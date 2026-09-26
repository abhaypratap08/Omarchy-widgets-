import QtQml
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris

/*
 * shell.qml — album-art wallpaper via Omarchy
 * ------------------------------------------------
 * Runs as its own Quickshell process and integrates through Omarchy's
 * public CLI. It does not import private shell services or QML modules.
 *
 * WHAT IT DOES
 *   - Watches MPRIS for a player that's actively playing.
 *   - On a new track's art, snapshots the current Omarchy background from
 *     ~/.local/state/omarchy/current/background, then runs
 *       omarchy theme bg set <art>
 *     to set the desktop background to the album cover.
 *   - The cover is never shown sharp. Before the background is set, the art
 *     is reduced to an ambient colour field with `magick`: blurred far past
 *     any detail, laid at `artOpacity` over a flat accent colour taken from
 *     the art itself, then saturated up so the accent stays vivid. The
 *     result is baked into an opaque JPEG, so nothing downstream has to know
 *     the wallpaper was treated.
 *   - When playback stops or pauses (after a short debounce so back-to-
 *     back tracks don't flicker), restores the previous background through
 *     the same Omarchy command.
 *
 * REQUIRES
 *   - Omarchy with its `omarchy` CLI available on PATH
 *   - `curl` on PATH only for players whose MPRIS art URL is remote;
 *     local file:// art is used directly
 *   - `magick` on PATH. If it is missing or the blur fails, the sharp cover
 *     is used instead and the failure is logged, so the wallpaper still
 *     updates either way.
 *
 * INSTALL
 *   Copy this directory to:
 *     ~/.config/quickshell/album-wallpaper/
 *
 * RUN
 *   quickshell -c album-wallpaper
 *   From this repository, run:
 *     quickshell -p ./album-wallpaper
 *
 * THEME BEHAVIOR
 *   Changing the background this way does not regenerate the active Omarchy
 *   theme. Change themes independently with `omarchy theme set <name>`.
 *
 * CONTROL
 *   qs ipc call albumwallpaper toggle
 *   qs ipc call albumwallpaper status
 */
