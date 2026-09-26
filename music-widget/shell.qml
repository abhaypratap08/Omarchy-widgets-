pragma ComponentBehavior: Bound

import QtQml
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris

/*
 * music-widget — MPRIS now-playing card for Omarchy
 * -------------------------------------------------
 * A single layer-shell card showing the active player's artwork, title,
 * artist, seek bar and transport controls. It is a standalone Quickshell
 * config: it imports no private Omarchy QML modules and reads only the
 * generated theme files plus the public MPRIS interfaces.
 *
 * RUN
 *   quickshell -c music-widget
 *
 * LAYER NOTES
 *   The card lives on the Bottom layer, directly above the wallpaper and
 *   below the Omarchy bar. It reserves no exclusive zone so it never
 *   pushes windows around, and it never animates its own surface size --
 *   resizing a layer-shell surface makes Hyprland recreate it, which shows
 *   up as a visible flicker. The card is therefore a fixed size and only
 *   its contents react to state changes.
 */

ShellRoot {
    id: root

    /* =================================================================
     * Configuration
     * ================================================================= */

    // Card geometry. Fixed so the surface is created once.
    readonly property int cardWidth: 380
    // Must equal pad*2 + art(72) + seek(29) + transport(32) + spacing*2.
    // Anything smaller does not just look tight: the ColumnLayout overflows,
    // and because a layer-shell window clips to its own surface, the
    // overflowing rows are not drawn at all. At the old value of 132 the
    // whole transport row sat below the card and never reached the screen.
    readonly property int cardHeight: 185
    readonly property int cornerRadius: 18
    readonly property int pad: 16

    // Distance from the bottom of the screen. Sits clear of the bar.
    readonly property int bottomInset: 34

    /* =================================================================
     * Theme
     * ================================================================= */

    readonly property string omarchyStateDir:
        (Quickshell.env("HOME") || "/tmp") + "/.local/state"
    readonly property string currentThemePath:
        omarchyStateDir + "/omarchy/current/theme"
    readonly property string themeNamePath:
        omarchyStateDir + "/omarchy/current/theme.name"

    QtObject {
        id: theme

        // FileViews for the generated Omarchy theme. Omarchy replaces the
        // theme directory and then writes theme.name, so theme.name is the
        // signal that the new files are safe to read.
        property FileView colorsFile: FileView {
            path: root.currentThemePath + "/colors.toml"
            watchChanges: false
            printErrors: false
            onLoaded: theme.setColorValues(text())
        }

        property FileView shellFile: FileView {
            path: root.currentThemePath + "/shell.toml"
            watchChanges: false
            printErrors: false
            onLoaded: theme.setThemeShellValues(text())
        }

        property FileView themeNameFile: FileView {
            path: root.themeNamePath
            watchChanges: true
            printErrors: false
            onFileChanged: theme.reloadTheme()
        }

        function reloadTheme() {
            colorsFile.reload();
            shellFile.reload();
        }

        property var colorValues: ({})
        property var themeShellValues: ({})
        property var values: ({})

        // Omarchy's generated files use a small TOML subset. Keep the
        // parser local so this module remains standalone and does not
        // import private shell QML modules.
        function stripComment(line) {
            let quote = "";
            let escaped = false;

            for (let i = 0; i < line.length; i++) {
                const ch = line.charAt(i);
                if (quote) {
                    if (escaped) {
                        escaped = false;
                    } else if (ch === "\\") {
                        escaped = true;
                    } else if (ch === quote) {
                        quote = "";
                    }
                } else if (ch === "\"" || ch === "'") {
                    quote = ch;
                } else if (ch === "#") {
                    return line.substring(0, i);
                }
            }

            return line;
        }

        function parseValue(raw) {
            const value = String(raw || "").replace(/^\s+|\s+$/g, "");
            if (!value) return null;

            const quote = value.charAt(0);
            if (quote === "\"" || quote === "'") {
                let escaped = false;
                for (let i = 1; i < value.length; i++) {
                    const ch = value.charAt(i);
                    if (quote === "\"" && escaped) {
                        escaped = false;
                    } else if (quote === "\"" && ch === "\\") {
                        escaped = true;
                    } else if (ch === quote) {
                        const trailing = value.substring(i + 1).replace(/^\s+|\s+$/g, "");
                        if (trailing && trailing.charAt(0) !== "#")
                            return null;
                        return value.substring(1, i).replace(/\\([\\"])/g, "$1");
                    }
                }
                return null;
            }

            return value;
        }

        function parseToml(raw) {
            const parsed = {};
            let section = "";
            const lines = String(raw || "").split(/\r?\n/);

            for (let i = 0; i < lines.length; i++) {
                const line = stripComment(lines[i]).replace(/^\s+|\s+$/g, "");
                if (!line || line.charAt(0) === "#") continue;

                const sectionMatch = line.match(/^\[([A-Za-z0-9_.-]+)\]\s*$/);
                if (sectionMatch) {
                    section = sectionMatch[1];
                    continue;
                }

                const equals = line.indexOf("=");
                if (equals < 0) continue;
                const key = line.substring(0, equals).replace(/^\s+|\s+$/g, "");
                if (!/^[A-Za-z0-9_-]+$/.test(key)) continue;

                const value = parseValue(line.substring(equals + 1));
                if (value === null) continue;
                parsed[(section ? section + "." : "") + key] = value;
            }

            return parsed;
        }

        function rebuildValues() {
            const merged = {};
            const sources = [colorValues, themeShellValues];
            for (let i = 0; i < sources.length; i++) {
                const source = sources[i] || {};
                for (const key in source) merged[key] = source[key];
            }

            // Omarchy accepts both the semantic palette and its short
            // aliases. Mirror the aliases that are useful to color-only
            // consumers so older themes resolve consistently too.
            const aliases = {
                "bg": "background",
                "fg": "foreground",
                "dark_bg": "dark_background",
                "darker_bg": "darker_background",
                "lighter_bg": "lighter_background",
                "dark_fg": "dark_foreground",
                "light_fg": "light_foreground",
                "bright_fg": "bright_foreground",
                "purple": "magenta",
                "bright_purple": "bright_magenta"
            };
            for (const alias in aliases) {
                if (merged[alias] === undefined && merged[aliases[alias]] !== undefined)
                    merged[alias] = merged[aliases[alias]];
            }

            values = merged;
        }

        function setColorValues(raw) {
            colorValues = parseToml(raw);
            rebuildValues();
        }

        function setThemeShellValues(raw) {
            themeShellValues = parseToml(raw);
            rebuildValues();
        }

        function splitColorTokens(value) {
            const parts = [];
            let current = "";
            let depth = 0;
            let quote = "";

            for (let i = 0; i < value.length; i++) {
                const ch = value.charAt(i);
                if (quote) {
                    current += ch;
                    if (ch === quote)
                        quote = "";
                } else if (ch === "\"" || ch === "'") {
                    quote = ch;
                    current += ch;
                } else if (ch === "(") {
                    depth++;
                    current += ch;
                } else if (ch === ")") {
                    depth = Math.max(0, depth - 1);
                    current += ch;
                } else if (/\s/.test(ch) && depth === 0) {
                    if (current) parts.push(current);
                    current = "";
                } else {
                    current += ch;
                }
            }
            if (current) parts.push(current);
            return parts;
        }

        function firstColorToken(value) {
            const parts = splitColorTokens(String(value || ""));
            for (let i = 0; i < parts.length; i++) {
                if (!/^-?\d+(?:\.\d+)?deg$/i.test(parts[i]))
                    return parts[i];
            }
            return "";
        }

        function byteHex(number) {
            const n = Math.max(0, Math.min(255, Math.round(number)));
            return ("0" + n.toString(16)).slice(-2);
        }

        function alphaHex(value) {
            if (value === undefined || value === null || value === "")
                return "ff";
            const text = String(value).trim();
            if (text.charAt(text.length - 1) === "%") {
                // Divide first: "50% * 2.55" lands just under 127.5 in
                // floating point and rounds to 0x7f instead of 0x80.
                return byteHex(parseFloat(text.substring(0, text.length - 1)) / 100 * 255);
            }
            const alpha = parseFloat(text);
            return byteHex((isNaN(alpha) ? 1 : alpha) * 255);
        }

        function normalizeHex(value) {
            let hex = String(value || "").replace(/^#/, "");
            if (!/^[0-9a-f]+$/i.test(hex)) return "";

            if (hex.length === 3 || hex.length === 4) {
                let expanded = "";
                for (let i = 0; i < hex.length; i++)
                    expanded += hex.charAt(i) + hex.charAt(i);
                hex = expanded;
            }
            if (hex.length === 6)
                return "#" + hex.toLowerCase();
            if (hex.length === 8) {
                // Omarchy/Hyprland colors use #RRGGBBAA; QML uses
                // #AARRGGBB for an eight-digit color literal.
                return "#" + hex.substring(6, 8).toLowerCase() +
                    hex.substring(0, 6).toLowerCase();
            }
            return "";
        }

        function normalizeColor(value) {
            const token = String(value || "").replace(/^\s+|\s+$/g, "");
            if (!token) return "";
            if (token === "transparent") return "#00000000";

            const hex = normalizeHex(token);
            if (hex) return hex;

            const rgb = token.match(/^rgba?\(([^)]*)\)$/i);
            if (rgb) {
                const parts = rgb[1].split(",").map(function (part) {
                    return part.replace(/^\s+|\s+$/g, "");
                });
                if (parts.length === 1 && /^#?[0-9a-f]{6}(?:[0-9a-f]{2})?$/i.test(parts[0])) {
                    return normalizeHex("#" + parts[0].replace(/^#/, ""));
                }
                if (parts.length >= 3) {
                    // Comma-separated components are decimal, matching
                    // Omarchy's own color conversion. The hex spelling
                    // (for example rgba(1e1e2eff)) is handled by the
                    // single-argument branch above, so a two-digit
                    // decimal such as 46 must not be read as a hex pair.
                    const r = parseFloat(parts[0].replace(/^#/, ""));
                    const g = parseFloat(parts[1].replace(/^#/, ""));
                    const b = parseFloat(parts[2].replace(/^#/, ""));
                    const a = parts.length > 3 ? alphaHex(parts[3]) : "ff";
                    if (!isNaN(r) && !isNaN(g) && !isNaN(b))
                        return "#" + a + byteHex(r) + byteHex(g) + byteHex(b);
                }
            }

            if (/^(?:hsl|hsla)\(/i.test(token))
                return token;
            return "";
        }

        function resolveToken(token, depth) {
            if (depth > 16) return "";

            const value = String(token || "").replace(/^\s+|\s+$/g, "");
            if (!value) return "";

            if (value === "text")
                return resolveToken("foreground", depth + 1);
            if (value === "transparent")
                return "#00000000";
            if (values[value] !== undefined && values[value] !== value)
                return resolveToken(values[value], depth + 1);

            // Color-only consumers use the first stop of an Omarchy
            // shell gradient (for example, rgba(...) rgba(...) 45deg).
            const first = firstColorToken(value);
            if (first && first !== value)
                return resolveToken(first, depth + 1);
            return normalizeColor(value);
        }

        function pickColor(keys, fallback) {
            for (let i = 0; i < keys.length; i++) {
                const resolved = resolveToken(values[keys[i]], 0);
                if (resolved) return resolved;
            }
            return fallback;
        }

        function luminance(col) {
            return 0.299 * col.r + 0.587 * col.g + 0.114 * col.b;
        }

        readonly property color baseBackground: pickColor(["background", "color0"], "#1b1d1e")
        readonly property color baseForeground: pickColor(["foreground", "color7"], "#c6c5bf")
        readonly property color baseAccent: pickColor(["accent", "color4"], "#fcef0c")
        readonly property color baseMuted: pickColor(["muted", "color8"], baseForeground)

        readonly property color surface: pickColor(["popups.background", "background"], baseBackground)
        readonly property bool dark: luminance(surface) < 0.5
        readonly property color surfaceHigh: Qt.lighter(surface, dark ? 1.08 : 0.94)
        readonly property color surfaceHighest: Qt.lighter(surface, dark ? 1.14 : 0.88)
        readonly property color foreground: pickColor(["popups.text", "foreground"], baseForeground)
        readonly property color muted: pickColor(["muted", "color8"], baseMuted)
        readonly property color accent: baseAccent
        readonly property color onAccent: luminance(accent) > 0.5 ? "#101015" : "#ffffff"
    }

    readonly property color colText: theme.foreground
    readonly property color colDim: theme.muted
    readonly property color colAccent: theme.accent
    readonly property color colOnAccent: theme.onAccent
    readonly property color colSurface: theme.surfaceHigh
    readonly property color colBorder: Qt.alpha(theme.foreground, 0.10)

    /* =================================================================
     * Player selection
     * ================================================================= */

    readonly property var allPlayers: {
        const list = Mpris.players ? Mpris.players.values : [];
        // Sort so the list order is stable between updates; an unstable
        // order makes the "current player" jump around on its own.
        return list.slice().sort(function (a, b) {
            return (a.identity || "").localeCompare(b.identity || "");
        });
    }

    // -1 follows the active player automatically.
    property int manualIndex: -1

    readonly property var player: {
        if (manualIndex >= 0 && manualIndex < allPlayers.length)
            return allPlayers[manualIndex];
        if (allPlayers.length === 0)
            return null;
        // Prefer something that is actually playing, else the first entry.
        for (const p of allPlayers) {
            if (p.playbackState === MprisPlaybackState.Playing)
                return p;
        }
        return allPlayers[0];
    }

    readonly property bool hasPlayer: player !== null

    readonly property bool isPlaying:
        hasPlayer && player.playbackState === MprisPlaybackState.Playing

    readonly property bool canControl: hasPlayer && player.canControl === true
    readonly property bool canSeek: canControl && player.canSeek === true
    // position may only be written when the player supports it.
    readonly property bool canSetPosition:
        canSeek && player.positionSupported === true
    readonly property bool canGoPrevious: canControl && player.canGoPrevious === true
    readonly property bool canGoNext: canControl && player.canGoNext === true
    // Play/pause is offered whenever either direction is available.
    readonly property bool canTogglePlay:
        canControl && (player.canTogglePlaying === true
                       || player.canPlay === true
                       || player.canPause === true)

    /* ---- volume, shuffle, repeat -------------------------------------
     *
     * MPRIS only permits writing these when the player advertises the
     * matching capability, and support varies wildly between players. Each
     * control is therefore hidden rather than shown-but-dead, matching how
     * the transport buttons above already behave.
     * ------------------------------------------------------------------ */

    readonly property bool canSetVolume:
        hasPlayer && canControl && player.volumeSupported === true

    readonly property bool canToggleShuffle:
        hasPlayer && canControl && player.shuffleSupported === true

    readonly property bool canCycleLoop:
        hasPlayer && canControl && player.loopSupported === true

    // MPRIS volume is 0.0-1.0.
    readonly property real volumeLevel:
        canSetVolume ? Math.max(0, Math.min(1, Number(player.volume))) : 0

    readonly property bool shuffleOn:
        canToggleShuffle && player.shuffle === true

    // Repeat has three states but only one button, so "repeat this track"
    // needs its own artwork. Lucide ships `repeat-1`, whose numeral is part
    // of the vector path -- so the distinction needs no text badge at all.
    // Off and repeat-all share the plain loop and are told apart by the
    // button's `active` tint.
    readonly property string loopIcon:
        canCycleLoop && player.loopState === MprisLoopState.Track
            ? "repeat-1" : "repeat"

    readonly property bool loopOn:
        canCycleLoop && player.loopState !== MprisLoopState.None

    // ---- artwork ----------------------------------------------------

    // MPRIS players advertise artwork however they please: a local file for
    // some, an https CDN link for others. Spotify -- the player this widget
    // is normally pointed at -- only ever hands out https, so accepting
    // file:// alone left the cover permanently blank.
    readonly property string rawArtUrl:
        hasPlayer && player.trackArtUrl ? String(player.trackArtUrl).trim() : ""

    // Qt Quick has no network image loader, so a remote URL cannot be bound
    // straight to Image.source. `artPath` is therefore always a local file:
    // either the player's own file:// path, or a copy fetched into the cache
    // below. It stays "" while a fetch is outstanding, which is what the
    // placeholder keys off.
    property string artPath: ""

    readonly property string artSource:
        artPath ? artFileUrl(artPath) : ""

    readonly property string artCacheDir:
        ((Quickshell.env("XDG_CACHE_HOME") ||
            ((Quickshell.env("HOME") || "/tmp") + "/.cache")) + "/music-widget")

    readonly property int keepCachedArt: 12

    // ---- artwork fetch state -- don't touch ----

    property bool artCacheReady: false
    property string artFetchUrl: ""
    property string artFetchPath: ""
    // Every fetch carries the request id that started it, so a slow download
    // belonging to a skipped track can never overwrite the current cover.
    property int artRequestId: 0
    property int artAttempts: 0

    // A file:// URL with each path segment percent-encoded, so spaces in a
    // cache path can't break Image.source.
    function artFileUrl(path) {
        if (!path)
            return "";
        return "file://" + String(path).split("/").map(encodeURIComponent).join("/");
    }

    // One stable filename per art URL, so a cover is fetched once and served
    // from cache afterwards. Deliberately extension-less: Qt detects the
    // format from the file's contents, so a CDN serving WebP or PNG is never
    // stored under a misleading name.
    function artFileNameFor(url) {
        const s = String(url);
        let h = 5381;
        for (let i = 0; i < s.length; ++i)
            h = (Math.imul(h, 33) + s.charCodeAt(i)) >>> 0;
        const tail = s.split("/").pop().replace(/[^a-zA-Z0-9]/g, "").slice(-16);
        return (tail ? tail + "_" : "") + h.toString(16);
    }

    // Point the artwork at something loadable, fetching it first when the
    // player only offered a remote URL.
    function resolveArt() {
        const url = rawArtUrl;

        if (!url) {
            artRequestId += 1;
            artFetchUrl = "";
            artFetchPath = "";
            artPath = "";
            return;
        }

        // Already a local file: use it as-is, no copy needed.
        if (/^file:\/\//i.test(url)) {
            artRequestId += 1;
            artFetchUrl = "";
            artFetchPath = "";
            let path = "";
            try {
                path = decodeURIComponent(url.substring(7));
            } catch (error) {
                console.warn("[musicwidget] invalid local artwork URL:", url, error);
            }
            artPath = path;
            return;
        }

        // Only http(s) can be fetched; anything else is not artwork we can show.
        if (!/^https?:\/\//i.test(url)) {
            console.warn("[musicwidget] unsupported artwork URL:", url);
            artRequestId += 1;
            artFetchUrl = "";
            artFetchPath = "";
            artPath = "";
            return;
        }

        const path = artCacheDir + "/" + artFileNameFor(url);

        // Already showing this cover, or already fetching it: nothing to do.
        if (artPath === path || artFetchUrl === url)
            return;

        artFetchUrl = url;
        artFetchPath = path;
        artAttempts = 0;
        artRequestId += 1;
        startArtFetch(artRequestId);
    }

    function startArtFetch(id) {
        if (id !== artRequestId || !artFetchUrl || !artFetchPath)
            return;

        if (!artCacheReady) {
            artFetchProc.waitingForCache = true;
            artMkdirProc.running = true;
            return;
        }

        artFetchProc.requestId = id;
        artFetchProc.url = artFetchUrl;
        artFetchProc.outFile = artFetchPath;
        artFetchProc.running = true;
    }

    function handleArtFetchExit(id, url, outFile, exitCode) {
        if (id !== artRequestId || url !== artFetchUrl || outFile !== artFetchPath) {
            // A cover we no longer want. Drop the file, unless a newer request
            // for the same cover is already using it.
            if (outFile && outFile !== artFetchPath)
                discardArtFile(outFile);
            return;
        }

        if (exitCode !== 0) {
            discardArtFile(outFile);
            artAttempts += 1;
            if (artAttempts < 2) {
                artRetryTimer.restart();
                return;
            }
            console.warn("[musicwidget] artwork download failed", url, "exit", exitCode);
            artFetchUrl = "";
            artFetchPath = "";
            return;
        }

        artRetryTimer.stop();
        artAttempts = 0;
        artPath = outFile;
        pruneArtCache();
    }

    function discardArtFile(path) {
        if (!path)
            return;
        artCleanupProc.path = path;
        artCleanupProc.running = true;
    }

    // Keep only the most recent covers so the cache doesn't grow forever over
    // a long listening session. The on-screen cover and any in-flight fetch
    // are passed as positional arguments and never pruned.
    readonly property string artPruneScript: [
        'cd "$1" || exit 0',
        'keep="$2"',
        'shift 2',
        'ls -1t | tail -n +"$keep" | while IFS= read -r name; do',
        '  skip=0',
        '  for p in "$@"; do [ -n "$p" ] && [ "$name" = "${p##*/}" ] && skip=1; done',
        '  [ "$skip" -eq 0 ] && rm -f -- "$name"',
        'done',
        'exit 0'
    ].join("\n")

    function pruneArtCache() {
        artPruneProc.keep = Math.max(1, keepCachedArt + 1);
        artPruneProc.running = true;
    }

    Process {
        id: artMkdirProc
        command: ["mkdir", "-p", root.artCacheDir]
        onExited: (exitCode, exitStatus) => {
            root.artCacheReady = exitCode === 0;
            if (exitCode !== 0) {
                console.warn("[musicwidget] could not create artwork cache", root.artCacheDir);
            } else if (artFetchProc.waitingForCache) {
                artFetchProc.waitingForCache = false;
                root.startArtFetch(root.artRequestId);
            }
        }
    }

    Process {
        id: artFetchProc
        property int requestId: 0
        property string url: ""
        property string outFile: ""
        property bool waitingForCache: false

        // Reuse an already-cached copy instead of refetching it. Paths are
        // passed as positional arguments so a hostile XDG_CACHE_HOME can never
        // reach the shell.
        command: ["bash", "-c", [
            'if [ -f "$1" ]; then exit 0; fi',
            // --output must precede `--`: everything after `--` is a URL, so
            // a trailing `-o` would be parsed as one.
            'curl --fail --silent --show-error --location --max-time 20 --output "$1" -- "$2"'
        ].join("\n"), "artfetch", outFile, url]
        // Quickshell reads `command` once when `running` flips, so the
        // arguments must be plain properties rather than bindings that
        // re-evaluate mid-flight.

        onExited: (exitCode, exitStatus) =>
            root.handleArtFetchExit(requestId, url, outFile, exitCode)
    }

    Process {
        id: artCleanupProc
        property string path: ""
        command: ["rm", "-f", "--", path]
    }

    Process {
        id: artPruneProc
        property int keep: 12
        command: ["bash", "-c", root.artPruneScript, "artprune", root.artCacheDir,
            String(keep), root.artPath, root.artFetchPath]
    }

    Timer {
        id: artRetryTimer
        interval: 700
        repeat: false
        onTriggered: root.startArtFetch(root.artRequestId)
    }

    // Re-resolve whenever the advertised art URL changes. This single hook
    // covers both a track change and a player appearing after startup: MPRIS
    // discovery is asynchronous, and a player that shows up already holding an
    // art URL never emits trackArtUrlChanged of its own.
    onRawArtUrlChanged: resolveArt()

    Component.onCompleted: artMkdirProc.running = true

    readonly property color placeholderColor:
        Qt.alpha(theme.accent, theme.dark ? 0.18 : 0.14)

    /* ---- metadata --------------------------------------------------- */

    readonly property string trackTitle: {
        if (!hasPlayer || !player.trackTitle)
            return "Not playing";
        return String(player.trackTitle);
    }

    readonly property string trackArtist: {
        if (!hasPlayer || !player.trackArtist)
            return "";
        return String(player.trackArtist);
    }

    /* ---- position --------------------------------------------------- */

    // MPRIS reports position and length in *seconds*.
    //
    // `position` is deliberately not reactive in Quickshell: reading it is
    // always current, but bindings are only re-evaluated if the change
    // signal fires, which players rarely do. `positionTicker` re-emits it
    // so the seek bar advances.
    readonly property real positionSec:
        hasPlayer ? Number(player.position || 0) : 0
    readonly property real lengthSec:
        hasPlayer ? Number(player.length || 0) : 0

    Timer {
        id: positionTicker
        interval: 500
        repeat: true
        running: root.hasPlayer && root.isPlaying
        onTriggered: {
            if (root.hasPlayer)
                root.player.positionChanged();
        }
    }

    readonly property real progress: {
        if (lengthSec <= 0)
            return 0;
        return Math.max(0, Math.min(1, positionSec / lengthSec));
    }

    function mmss(sec) {
        const total = Math.max(0, Math.floor(sec));
        const hours = Math.floor(total / 3600);
        const minutes = Math.floor((total % 3600) / 60);
        const seconds = total % 60;
        const pad = (n) => (n < 10 ? "0" : "") + n;
        return hours > 0 ? hours + ":" + pad(minutes) + ":" + pad(seconds)
                         : minutes + ":" + pad(seconds);
    }

    /* =================================================================
     * Controls
     *
     * Every write is guarded by the capability flags. Writing an
     * unsupported property is a D-Bus error and leaves the widget
     * looking stuck, so an unsupported control is hidden rather than
     * shown-but-dead.
     * ================================================================= */

    function togglePlay() {
        if (!canTogglePlay)
            return;
        if (player.canTogglePlaying === true) {
            player.togglePlaying();
            return;
        }
        if (isPlaying) {
            if (player.canPause === true)
                player.pause();
        } else if (player.canPlay === true) {
            player.play();
        }
    }

    function previous() {
        if (canGoPrevious)
            player.previous();
    }

    function next() {
        if (canGoNext)
            player.next();
    }

    function seekTo(ratio) {
        if (!canSetPosition || lengthSec <= 0)
            return;
        const target = Math.max(0, Math.min(1, ratio)) * lengthSec;
        player.position = target;
    }

    // Applied live during the drag rather than on release: changing volume
    // is cheap and gives immediate feedback, unlike a seek.
    function setVolume(ratio) {
        if (!canSetVolume)
            return;
        player.volume = Math.max(0, Math.min(1, ratio));
    }

    function toggleShuffle() {
        if (!canToggleShuffle)
            return;
        player.shuffle = player.shuffle !== true;
    }

    // Off -> repeat this track -> repeat the whole queue -> off.
    function cycleLoop() {
        if (!canCycleLoop)
            return;
        const now = player.loopState;
        if (now === MprisLoopState.Track)
            player.loopState = MprisLoopState.Playlist;
        else if (now === MprisLoopState.Playlist)
            player.loopState = MprisLoopState.None;
        else
            player.loopState = MprisLoopState.Track;
    }

    /* =================================================================
     * Window
     * ================================================================= */

    PanelWindow {
        id: card

        visible: root.hasPlayer

        WlrLayershell.layer: WlrLayer.Bottom
        WlrLayershell.exclusionMode: ExclusionMode.Ignore
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.namespace: "mpris-pin"

        color: "transparent"

        // PanelWindow anchors only understand left/right/top/bottom -- there
        // is no horizontalCenter -- so centring is done by deriving the left
        // margin from the screen width. That also makes the card follow the
        // monitor when it is resized or moved.
        anchors {
            bottom: true
            left: true
        }
        margins.left: {
            const w = card.screen ? card.screen.width : 0;
            return w > 0 ? Math.max(0, Math.round((w - root.cardWidth) / 2)) : 0;
        }
        margins.bottom: root.bottomInset

        implicitWidth: root.cardWidth
        implicitHeight: root.cardHeight

        // ---------------- background card ----------------

        Rectangle {
            anchors.fill: parent
            radius: root.cornerRadius
            color: Qt.alpha(root.colSurface, 0.94)
            border.width: 1
            border.color: root.colBorder
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: root.pad
            spacing: 10

            /* ---------------- art + text ---------------- */

            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                Rectangle {
                    Layout.preferredWidth: 72
                    Layout.preferredHeight: 72
                    radius: 10
                    color: root.placeholderColor
                    border.width: 1
                    border.color: root.colBorder
                    clip: true

                    // The box is square and `PreserveAspectCrop` keeps the
                    // cover's own proportions while filling it edge to edge,
                    // so a non-square cover is cropped rather than squashed.
                    // `clip` keeps that crop inside the rounded corners.
                    Image {
                        id: art
                        anchors.fill: parent
                        source: root.artSource
                        asynchronous: true
                        fillMode: Image.PreserveAspectCrop
                        smooth: true
                        mipmap: true
                        visible: status === Image.Ready
                    }

                    // Shown whenever no usable artwork is loaded.
                    Column {
                        anchors.centerIn: parent
                        spacing: 2
                        visible: art.status !== Image.Ready

                        Glyph {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 26
                            height: 26
                            icon: "music"
                            color: root.colAccent
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "no artwork"
                            color: root.colDim
                            font.pixelSize: 9
                        }
                    }

                    /* ---- level meter ----------------------------------
                     * Sits in the artwork's free corner so it costs the
                     * card no extra height.
                     *
                     * Each bar owns its own timer rather than sharing one:
                     * a single shared timer would drive all four through
                     * the same `children[]` array, which QML hands to JS
                     * typed as plain `Item` -- the bars' `target`
                     * property is simply not visible there. Per-bar timers
                     * also stagger the periods, so the bars drift instead
                     * of pulsing in lockstep.
                     * ---------------------------------------------------- */

                    Item {
                        id: eq
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: 6
                        width: eqRow.width
                        height: 13

                        Row {
                            id: eqRow
                            anchors.bottom: parent.bottom
                            spacing: 2

                            Repeater {
                                model: 4

                                delegate: Rectangle {
                                    id: bar
                                    required property int index

                                    readonly property real low: 3
                                    property real target: low

                                    width: 3
                                    // Resting height while paused, so the
                                    // meter falls back to a flat line
                                    // without needing a separate reset.
                                    height: root.isPlaying ? target : low
                                    radius: 1.5
                                    color: root.colAccent

                                    Timer {
                                        interval: 130 + bar.index * 41
                                        repeat: true
                                        running: root.isPlaying
                                        onTriggered: bar.target = bar.low
                                            + Math.random()
                                            * (eq.height - bar.low)
                                    }

                                    Behavior on height {
                                        NumberAnimation {
                                            duration: 170
                                            easing.type: Easing.OutQuad
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 2

                    Text {
                        Layout.fillWidth: true
                        text: root.trackTitle
                        color: root.colText
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                        // Elide instead of letting long titles overflow the
                        // card and collide with the controls.
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }

                    Text {
                        Layout.fillWidth: true
                        text: root.trackArtist
                        color: root.colDim
                        font.pixelSize: 12
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }

                    // Player switcher, only when it would be useful.
                    Row {
                        Layout.fillWidth: true
                        spacing: 4
                        visible: root.allPlayers.length > 1

                        Repeater {
                            model: root.allPlayers

                            delegate: Rectangle {
                                required property int index
                                required property var modelData

                                readonly property bool active: root.player === modelData

                                width: label.implicitWidth + 12
                                height: 18
                                radius: 9
                                color: active ? Qt.alpha(root.colAccent, 0.22) : "transparent"
                                border.width: 1
                                border.color: active ? Qt.alpha(root.colAccent, 0.5) : root.colBorder

                                Text {
                                    id: label
                                    anchors.centerIn: parent
                                    text: (modelData.identity || "player").slice(0, 12)
                                    color: active ? root.colText : root.colDim
                                    font.pixelSize: 9
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.manualIndex = index
                                }
                            }
                        }
                    }

                    Item { Layout.fillHeight: true }
                }
            }

            /* ---------------- seek bar ---------------- */

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4
                visible: root.canSeek && root.lengthSec > 0

                // A hand-rolled bar rather than Slider: Slider writes its own
                // `value` while dragging, which silently destroys the binding
                // to `root.progress`, and the bar then freezes at the drag
                // position forever. Here the fill is a plain ratio and the
                // drag is committed only on release.
                Item {
                    id: seekBar
                    Layout.fillWidth: true
                    Layout.preferredHeight: 14

                    readonly property real ratio: root.canSetPosition
                        ? root.progress : 0
                    property bool dragging: false
                    property real dragRatio: 0

                    readonly property real shown: dragging ? dragRatio : ratio

                    function ratioAt(mx) {
                        const w = Math.max(1, width);
                        return Math.max(0, Math.min(1, mx / w));
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: 4
                        radius: 2
                        color: Qt.alpha(root.colText, 0.16)
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(0, parent.width * seekBar.shown)
                        height: 4
                        radius: 2
                        color: root.colAccent
                    }

                    Rectangle {
                        visible: seekBar.dragging
                        width: 12
                        height: 12
                        radius: 6
                        color: root.colAccent
                        x: Math.max(0, Math.min(seekBar.width - width,
                              seekBar.shown * seekBar.width - width / 2))
                        y: (seekBar.height - height) / 2
                    }

                    MouseArea {
                        id: seekInput
                        anchors.fill: parent
                        enabled: root.canSetPosition
                        cursorShape: root.canSetPosition
                            ? Qt.PointingHandCursor : Qt.ArrowCursor

                        onPressed: function (event) {
                            seekBar.dragging = true;
                            seekBar.dragRatio = seekBar.ratioAt(event.x);
                        }
                        onPositionChanged: function (event) {
                            if (seekBar.dragging)
                                seekBar.dragRatio = seekBar.ratioAt(event.x);
                        }
                        onReleased: function (event) {
                            if (!seekBar.dragging)
                                return;
                            seekBar.dragging = false;
                            root.seekTo(seekBar.dragRatio);
                        }
                        onExited: {
                            // A press that leaves the surface is still a
                            // drag; only cancel is treated as a click.
                        }
                        onCanceled: {
                            seekBar.dragging = false;
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true

                    Text {
                        text: root.mmss(seekBar.dragging
                            ? seekBar.dragRatio * root.lengthSec
                            : root.positionSec)
                        color: root.colDim
                        font.pixelSize: 9
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: root.mmss(root.lengthSec)
                        color: root.colDim
                        font.pixelSize: 9
                    }
                }
            }

            /* ---------------- transport ----------------
             *
             * Shuffle, repeat and volume share the transport row rather
             * than taking rows of their own: the card's height is a fixed
             * constant so the compositor never resizes it, and growing it
             * by ~70px to hold three small controls would occlude far more
             * of the desktop than it is worth. The two fillWidth spacers
             * are still equal, so prev/play/next stay optically centred
             * regardless of which optional controls are present.
             */

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                ControlButton {
                    visible: root.canToggleShuffle
                    icon: "shuffle"
                    small: true
                    active: root.shuffleOn
                    onTriggered: root.toggleShuffle()
                }
                ControlButton {
                    visible: root.canCycleLoop
                    icon: root.loopIcon
                    small: true
                    active: root.loopOn
                    onTriggered: root.cycleLoop()
                }

                Item { Layout.fillWidth: true }

                ControlButton {
                    visible: root.canGoPrevious
                    icon: "skip-back"
                    onTriggered: root.previous()
                }
                ControlButton {
                    visible: root.canTogglePlay
                    icon: root.isPlaying ? "pause" : "play"
                    prominent: true
                    onTriggered: root.togglePlay()
                }
                ControlButton {
                    visible: root.canGoNext
                    icon: "skip-forward"
                    onTriggered: root.next()
                }

                Item { Layout.fillWidth: true }

                Text {
                    visible: root.canSetVolume
                    text: "vol"
                    color: root.colDim
                    font.pixelSize: 8
                }

                VolumeSlider {
                    visible: root.canSetVolume
                    Layout.preferredWidth: 84
                }
            }
        }
    }

    /* =================================================================
     * Live wallpaper
     *
     * A second, independent surface in this same config. It reuses the
     * artwork cache and the track metadata resolved above -- it downloads
     * and resolves nothing of its own -- and renders the current track as
     * the desktop background, with the lyrics advancing as the song plays.
     * ================================================================= */

    LiveWallpaper {
        artSource: root.artSource
        trackTitle: root.trackTitle
        trackArtist: root.trackArtist
        positionSec: root.positionSec
        hasPlayer: root.hasPlayer

        // Deliberately near-white rather than the desktop theme's
        // foreground: the current theme's #d4be98 reads as beige against
        // blurred artwork, and this composition calls for bright white.
        textColor: "#f4f4f7"
        dimColor: "#9a9aa2"
    }

    /* =================================================================
     * Small reusable control
     * ================================================================= */

    component ControlButton: Rectangle {
        id: btn

        // A Lucide icon name, drawn as vector paths. This used to be a
        // `glyph` string of transport characters, but those codepoints are
        // claimed by 50-170 installed fonts each and Qt resolves a font per
        // glyph, so one row could mix several unrelated typefaces.
        property string icon: ""
        property bool prominent: false
        // A latched toggle: shuffle and repeat are *on* without anything
        // moving, so they need a colour of their own to show it.
        property bool active: false
        property bool small: false
        signal triggered()

        implicitWidth: small ? 28 : 32
        implicitHeight: small ? 28 : 32
        radius: small ? 14 : 16

        color: prominent
            ? (hover.hovered ? Qt.lighter(root.colAccent, 1.1) : root.colAccent)
            : (active
               ? Qt.alpha(root.colAccent, hover.hovered ? 0.34 : 0.20)
               : (hover.hovered ? Qt.alpha(root.colText, 0.10)
                               : Qt.alpha(root.colText, 0.04)))
        border.width: prominent ? 0 : 1
        border.color: active ? Qt.alpha(root.colAccent, 0.55) : root.colBorder

        readonly property color glyphColor: prominent ? root.colOnAccent
            : (active ? root.colAccent : root.colText)

        Glyph {
            anchors.centerIn: parent
            width: btn.prominent ? 15 : (btn.small ? 12 : 14)
            height: width
            icon: btn.icon
            color: btn.glyphColor
        }

        HoverHandler {
            id: hover
            cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
            onTapped: btn.triggered()
        }
    }

    /* Hand-rolled for the same reason as the seek bar: Slider writes its
     * own `value` while dragging, which would break the binding to the
     * player's reported volume and freeze the bar at the drag position. */
    component VolumeSlider: Item {
        id: vol

        readonly property real ratio:
            root.canSetVolume ? root.volumeLevel : 0
        property bool dragging: false
        property real dragRatio: 0

        readonly property real shown: dragging ? dragRatio : ratio

        implicitWidth: 84
        implicitHeight: 20

        function ratioAt(mx) {
            const w = Math.max(1, width);
            return Math.max(0, Math.min(1, mx / w));
        }

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 4
            radius: 2
            color: Qt.alpha(root.colText, 0.16)
        }

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, parent.width * vol.shown)
            height: 4
            radius: 2
            color: root.colAccent
        }

        Rectangle {
            width: 10
            height: 10
            radius: 5
            color: root.colAccent
            x: Math.max(0, Math.min(vol.width - width,
                  vol.shown * vol.width - width / 2))
            y: (vol.height - height) / 2
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor

            onPressed: function (event) {
                vol.dragging = true;
                vol.dragRatio = vol.ratioAt(event.x);
                root.setVolume(vol.dragRatio);
            }
            onPositionChanged: function (event) {
                if (!vol.dragging)
                    return;
                vol.dragRatio = vol.ratioAt(event.x);
                root.setVolume(vol.dragRatio);
            }
            onReleased: vol.dragging = false
            onCanceled: vol.dragging = false

            // Wheel over the slider nudges in 5% steps, so the volume is
            // reachable without a drag.
            onWheel: function (event) {
                if (!root.canSetVolume)
                    return;
                const delta = event.angleDelta.y !== 0
                    ? event.angleDelta.y : event.angleDelta.x;
                root.setVolume(root.volumeLevel + (delta > 0 ? 0.05 : -0.05));
                event.accepted = true;
            }
        }
    }
}
