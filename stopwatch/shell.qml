pragma ComponentBehavior: Bound

import QtQml
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

/*
 * stopwatch — stopwatch + countdown timer for Omarchy
 * ---------------------------------------------------
 * A draggable corner widget that toggles between a compact countdown
 * bubble and a full control card.
 *
 * RUN
 *   quickshell -c stopwatch
 *
 * LAYER NOTES
 *   The surface sits on the Bottom layer, not on Background. Background is
 *   where the wallpaper lives, so anything drawn there competes with it and
 *   can be covered by a wallpaper change -- this widget used to do exactly
 *   that and vanished.
 *
 *   The surface size is constant in every state. A layer-shell surface that
 *   changes size is destroyed and recreated by the compositor, which is what
 *   produced the visible flicker while expanding. Collapsed and expanded
 *   share one 288x300 surface and only the contents change; in the collapsed
 *   state every input handler is bounded to the visible bubble so clicks on
 *   the surrounding transparent area reach the desktop.
 */

ShellRoot {
    id: root

    /* =================================================================
     * Configuration
     * ================================================================= */

    // Constant surface size -- never animated, never state-dependent.
    readonly property int panelW: 288
    readonly property int panelH: 300

    readonly property int bubbleSize: 52
    readonly property int pad: 14
    readonly property int radius: 16

    // Keep the bubble on screen even if the display is resized.
    readonly property int edgeMargin: 8

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

        // Omarchy replaces the theme directory and then writes theme.name,
        // so theme.name is the signal that the new files are safe to read.
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
    readonly property color colBorder: Qt.alpha(theme.foreground, 0.12)

    /* =================================================================
     * Persisted state
     * ================================================================= */

    PersistentProperties {
        id: mem
        reloadableId: "stopwatch"

        property int posX: 60
        property int posY: 60
        property bool expanded: false
        property int mode: 0          // 0 = stopwatch, 1 = timer
        property int timerMinutes: 5
    }

    /* =================================================================
     * Timing
     *
     * Elapsed time is derived from wall-clock deltas rather than by adding
     * a tick interval, so a late or skipped tick cannot make the clock
     * drift away from real time.
     * ================================================================= */

    property bool running: false
    property real bankedMs: 0        // time accumulated by previous runs
    property real startedAt: 0       // Date.now() when the current run began
    property var laps: []            // stopwatch lap times in ms

    readonly property real nowMs: running ? (Date.now() - startedAt) : 0
    readonly property real elapsedMs: bankedMs + nowMs

    readonly property int timerTotalMs: mem.timerMinutes * 60 * 1000
    readonly property real timerRemainingMs: Math.max(0, timerTotalMs - elapsedMs)
    readonly property bool timerFinished: mem.mode === 1 && running
        && timerTotalMs > 0 && timerRemainingMs <= 0

    readonly property real timerProgress: {
        if (mem.mode !== 1 || timerTotalMs <= 0)
            return 0;
        return Math.max(0, Math.min(1, 1 - timerRemainingMs / timerTotalMs));
    }

    // Fast enough for centiseconds without burning a core.
    Timer {
        id: tick
        interval: 50
        repeat: true
        running: root.running
        onTriggered: {
            if (root.timerFinished)
                root.stop();
        }
    }

    function start() {
        if (running)
            return;
        // Restarting a finished timer restarts the full duration.
        if (mem.mode === 1 && elapsedMs >= timerTotalMs)
            reset();
        startedAt = Date.now();
        running = true;
    }

    function stop() {
        if (!running)
            return;
        bankedMs += Date.now() - startedAt;
        running = false;
    }

    function toggle() {
        if (running)
            stop();
        else
            start();
    }

    function reset() {
        running = false;
        bankedMs = 0;
        startedAt = 0;
        laps = [];
    }

    function lap() {
        if (mem.mode !== 0)
            return;
        laps = laps.concat([{ index: laps.length + 1, total: elapsedMs }]);
    }

    function setMode(next) {
        if (mem.mode === next)
            return;
        reset();
        mem.mode = next;
    }

    function setTimerMinutes(mins) {
        reset();
        mem.timerMinutes = Math.max(1, Math.min(59, mins));
    }

    /* ---- formatting ------------------------------------------------- */

    function padNum(n, width) {
        let s = String(Math.floor(Math.abs(n)));
        while (s.length < width)
            s = "0" + s;
        return s;
    }

    // Stopwatch: MM:SS.cc, widening to H:MM:SS.cc past an hour.
    readonly property string stopwatchText: {
        const total = Math.max(0, elapsedMs);
        const cs = Math.floor(total / 10) % 100;
        const s = Math.floor(total / 1000) % 60;
        const m = Math.floor(total / 60000);
        const h = Math.floor(m / 60);
        const body = h > 0
            ? h + ":" + padNum(m % 60, 2) + ":" + padNum(s, 2)
            : padNum(m, 2) + ":" + padNum(s, 2);
        return body + "." + padNum(cs, 2);
    }

    // Timer: counts down, and is always shown as M:SS so the width is stable.
    readonly property string timerText: {
        const total = Math.max(0, timerRemainingMs);
        const s = Math.floor(total / 1000);
        return Math.floor(s / 60) + ":" + padNum(s % 60, 2);
    }

    readonly property string bubbleText: {
        if (mem.mode === 1)
            return timerText;
        const total = Math.max(0, elapsedMs);
        const s = Math.floor(total / 1000);
        return Math.floor(s / 60) + ":" + padNum(s % 60, 2);
    }

    function delta(ms) {
        const s = Math.max(0, ms) / 1000;
        const m = Math.floor(s / 60);
        return m + ":" + padNum(s % 60, 2) + "." + padNum((s * 100) % 100, 2);
    }

    // Highlights the bubble when there is something worth noticing.
    readonly property bool alert: {
        if (mem.mode === 1)
            return timerFinished || (running && timerRemainingMs > 0
                && timerRemainingMs <= 10000);
        return running;
    }

    /* =================================================================
     * Dragging
     *
     * Deltas are taken in *global* coordinates. The surface itself is what
     * moves during a drag, so item-relative `event.x` stays pinned under
     * the cursor and the widget would refuse to move. QQuickMouseEvent also
     * exposes no scene coordinates, only x/y, hence the mapToGlobal hop.
     *
     * A press that never travels is a click, not a drag -- that distinction
     * is what lets the bubble open on tap while still being draggable.
     * ================================================================= */

    property bool dragging: false
    property real dragAccum: 0
    property real dragLastX: 0
    property real dragLastY: 0

    function beginDrag(item, event) {
        dragging = true;
        dragAccum = 0;
        const p = item.mapToGlobal(event.x, event.y);
        dragLastX = p.x;
        dragLastY = p.y;
    }

    function updateDrag(item, event) {
        if (!dragging)
            return;
        const p = item.mapToGlobal(event.x, event.y);
        const dx = p.x - dragLastX;
        const dy = p.y - dragLastY;
        dragLastX = p.x;
        dragLastY = p.y;
        dragAccum += Math.abs(dx) + Math.abs(dy);

        const scr = card.screen;
        const limitW = scr ? scr.width : 1920;
        const limitH = scr ? scr.height : 1080;
        // The visible bubble must stay fully on screen; the transparent
        // part of the surface is free to hang off the edge.
        const maxX = Math.max(root.edgeMargin,
            limitW - root.bubbleSize - root.edgeMargin);
        const maxY = Math.max(root.edgeMargin,
            limitH - root.bubbleSize - root.edgeMargin);

        mem.posX = Math.round(Math.max(root.edgeMargin,
            Math.min(maxX, mem.posX + dx)));
        mem.posY = Math.round(Math.max(root.edgeMargin,
            Math.min(maxY, mem.posY + dy)));
    }

    function endDrag() {
        dragging = false;
    }

    // Past a few pixels of travel it counts as a drag, not a click.
    function wasDrag() {
        return dragAccum > 4;
    }

    /* =================================================================
     * Window
     * ================================================================= */

    PanelWindow {
        id: card

        WlrLayershell.layer: WlrLayer.Bottom
        WlrLayershell.exclusionMode: ExclusionMode.Ignore
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.namespace: "stopwatch"

        color: "transparent"

        anchors {
            top: true
            left: true
        }

        margins.left: mem.posX
        margins.top: mem.posY

        // Fixed. See the layer notes at the top of this file.
        implicitWidth: root.panelW
        implicitHeight: root.panelH

        // The surface is always the full panel size, so without this the
        // collapsed widget would silently eat clicks across 288x300 of
        // desktop. Restrict the clickable region to whatever is drawn.
        mask: Region {
            item: mem.expanded ? panel : bubble
        }

        /* ---------------- collapsed bubble ---------------- */

        Item {
            id: bubble
            width: root.bubbleSize
            height: root.bubbleSize
            visible: !mem.expanded

            Rectangle {
                id: bubbleFace
                anchors.fill: parent
                radius: width / 2
                color: Qt.alpha(root.colSurface, 0.94)
                border.width: root.alert ? 2 : 1
                border.color: root.alert
                    ? Qt.alpha(root.colAccent, 0.9) : root.colBorder

                // Only the surface is animated; animating the window's own
                // dimensions is what caused the compositor-level flicker.
                Behavior on border.color {
                    ColorAnimation { duration: 220 }
                }
            }

            Text {
                anchors.centerIn: parent
                text: root.bubbleText
                color: root.alert ? root.colAccent : root.colText
                font.family: "monospace"
                font.pixelSize: 12
                font.weight: Font.DemiBold
                // Keep the label inside the circle for long durations.
                width: parent.width - 6
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.SizeAllCursor

                onPressed: function (event) {
                    root.beginDrag(parent, event);
                }
                onPositionChanged: function (event) {
                    root.updateDrag(parent, event);
                }
                onReleased: {
                    const moved = root.wasDrag();
                    root.endDrag();
                    if (!moved)
                        mem.expanded = true;
                }
                onExited: root.endDrag()
            }
        }

        /* ---------------- expanded card ---------------- */

        Rectangle {
            id: panel
            visible: mem.expanded
            width: root.panelW
            height: root.panelH
            radius: root.radius
            color: Qt.alpha(root.colSurface, 0.97)
            border.width: 1
            border.color: root.colBorder

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: root.pad
                spacing: 10

                /* ---- header ---- */

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    // Drag handle across the header.
                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 26

                        // Declared first so the chips below sit on top of it:
                        // in QML a later sibling wins input, so a drag area
                        // placed after them would swallow every chip click.
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.SizeAllCursor
                            acceptedButtons: Qt.LeftButton

                            onPressed: function (event) {
                                root.beginDrag(parent, event);
                            }
                            onPositionChanged: function (event) {
                                root.updateDrag(parent, event);
                            }
                            onReleased: root.endDrag()
                            onExited: root.endDrag()
                        }

                        Row {
                            anchors.fill: parent
                            spacing: 6

                            Repeater {
                                model: [
                                    { label: "Stopwatch", value: 0 },
                                    { label: "Timer", value: 1 }
                                ]

                                delegate: Rectangle {
                                    required property var modelData

                                    readonly property bool active:
                                        mem.mode === modelData.value

                                    width: chipText.implicitWidth + 18
                                    height: 24
                                    radius: 12
                                    color: active
                                        ? Qt.alpha(root.colAccent, 0.22)
                                        : Qt.alpha(root.colText, 0.05)
                                    border.width: 1
                                    border.color: active
                                        ? Qt.alpha(root.colAccent, 0.55)
                                        : root.colBorder

                                    Text {
                                        id: chipText
                                        anchors.centerIn: parent
                                        text: modelData.label
                                        color: parent.active ? root.colText : root.colDim
                                        font.pixelSize: 11
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.setMode(modelData.value)
                                    }
                                }
                            }
                        }
                    }

                    RoundButton {
                        icon: "x"
                        onTriggered: mem.expanded = false
                    }
                }

                /* ---- readout ---- */

                Text {
                    Layout.fillWidth: true
                    text: mem.mode === 0 ? root.stopwatchText : root.timerText
                    color: root.alert ? root.colAccent : root.colText
                    font.family: "monospace"
                    font.pixelSize: mem.mode === 0 ? 34 : 40
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                }

                /* ---- countdown bar (timer only) ---- */

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 4
                    visible: mem.mode === 1

                    Rectangle {
                        anchors.fill: parent
                        radius: 2
                        color: Qt.alpha(root.colText, 0.16)
                    }
                    Rectangle {
                        width: Math.max(0, parent.width * root.timerProgress)
                        height: parent.height
                        radius: 2
                        color: root.alert ? root.colAccent : root.colDim
                    }
                }

                /* ---- timer presets ---- */

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    visible: mem.mode === 1

                    Repeater {
                        model: [1, 3, 5, 10, 15]
                        delegate: Rectangle {
                            required property int modelData
                            readonly property bool active:
                                mem.timerMinutes === modelData

                            Layout.fillWidth: true
                            Layout.preferredHeight: 26
                            radius: 8
                            color: active
                                ? Qt.alpha(root.colAccent, 0.22)
                                : Qt.alpha(root.colText, 0.05)
                            border.width: 1
                            border.color: active
                                ? Qt.alpha(root.colAccent, 0.55) : root.colBorder

                            Text {
                                anchors.centerIn: parent
                                text: modelData + "m"
                                color: parent.active ? root.colText : root.colDim
                                font.pixelSize: 11
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.setTimerMinutes(modelData)
                            }
                        }
                    }
                }

                /* ---- laps (stopwatch only) ---- */

                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 2
                    visible: mem.mode === 0
                    model: root.laps
                    // Newest lap first, like a real stopwatch.
                    orientation: ListView.Vertical

                    delegate: RowLayout {
                        required property int index
                        required property var modelData

                        width: ListView.view.width
                        height: 20

                        Text {
                            text: "#" + modelData.index
                            color: root.colDim
                            font.pixelSize: 10
                            font.family: "monospace"
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: root.delta(modelData.total)
                            color: root.colText
                            font.pixelSize: 11
                            font.family: "monospace"
                        }
                    }

                    // Show the most recent laps when they overflow.
                    onCountChanged: if (count > 0) positionViewAtBeginning()
                }

                Item {
                    Layout.fillHeight: true
                    visible: mem.mode === 1
                }

                /* ---- transport ---- */

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    RoundButton {
                        Layout.fillWidth: true
                        icon: "rotate-ccw"
                        onTriggered: root.reset()
                    }

                    // Both modes ran or paused identically here -- the old
                    // ternary tested `mem.mode` and then picked the same
                    // glyph either way, so the mode check was dead code.
                    RoundButton {
                        Layout.fillWidth: true
                        icon: root.running ? "square" : "play"
                        prominent: true
                        onTriggered: root.toggle()
                    }

                    RoundButton {
                        Layout.fillWidth: true
                        icon: "plus"
                        visible: mem.mode === 0
                        onTriggered: root.lap()
                    }

                    RoundButton {
                        Layout.fillWidth: true
                        icon: "skip-forward"
                        visible: mem.mode === 1
                        onTriggered: root.setTimerMinutes(mem.timerMinutes + 1)
                    }
                }
            }
        }
    }

    /* =================================================================
     * Small reusable control
     * ================================================================= */

    component RoundButton: Rectangle {
        id: btn

        // A Lucide icon name drawn as vector paths, rather than a
        // transport character. Those codepoints are claimed by 50-170
        // installed fonts each and Qt resolves a font per glyph, so a row
        // of these could otherwise mix several unrelated typefaces.
        property string icon: ""
        property bool prominent: false
        signal triggered()

        implicitWidth: 38
        implicitHeight: 34
        radius: 10
        color: prominent
            ? (hover.hovered ? Qt.lighter(root.colAccent, 1.1) : root.colAccent)
            : (hover.hovered ? Qt.alpha(root.colText, 0.10) : Qt.alpha(root.colText, 0.05))
        border.width: prominent ? 0 : 1
        border.color: root.colBorder

        Glyph {
            anchors.centerIn: parent
            width: btn.prominent ? 17 : 15
            height: width
            icon: btn.icon
            color: btn.prominent ? root.colOnAccent : root.colText
        }

        HoverHandler {
            id: hover
            cursorShape: Qt.PointingHandCursor
        }

        TapHandler {
            onTapped: btn.triggered()
        }
    }
}