ShellRoot {
    id: root

    // ---------------- config ----------------
    property bool enabled: true
    property int restoreDelayMs: 1200 // debounce before reverting between tracks
    property string cacheDir:
        ((Quickshell.env("XDG_CACHE_HOME") ||
            ((Quickshell.env("HOME") || "/tmp") + "/.cache")) + "/albumwallpaper")
    property string currentBackgroundLink: (Quickshell.env("HOME") || "/tmp") + "/.local/state/omarchy/current/background"
    property int keepCachedFiles: 20 // how many past songs' art to keep on disk

    // ---------------- wallpaper treatment ----------------
    // The wallpaper shows colour, not artwork. These turn a cover into a flat
    // accent field; see the WHAT IT DOES note above.
    readonly property string blurredDir: cacheDir + "/blurred"
    // A sigma of 48 on a 160px image is already past the point where any
    // detail survives, so raising it further costs time and changes nothing.
    readonly property string blurSigma: "0x48"
    readonly property string blurWidth: "160x160"
    // Blurring averages neighbouring hues together, which pulls colour toward
    // grey -- on a vivid cover that costs more saturation than a modest boost
    // can win back. These restore it. They cannot fully equalise across
    // tracks, because a washed-out cover gets pumped harder than a vivid one;
    // treat them as one tuning knob, not two precise values.
    readonly property string artSaturation: "200" // the art's own colour, boosted
    readonly property string baseSaturation: "210" // the flat accent colour, boosted harder
    // Percent of the art kept over the flat colour. The other 70% is the
    // accent colour itself, which is what makes the result read as a tint
    // rather than a picture.
    readonly property string artOpacity: "30"

    // ---------------- internal state — don't touch ----------------
    property string previousWallpaper: ""
    property bool wallpaperOverridden: false
    property string lastAppliedArt: ""
    property string lastAppliedPath: ""
    property string pendingArtUrl: ""
    property string pendingFileName: ""

    // Every asynchronous command carries the request id that created it. A
    // response from an older track is ignored instead of changing the current
    // wallpaper after a skip or a theme switch.
    property int requestSerial: 0
    property int captureAttempts: 0
    property int downloadAttempts: 0
    property int applyAttempts: 0
    property int restoreAttempts: 0
    property int applyRetryId: 0
    property string applyRetryPath: ""
    property bool cacheReady: false
    property bool downloadWaitingForCache: false
    property bool blurWaitingForCache: false
    property string blurRetrySource: ""

    // A theme switch is signalled by theme.name. Keep a generation separate
    // from the theme process so an older read cannot become the new baseline.
    property int themeGeneration: 0
    property int baselineRequestedGeneration: 0
    property int baselineAttempts: 0
    property string staleArtPath: ""
    property bool themeSwitchPending: false
    property bool themeNameInitialized: false
    readonly property string themeNamePath:
        (Quickshell.env("HOME") || "/tmp") + "/.local/state/omarchy/current/theme.name"

    // Desired/active apply state lets a new track queue behind an old command
    // without ever allowing the old command to win a race.
    property string desiredBackgroundPath: ""
    property int desiredBackgroundId: 0
    property string desiredBackgroundKind: ""
    property string activeBackgroundPath: ""
    property int activeBackgroundId: 0
    property string activeBackgroundKind: ""

    // Give every downloaded track a unique, human-readable path. This keeps
    // Omarchy's background transitions unambiguous and makes cache pruning
    // predictable.
    function sanitize(s) {
        const cleaned = (s || "").toString().trim()
            .replace(/[^a-zA-Z0-9]+/g, "_")
            .replace(/^_+|_+$/g, "");
        return cleaned.length > 0 ? cleaned.slice(0, 60) : "unknown";
    }

    function fileNameFor(p) {
        const artist = sanitize(p.trackArtist);
        const title = sanitize(p.trackTitle);
        const id = (p.uniqueId !== undefined && p.uniqueId !== null)
            ? sanitize(p.uniqueId)
            : String(Date.now());
        return artist + "_-_" + title + "_" + id + ".jpg";
    }

    // Local file:// art is used from wherever the player keeps it, and those
    // files are not named uniquely — plenty of players call theirs cover.jpg.
    // Hashing the full path keeps two different tracks from sharing one
    // treated file.
    function shortHash(s) {
        let h = 2166136261;
        const text = String(s);
        for (let i = 0; i < text.length; i++) {
            h ^= text.charCodeAt(i);
            h = Math.imul(h, 16777619);
        }
        return (h >>> 0).toString(36);
    }

    function blurredFileNameFor(path) {
        const base = sanitize(String(path).split("/").pop());
        return base + "_" + shortHash(path) + ".jpg";
    }

    readonly property var activePlayer: {
        const list = Mpris.players ? Mpris.players.values : [];
        for (const p of list) {
            if (p.playbackState === MprisPlaybackState.Playing && p.trackArtUrl)
                return p;
        }
        return null;
    }

    onActivePlayerChanged: evaluate()
    onEnabledChanged: evaluate()

    Connections {
        target: root.activePlayer
        function onTrackArtUrlChanged() { root.evaluate(); }
        function onPlaybackStateChanged() { root.evaluate(); }
    }

    Component.onCompleted: {
        mkdirProc.running = true;
        // MPRIS discovery is asynchronous, so onActivePlayerChanged usually
        // covers startup. Evaluate explicitly so an already-playing track is
        // still picked up if the player was discovered first.
        evaluate();
    }

    Process {
        id: mkdirProc
        // -p on the treated dir also creates cacheDir, so one call covers both.
        command: ["mkdir", "-p", root.blurredDir]
        onExited: (exitCode, exitStatus) => {
            root.cacheReady = exitCode === 0;
            if (exitCode !== 0) {
                console.warn("[albumwallpaper] could not create cache directory", root.blurredDir);
            } else if (root.downloadWaitingForCache) {
                root.downloadWaitingForCache = false;
                root.startDownload(root.requestSerial);
            } else if (root.blurWaitingForCache) {
                root.blurWaitingForCache = false;
                root.startBlur(root.blurRetrySource, root.requestSerial);
            }
        }
    }

    // ---------------- core logic ----------------
    function hasPlayingArt() {
        const p = activePlayer;
        return !!(p && p.playbackState === MprisPlaybackState.Playing && p.trackArtUrl);
    }

    function nextRequestId() {
        requestSerial += 1;
        return requestSerial;
    }

    function stopProcess(proc) {
        if (proc && proc.running)
            proc.running = false;
    }

    function resetPendingArt() {
        pendingArtUrl = "";
        pendingFileName = "";
        captureAttempts = 0;
        downloadAttempts = 0;
        applyAttempts = 0;
        applyRetryId = 0;
        applyRetryPath = "";
        downloadWaitingForCache = false;
        blurWaitingForCache = false;
        blurRetrySource = "";
    }

    function clearDesiredBackground() {
        desiredBackgroundPath = "";
        desiredBackgroundId = 0;
        desiredBackgroundKind = "";
    }

    function clearOverrideState() {
        previousWallpaper = "";
        wallpaperOverridden = false;
        lastAppliedArt = "";
        lastAppliedPath = "";
        resetPendingArt();
        clearDesiredBackground();
        restoreAttempts = 0;
    }

    function evaluate() {
        if (themeSwitchPending)
            return;

        if (!enabled) {
            // Keep the override in place while music is still playing, but
            // cancel any in-flight setup. Once playback ends, the next
            // evaluation restores the captured background.
            restoreTimer.stop();
            if (pendingArtUrl || captureProc.running || downloadProc.running || blurProc.running)
                cancelPendingArt();
            if (wallpaperOverridden && !hasPlayingArt())
                performRestore();
            return;
        }

        if (hasPlayingArt()) {
            restoreTimer.stop();
            requestArt(activePlayer);
        } else {
            if (pendingArtUrl || captureProc.running || downloadProc.running || blurProc.running)
                cancelPendingArt();
            scheduleRestore();
        }
    }

    function requestArt(p) {
        if (!p || !enabled || themeSwitchPending)
            return;

        const url = p.trackArtUrl;
        if (url === lastAppliedArt && wallpaperOverridden && !pendingArtUrl)
            return;
        // Repeated metadata signals for the same art must not reset retry
        // counters while a process or timer is between attempts.
        if (pendingArtUrl === url)
            return;

        const id = nextRequestId();
        pendingArtUrl = url;
        pendingFileName = fileNameFor(p);
        captureAttempts = 0;
        downloadAttempts = 0;
        applyAttempts = 0;
        applyRetryId = 0;
        applyRetryPath = "";
        console.log("[albumwallpaper] new track:", p.trackArtist, "-", p.trackTitle,
            "| art:", url, "| file:", pendingFileName);

        if (wallpaperOverridden)
            applyPendingArt(id);
        else
            startCapture(id);
    }

    function cancelPendingArt() {
        // Invalidate callbacks before stopping child processes. Their exit
        // handlers will see the new serial and will not apply stale art.
        nextRequestId();
        resetPendingArt();
        clearDesiredBackground();
        stopProcess(captureProc);
        stopProcess(downloadProc);
        stopProcess(blurProc);
        stopProcess(applyProc);
        captureRetryTimer.stop();
        downloadRetryTimer.stop();
        applyRetryTimer.stop();
    }

    function startCapture(id) {
        if (!enabled || themeSwitchPending || wallpaperOverridden ||
            captureProc.running || id !== requestSerial || !pendingArtUrl)
            return;

        captureProc.requestId = id;
        captureProc.running = true;
    }

    function handleCaptureExit(id, exitCode) {
        const captured = String(captureProc.stdout ? captureProc.stdout.text : "").trim();

        if (id !== requestSerial || themeSwitchPending || !enabled || !pendingArtUrl) {
            if (id !== requestSerial && !themeSwitchPending && !wallpaperOverridden)
                startCapture(requestSerial);
            return;
        }

        if (exitCode !== 0 || captured.length === 0) {
            captureAttempts += 1;
            console.warn("[albumwallpaper] could not capture the current Omarchy background",
                "exit", exitCode);
            if (captureAttempts < 3) {
                captureRetryTimer.restart();
            } else {
                resetPendingArt();
                clearOverrideState();
            }
            return;
        }

        captureRetryTimer.stop();
        previousWallpaper = captured;
        wallpaperOverridden = true;
        captureAttempts = 0;
        applyPendingArt(id);
    }

    Process {
        id: captureProc
        property int requestId: 0
        command: ["readlink", "-f", root.currentBackgroundLink]
        stdout: StdioCollector {}
        onExited: (exitCode, exitStatus) => root.handleCaptureExit(requestId, exitCode)
    }

    function applyPendingArt(id) {
        if (id !== requestSerial || !pendingArtUrl || themeSwitchPending)
            return;

        const url = pendingArtUrl;
        if (url.startsWith("file://")) {
            let path;
            try {
                path = decodeURIComponent(url.substring(7));
            } catch (error) {
                console.warn("[albumwallpaper] invalid local art URL:", url, error);
                failPendingArt(id, "invalid local art URL");
                return;
            }
            if (!path) {
                failPendingArt(id, "empty local art path");
                return;
            }
            startBlur(path, id);
        } else {
            startDownload(id);
        }
    }

    function startDownload(id) {
        if (!enabled || themeSwitchPending || id !== requestSerial || !pendingArtUrl)
            return;
        if (downloadProc.running)
            return;
        if (!cacheReady) {
            downloadWaitingForCache = true;
            mkdirProc.running = true;
            return;
        }

        downloadProc.requestId = id;
        downloadProc.artUrl = pendingArtUrl;
        downloadProc.outFile = cacheDir + "/" + pendingFileName;
        downloadProc.running = true;
    }

    function handleDownloadExit(id, url, outFile, exitCode) {
        if (id !== requestSerial || themeSwitchPending || !enabled ||
            url !== pendingArtUrl || outFile !== cacheDir + "/" + pendingFileName) {
            // Leave stale output for normal cache pruning. A stopped player
            // may resume the same track before an asynchronous rm completes;
            // deleting here could remove the replacement download's file.
            if (id !== requestSerial && !themeSwitchPending && hasPlayingArt() &&
                !pendingArtUrl.startsWith("file://"))
                startDownload(requestSerial);
            return;
        }

        if (exitCode !== 0) {
            cleanupFile(outFile);
            downloadAttempts += 1;
            console.warn("[albumwallpaper] album-art download failed", "exit", exitCode,
                "->", outFile);
            if (downloadAttempts < 2) {
                downloadRetryTimer.restart();
            } else {
                failPendingArt(id, "album-art download failed");
            }
            return;
        }

        downloadRetryTimer.stop();
        downloadAttempts = 0;
        startBlur(outFile, id);
        pruneCache();
    }

    Process {
        id: downloadProc
        property int requestId: 0
        property string artUrl: ""
        property string outFile: ""
        command: ["curl", "--fail", "--silent", "--show-error", "--location",
            artUrl, "-o", outFile]
        onExited: (exitCode, exitStatus) =>
            root.handleDownloadExit(requestId, artUrl, outFile, exitCode)
    }

    // ---------------- wallpaper treatment ----------------
    // Reduce the cover to an ambient colour field before it becomes the
    // wallpaper: blur the art, take a flat accent colour from it, and lay the
    // art over that colour. The parentheses are passed as literal argv
    // elements, not through a shell, so a hostile art path can never be
    // interpreted as anything but a filename.
    function blurCommandFor(src, dst) {
        return ["magick", src,
            "-resize", root.blurWidth,
            "-blur", root.blurSigma,
            "-modulate", "100," + root.artSaturation + ",100",
            "(", "+clone", "-resize", "1x1!", "-blur", "0x4",
            "-modulate", "100," + root.baseSaturation + ",100",
            "-resize", root.blurWidth, ")",
            "-compose", "dissolve",
            "-define", "compose:args=" + root.artOpacity,
            "-composite", dst];
    }

    // Re-treating costs about 40ms, which is less than the extra process a
    // cache check would need, so every track is treated afresh.
    function startBlur(src, id) {
        if (!src || !enabled || themeSwitchPending || id !== requestSerial)
            return;
        if (blurProc.running)
            return;
        if (!cacheReady) {
            blurWaitingForCache = true;
            blurRetrySource = src;
            mkdirProc.running = true;
            return;
        }

        blurProc.requestId = id;
        blurProc.sourcePath = src;
        blurProc.outFile = blurredDir + "/" + blurredFileNameFor(src);
        blurProc.running = true;
    }

    function handleBlurExit(id, src, outFile, exitCode) {
        if (id !== requestSerial || themeSwitchPending || !enabled ||
            src !== blurProc.sourcePath || outFile !== blurProc.outFile)
            return;

        blurWaitingForCache = false;

        if (exitCode !== 0) {
            // A missing or broken `magick` must never stop the wallpaper from
            // updating. Fall back to the sharp cover and say so.
            console.warn("[albumwallpaper] wallpaper blur failed, using the sharp cover",
                "exit", exitCode, "->", src);
            queueBackground(src, id, "art");
            return;
        }

        queueBackground(outFile, id, "art");
        pruneBlurredCache();
    }

    Process {
        id: blurProc
        property int requestId: 0
        property string sourcePath: ""
        property string outFile: ""
        command: root.blurCommandFor(sourcePath, outFile)
        onExited: (exitCode, exitStatus) =>
            root.handleBlurExit(requestId, sourcePath, outFile, exitCode)
    }

    function queueBackground(path, id, kind) {
        if (!path || id !== requestSerial || themeSwitchPending)
            return;

        desiredBackgroundPath = path;
        desiredBackgroundId = id;
        desiredBackgroundKind = kind;
        startBackgroundApply();
    }

    function startBackgroundApply() {
        if (applyProc.running || desiredBackgroundPath.length === 0)
            return;

        // A newer track bumped the request id without clearing queued work.
        // Dropping it here stops superseded artwork from ever being shown.
        if (desiredBackgroundId !== requestSerial) {
            clearDesiredBackground();
            return;
        }

        activeBackgroundPath = desiredBackgroundPath;
        activeBackgroundId = desiredBackgroundId;
        activeBackgroundKind = desiredBackgroundKind;
        clearDesiredBackground();
        applyProc.path = activeBackgroundPath;
        applyProc.running = true;
    }

    function handleApplyExit(id, kind, path, exitCode) {
        if (id !== requestSerial) {
            startBackgroundApply();
            return;
        }

        if (kind === "art") {
            if (exitCode === 0) {
                applyRetryTimer.stop();
                applyAttempts = 0;
                lastAppliedArt = pendingArtUrl;
                lastAppliedPath = path;
                pendingArtUrl = "";
                pendingFileName = "";
            } else {
                console.warn("[albumwallpaper] omarchy theme bg set failed", "exit", exitCode,
                    "->", path);
                if (applyAttempts < 2 && enabled && pendingArtUrl) {
                    applyAttempts += 1;
                    applyRetryId = id;
                    applyRetryPath = path;
                    // Keep the retry in the timer. Assigning a desired path
                    // here would make startBackgroundApply() below bypass
                    // the retry delay.
                    applyRetryTimer.restart();
                } else {
                    failPendingArt(id, "album-art background command failed");
                }
            }
        } else if (kind === "restore") {
            if (exitCode === 0) {
                restoreRetryTimer.stop();
                // A newer request, if playback resumed while the restore was
                // running, already owns the pending artwork. Otherwise the
                // successful restore means there is no override to remember;
                // do not retry the same failed track immediately.
                if (pendingArtUrl.length === 0)
                    clearOverrideState();
            } else {
                restoreAttempts += 1;
                console.warn("[albumwallpaper] could not restore Omarchy background",
                    "exit", exitCode, "->", path);
                if (restoreAttempts < 4)
                    restoreRetryTimer.restart();
                else
                    console.warn("[albumwallpaper] giving up background restore; the original path is retained");
            }
        }

        startBackgroundApply();
    }

    Process {
        id: applyProc
        property string path: ""
        command: ["omarchy", "theme", "bg", "set", path]
        onExited: (exitCode, exitStatus) =>
            root.handleApplyExit(activeBackgroundId, activeBackgroundKind, path, exitCode)
    }

    function failPendingArt(id, reason) {
        if (id !== requestSerial)
            return;

        console.warn("[albumwallpaper]", reason);
        const restorePath = previousWallpaper;
        const shouldRestore = wallpaperOverridden && restorePath.length > 0;
        resetPendingArt();
        lastAppliedArt = "";
        if (shouldRestore) {
            const restoreId = nextRequestId();
            queueBackground(restorePath, restoreId, "restore");
        } else {
            clearOverrideState();
        }
    }

    function cleanupFile(path) {
        if (!path)
            return;
        cleanupProc.path = path;
        cleanupProc.running = true;
    }

    Process {
        id: cleanupProc
        property string path: ""
        command: ["rm", "-f", "--", path]
    }

    // Keep only the most recent `keepCachedFiles` files in a cache directory
    // so it doesn't grow forever over a long listening session. Files that are
    // still referenced (the restore target, the applied art, queued work) are
    // never pruned, and the paths are passed as positional arguments so a
    // hostile XDG_CACHE_HOME can never reach the shell. A directory that does
    // not exist yet is not an error: the script cds or exits cleanly.
    readonly property string pruneScript: [
        'cd "$1" || exit 0',
        'keep="$2"',
        'shift 2',
        'ls -1t | tail -n +"$keep" | while IFS= read -r name; do',
        '  skip=0',
        '  for p in "$@"; do [ "$name" = "${p##*/}" ] && skip=1; done',
        '  [ "$skip" -eq 0 ] && rm -f -- "$name"',
        'done',
        'exit 0'
    ].join("\n")

    function pruneCommandFor(dir) {
        const protectedPaths = [root.previousWallpaper, root.activeBackgroundPath,
            root.desiredBackgroundPath, root.staleArtPath]
            .filter(function (path) { return path && path.length > 0; });

        return ["bash", "-c", root.pruneScript, "prune", dir,
            // Never prune everything: the newest file is the current track.
            String(Math.max(1, root.keepCachedFiles) + 1)].concat(protectedPaths);
    }

    function pruneCommand() {
        return root.pruneCommandFor(root.cacheDir);
    }

    function pruneCache() {
        pruneProc.running = true;
    }

    // Treated files are pruned separately from the art they came from, so they
    // never consume the art budget or evict a cover that is still needed.
    function pruneBlurredCache() {
        blurredPruneProc.running = true;
    }

    Process {
        id: pruneProc
        command: root.pruneCommand()
    }

    Process {
        id: blurredPruneProc
        command: root.pruneCommandFor(root.blurredDir)
    }

    Timer {
        id: captureRetryTimer
        interval: 350
        repeat: false
        onTriggered: root.startCapture(root.requestSerial)
    }

    Timer {
        id: downloadRetryTimer
        interval: 700
        repeat: false
        onTriggered: root.startDownload(root.requestSerial)
    }

    Timer {
        id: applyRetryTimer
        interval: 700
        repeat: false
        onTriggered: {
            if (root.applyRetryId === root.requestSerial && root.applyRetryPath.length > 0) {
                root.desiredBackgroundPath = root.applyRetryPath;
                root.desiredBackgroundId = root.requestSerial;
                root.desiredBackgroundKind = "art";
                root.startBackgroundApply();
            }
        }
    }

    Timer {
        id: restoreRetryTimer
        interval: 500
        repeat: false
        onTriggered: root.retryRestore()
    }

    function retryRestore() {
        if (themeSwitchPending || hasPlayingArt() || !wallpaperOverridden ||
            previousWallpaper.length === 0 || restoreAttempts >= 4)
            return;

        const restoreId = nextRequestId();
        queueBackground(previousWallpaper, restoreId, "restore");
    }

    Timer {
        id: restoreTimer
        interval: root.restoreDelayMs
        repeat: false
        onTriggered: root.performRestore()
    }

    function scheduleRestore() {
        if (themeSwitchPending)
            return;
        if (!wallpaperOverridden) {
            if (pendingArtUrl || captureProc.running || downloadProc.running || blurProc.running)
                cancelPendingArt();
            return;
        }
        console.log("[albumwallpaper] playback stopped/paused, restoring in",
            root.restoreDelayMs, "ms");
        restoreTimer.restart();
    }

    function performRestore() {
        restoreTimer.stop();
        restoreRetryTimer.stop();
        if (themeSwitchPending)
            return;
        if (hasPlayingArt()) {
            if (enabled)
                evaluate();
            return;
        }
        if (!wallpaperOverridden) {
            clearOverrideState();
            return;
        }
        if (previousWallpaper.length === 0) {
            clearOverrideState();
            return;
        }

        const restoreId = nextRequestId();
        resetPendingArt();
        lastAppliedArt = "";
        restoreAttempts = 0;
        clearDesiredBackground();
        queueBackground(previousWallpaper, restoreId, "restore");
    }

    // The first successful read of theme.name marks the baseline ready; the
    // name itself is only a change marker, so it is not stored.
    function observeThemeName() {
        themeNameInitialized = true;
    }

    function handleThemeChange() {
        if (!themeNameInitialized)
            return;

        console.log("[albumwallpaper] Omarchy theme changed; refreshing the restore baseline");
        themeGeneration += 1;
        baselineRequestedGeneration = themeGeneration;
        baselineAttempts = 0;
        staleArtPath = activeBackgroundKind === "art"
            ? activeBackgroundPath
            : (lastAppliedPath || staleArtPath);
        themeSwitchPending = true;
        nextRequestId();
        resetPendingArt();
        clearDesiredBackground();
        previousWallpaper = "";
        wallpaperOverridden = false;
        lastAppliedArt = "";
        lastAppliedPath = "";
        restoreTimer.stop();
        captureRetryTimer.stop();
        downloadRetryTimer.stop();
        applyRetryTimer.stop();
        restoreRetryTimer.stop();
        stopProcess(captureProc);
        stopProcess(downloadProc);
        stopProcess(blurProc);
        stopProcess(applyProc);
        themeBaselineTimer.restart();
    }

    function startThemeBaseline() {
        if (!themeSwitchPending || themeBaselineProc.running)
            return;
        themeBaselineProc.generation = baselineRequestedGeneration;
        themeBaselineProc.running = true;
    }

    function handleThemeBaselineExit(generation, exitCode) {
        if (generation !== themeGeneration) {
            startThemeBaseline();
            return;
        }

        const current = String(themeBaselineProc.stdout ? themeBaselineProc.stdout.text : "").trim();
        if (exitCode !== 0 || current.length === 0 ||
            (staleArtPath.length > 0 && current === staleArtPath)) {
            baselineAttempts += 1;
            if (baselineAttempts < 5) {
                themeBaselineTimer.restart();
            } else {
                console.warn("[albumwallpaper] could not refresh the post-theme background baseline");
                themeSwitchPending = false;
                clearOverrideState();
            }
            return;
        }

        previousWallpaper = current;
        staleArtPath = "";
        baselineAttempts = 0;
        themeSwitchPending = false;

        if (enabled && hasPlayingArt()) {
            const p = activePlayer;
            const id = nextRequestId();
            pendingArtUrl = p.trackArtUrl;
            pendingFileName = fileNameFor(p);
            wallpaperOverridden = true;
            applyPendingArt(id);
        } else {
            clearOverrideState();
        }
    }

    Process {
        id: themeBaselineProc
        property int generation: 0
        command: ["readlink", "-f", root.currentBackgroundLink]
        stdout: StdioCollector {}
        onExited: (exitCode, exitStatus) =>
            root.handleThemeBaselineExit(generation, exitCode)
    }

    Timer {
        id: themeBaselineTimer
        interval: 500
        repeat: false
        onTriggered: root.startThemeBaseline()
    }

    FileView {
        id: themeNameFile
        path: root.themeNamePath
        watchChanges: true
        printErrors: false
        onLoaded: root.observeThemeName()
        onFileChanged: root.handleThemeChange()
    }

    IpcHandler {
        target: "albumwallpaper"

        function toggle(): void { root.enabled = !root.enabled; }
        function status(): string { return root.enabled ? "enabled" : "disabled"; }
    }
}
