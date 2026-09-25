// shell.qml — standalone ChronoWidget (stopwatch / timer) for Hyprland,
// built on plain Quickshell. Single-file version.
//
// Design notes vs. the original two-file version:
//   - DRAG FIX: dragging used to write `posX`/`posY` into a
//     PersistentProperties object on every single pixel of movement, which
//     forces a disk write on every frame -> visible stutter. Now the drag
//     target is a plain, non-persisted Item; the position is only written
//     back to the persisted store once, when the drag finishes.
//   - RESTYLE: matches Caelestia's MPRIS/media widget — Material 3
//     tonal / filled icon buttons with hover + press state layers and
//     shape-morphing corners, the same colour roles (primary,
//     secondaryContainer, onSurfaceVariant ...) and no card border.
//   - ICONS: no emoji or unicode glyphs. Every icon is a vector path drawn
//     by the `Glyph` component and tinted from the scheme, so it always
//     matches the theme and needs no icon font.
//   - MERGE: ChronoWidget is now an inline `component` inside this file,
//     so there's only one file to ship/copy.
//
// This is a fully standalone module — it does NOT hook into the Caelestia
// shell. It only *optionally* reads the colour file that
// `caelestia scheme set` writes to, purely as a theme source. If that file
// doesn't exist, it falls back to a built-in dark palette.
//
// SETUP
//   1. Put this file in its own directory:
//        ~/.config/quickshell/chrono/shell.qml
//   2. Run it standalone: qs -c chrono
//   3. To start it with Hyprland, in your Hyprland config:
//        exec-once = qs -c chrono
//   4. To stop/reload just this widget:
//        qs -c chrono kill
//        qs -c chrono -d   (restart in the foreground, for debugging)
//   5. For real background blur, add a Hyprland layer rule:
//        layerrule = blur, chrono-widget
//        layerrule = ignorezero, chrono-widget
//   6. Delete/adjust the theme-file `path` in the FileView below if you're
//      not using Caelestia, or point it at whatever colour-scheme JSON you use.

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    // ---- Icon set (24x24 grid, tinted from the theme) -------------------
    component Glyph: Item {
        id: g
        property string name
        property color color: "white"
        property real size: 22
        property bool filled: false      // outline -> filled variant (toggles)

        width: size; height: size
        layer.enabled: true
        layer.samples: 4

        // [stroked path, filled path]
        function def(n, on) {
            switch (n) {
            case "play":
                return ["", "M8 5.5v13a1 1 0 0 0 1.5.86l10.5-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5z"];
            case "pause":
                return ["", "M7 5.5a1.5 1.5 0 0 1 3 0v13a1.5 1.5 0 0 1-3 0z M14 5.5a1.5 1.5 0 0 1 3 0v13a1.5 1.5 0 0 1-3 0z"];
            case "reset":
                return ["M8.5 5.94A7 7 0 1 0 18.06 8.5", "M20.3 7.2L15.8 9.8L16.46 5.73z"];
            case "flag":
                return ["M6 20.5V4", "M6.5 5h11.2a.8.8 0 0 1 .6 1.3L15.5 9.5l2.8 3.2a.8.8 0 0 1-.6 1.3H6.5z"];
            case "pin": {
                var head = "M9 4h6l-.8 6.2L17 13v2H7v-2l2.8-2.8z";
                return on ? ["M12 15v5.5", head] : [head + " M12 15v5.5", ""];
            }
            case "swap":
                return ["M5 8.5h14M15.5 5l3.5 3.5-3.5 3.5M19 15.5H5M8.5 12L5 15.5 8.5 19", ""];
            case "chevron":
                return ["M6.5 9.5l5.5 5.5 5.5-5.5", ""];
            case "stopwatch":
                return ["M12 21a7.5 7.5 0 1 0 0-15 7.5 7.5 0 0 0 0 15z M9.5 2.5h5 M12 2.5V6 M12 13.5l2.8-2.8", ""];
            case "hourglass":
                return ["M7 3.5h10 M7 20.5h10 M8 3.5c0 4.5 3 5.5 4 8.5-1 3-4 4-4 8.5 M16 3.5c0 4.5-3 5.5-4 8.5 1 3 4 4 4 8.5", ""];
            }
            return ["", ""];
        }
        readonly property var d: def(name, filled)

        Shape {
            width: 24; height: 24
            scale: g.size / 24
            transformOrigin: Item.TopLeft

            ShapePath {
                strokeColor: g.color
                strokeWidth: 2
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: g.d[0] || "M0 0" }
            }
            ShapePath {
                strokeColor: "transparent"
                fillColor: g.color
                PathSvg { path: g.d[1] || "M0 0" }
            }
        }
    }

    // ---- Icon button: mirrors Caelestia's IconButton (Filled / Tonal / Text)
    component IconBtn: Item {
        id: b
        required property var pal
        property string glyph
        property string kind: "tonal"    // "filled" | "tonal" | "text"
        property bool toggle: false      // toggles get an active colour + filled icon
        property bool checked: false     // active state (also morphs the corners)
        property real glyphSize: 22
        readonly property bool pressed: ma.pressed
        signal clicked()

        readonly property bool active: toggle && checked
        readonly property color bgColor: kind === "text" ? "transparent"
            : kind === "filled" ? pal.primary
            : active ? pal.secondary : pal.secondaryContainer
        readonly property color fgColor: kind === "filled" ? pal.onPrimary
            : kind === "tonal" ? (active ? pal.onSecondary : pal.onSecondaryContainer)
            : (active ? pal.primary : pal.onSurfaceVariant)

        opacity: enabled ? 1 : 0.38

        Rectangle {
            id: bg
            anchors.fill: parent
            color: b.bgColor
            radius: b.pressed ? 12 : b.checked ? 16 : b.height / 2
            Behavior on radius { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 150 } }
        }
        // state layer (hover 8%, press 10%, same as Caelestia)
        Rectangle {
            anchors.fill: parent
            radius: bg.radius
            color: b.fgColor
            opacity: ma.pressed ? 0.10 : ma.containsMouse ? 0.08 : 0
            Behavior on opacity { NumberAnimation { duration: 100 } }
        }
        Glyph {
            anchors.centerIn: parent
            name: b.glyph
            size: b.glyphSize
            color: b.fgColor
            filled: !b.toggle || b.checked
        }
        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: b.clicked()
        }
    }

    // ---- Small pill button (timer +/- steps, "Clear") -------------------
    component Chip: Item {
        id: c
        required property var pal
        property string label
        property bool tonal: true
        signal clicked()

        implicitWidth: txt.implicitWidth + 20
        implicitHeight: 24
        width: implicitWidth; height: implicitHeight

        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: c.tonal ? c.pal.secondaryContainer : "transparent"
        }
        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: c.tonal ? c.pal.onSecondaryContainer : c.pal.primary
            opacity: cma.pressed ? 0.10 : cma.containsMouse ? 0.08 : 0
        }
        Text {
            id: txt
            anchors.centerIn: parent
            text: c.label
            color: c.pal.primary
            font.pixelSize: 11
            font.weight: Font.Medium
        }
        MouseArea {
            id: cma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: c.clicked()
        }
    }

    component ChronoWidget: PanelWindow {
        id: root

        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.exclusionMode: ExclusionMode.Ignore
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.namespace: "chrono-widget"

        color: "transparent"

        anchors {
            top: true
            left: true
        }

        // ---- persisted bits (survive a `qs -c` config reload) --------------
        PersistentProperties {
            id: mem
            reloadableId: "chronoWidget"

            property real posX: 60
            property real posY: 60
            property int mode: 0        // 0 = stopwatch, 1 = timer
            property bool pinned: false
            property int timerDurationMs: 5 * 60 * 1000
        }

        // ---- position: bound to the persisted store, dragged by delta --------
        margins.left: mem.posX
        margins.top: mem.posY

        // Drag options (off by default — same behaviour as before unless
        // you turn clampToScreen on).
        property bool clampToScreen: false
        property int snapDistance: 14
        property int edgeGap: 8

        // Relative move used by dragging. Mutates `margins` directly every
        // frame (cheap, no extra binding hop through a proxy item) and
        // never touches the persisted `mem` store mid-drag — only
        // commitPosition() (called once, on release) writes back to disk.
        // That's what fixes the stutter: a disk write on every pixel of
        // movement is what caused it before.
        function moveBy(dx, dy) {
            var l = root.margins.left + dx;
            var t = root.margins.top + dy;

            if (clampToScreen && root.screen && root.screen.width > 0) {
                var minL = edgeGap, maxL = root.screen.width - root.width - edgeGap;
                var minT = edgeGap, maxT = root.screen.height - root.height - edgeGap;

                if (Math.abs(l - minL) < snapDistance) l = minL;
                if (Math.abs(l - maxL) < snapDistance) l = maxL;
                if (Math.abs(t - minT) < snapDistance) t = minT;
                if (Math.abs(t - maxT) < snapDistance) t = maxT;

                l = Math.max(minL, Math.min(maxL, l));
                t = Math.max(minT, Math.min(maxT, t));
            }

            root.margins.left = l;
            root.margins.top = t;
        }

        function commitPosition() {
            mem.posX = root.margins.left;
            mem.posY = root.margins.top;
        }

        // ---- optional external colour scheme (Caelestia's scheme.json, or none) ----
        readonly property string stateDir:
            Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")
        readonly property string schemePath: stateDir + "/caelestia/scheme.json"

        QtObject {
            id: pal
            // Raw "colours" map from scheme.json (hex strings, no '#').
            property var sch: ({})

            function c(role, fallback) {
                var v = sch[role];
                if (v === undefined || v === null || v === "") return fallback;
                return v.toString().charAt(0) === "#" ? v : ("#" + v);
            }

            // ---- theme polarity ---------------------------------------------
            // Simple rule: dark card -> light text, light card -> dark text.
            function lum(col) { return 0.299 * col.r + 0.587 * col.g + 0.114 * col.b; }

            // Raw roles straight from the scheme (or the fallback palette).
            property color background: c("background", "#1b1d24")
            property color surface: c("surfaceContainer", c("surface", "#232530"))
            property color surfaceHigh: c("surfaceContainerHigh", c("surfaceVariant", "#2b2e39"))
            property color outline: c("outline", "#8b8d98")
            property color secondary: c("secondary", "#bcc7dc")
            property color secondaryContainer: c("secondaryContainer", "#3d4759")
            property color rawPrimary: c("primary", "#a6c8ff")

            // true when the card/disc surfaces are dark
            readonly property bool dark: lum(surface) < 0.5

            // Text drawn straight on the card / disc / lap box.
            // (all text now uses the accent colour instead — set below)

            // Accent (icons, ring, "Clear"): keep the scheme hue, but make
            // sure it is light enough on dark cards / dark enough on light ones.
            property color primary: dark
                ? (lum(rawPrimary) >= 0.55 ? rawPrimary : Qt.lighter(rawPrimary, 1.0 + (0.55 - lum(rawPrimary)) * 3.5))
                : (lum(rawPrimary) <= 0.4 ? rawPrimary : Qt.darker(rawPrimary, 1.0 + (lum(rawPrimary) - 0.4) * 3.5))

            // Text on coloured buttons: pick by the button's own luminance.
            property color onPrimary: lum(primary) > 0.5 ? "#101015" : "#ffffff"
            property color onSecondary: lum(secondary) > 0.5 ? "#101015" : "#ffffff"
            property color onSecondaryContainer: lum(secondaryContainer) > 0.5 ? "#101015" : "#f4f4fa"

            // Text = accent colour. Secondary text is the same accent, softened.
            property color onSurface: primary
            property color onSurfaceVariant: Qt.rgba(primary.r, primary.g, primary.b, 0.75)
            property color muted: onSurfaceVariant
        }

        // Watches the scheme file and reloads whenever `caelestia scheme
        // set` (or the dynamic wallpaper-scheme writer) touches it, so
        // every colour in `pal` updates live, in place, with no restart.
        // Reading via onLoaded (rather than binding straight to a `text`
        // property) means we only parse once the read has actually
        // finished, and onLoadFailed gives us a clear signal — and a log
        // line — when the file is missing instead of silently keeping
        // stale colours forever.
        FileView {
            id: schemeFile
            path: root.schemePath
            watchChanges: true
            onFileChanged: reload()
            onLoaded: {
                try {
                    const data = JSON.parse(text());
                    // Accept either `{ colours: {...} }` (Caelestia's
                    // usual shape) or a flat `{ primary: ..., ... }` file.
                    pal.sch = (data && data.colours) ? data.colours : (data || {});
                } catch (e) {
                    // Can happen if we read mid-write; keep the last good
                    // scheme, the next change event will fix it.
                    console.warn("[chrono-widget] could not parse scheme.json:", e);
                }
            }
            onLoadFailed: (error) => {
                console.warn("[chrono-widget] could not read", root.schemePath, error);
            }
        }

        // ---- expand / collapse -----------------------------------------------
        property bool running: false
        property bool manualOpen: false

        // Expansion is controlled only by the UI toggle/pin state.
        // Starting, pausing, or resetting the stopwatch must not close it.
        property bool expanded: manualOpen || mem.pinned

        implicitWidth: expanded ? 288 : 52
        implicitHeight: expanded ? content.implicitHeight + 36 : 52
        Behavior on implicitWidth { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Behavior on implicitHeight { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        // ---- stopwatch state --------------------------------------------------
        property real swStartedAt: 0
        property real swAccumMs: 0
        property real swElapsedMs: 0
        property var laps: []

        // ---- timer state --------------------------------------------------
        property real tmEndAt: 0
        property real tmRemainingMs: mem.timerDurationMs
        property bool tmFinished: false

        Timer {
            interval: 16
            running: root.running
            repeat: true
            onTriggered: {
                if (mem.mode === 0) {
                    root.swElapsedMs = root.swAccumMs + (Date.now() - root.swStartedAt);
                } else {
                    var rem = root.tmEndAt - Date.now();
                    if (rem <= 0) {
                        root.tmRemainingMs = 0;
                        root.running = false;
                        root.tmFinished = true;
                    } else {
                        root.tmRemainingMs = rem;
                    }
                }
            }
        }

        function fmt(ms, withHour) {
            var h = Math.floor(ms / 3600000);
            var m = Math.floor((ms % 3600000) / 60000);
            var s = Math.floor((ms % 60000) / 1000);
            var cs = Math.floor((ms % 1000) / 10);
            function pad(n) { return (n < 10 ? "0" : "") + n; }
            return (withHour ? pad(h) + ":" : "") + pad(m) + ":" + pad(s) + "." + pad(cs);
        }

        function toggleStart() {
            if (mem.mode === 0) {
                if (root.running) {
                    root.swAccumMs = root.swElapsedMs;
                    root.running = false;
                } else {
                    root.swStartedAt = Date.now();
                    root.running = true;
                }
            } else {
                if (root.tmRemainingMs <= 0) return;
                if (root.running) {
                    root.tmRemainingMs = root.tmEndAt - Date.now();
                    root.running = false;
                } else {
                    root.tmFinished = false;
                    root.tmEndAt = Date.now() + root.tmRemainingMs;
                    root.running = true;
                }
            }
        }

        function reset() {
            root.running = false;
            if (mem.mode === 0) {
                root.swAccumMs = 0; root.swElapsedMs = 0; root.laps = [];
            } else {
                root.tmFinished = false;
                root.tmRemainingMs = mem.timerDurationMs;
            }
        }

        function lap() {
            if (mem.mode !== 0 || !root.running) return;
            var l = root.laps.slice();
            l.push(root.swElapsedMs);
            root.laps = l;
        }

        function adjustTimer(deltaMs) {
            if (root.running) return;
            mem.timerDurationMs = Math.max(0, Math.min(99 * 3600000, mem.timerDurationMs + deltaMs));
            root.tmRemainingMs = mem.timerDurationMs;
        }

        // ================= UI =================
        Rectangle {
            id: card
            anchors.fill: parent
            radius: root.expanded ? 24 : height / 2
            color: Qt.rgba(pal.surface.r, pal.surface.g, pal.surface.b, 0.94)
            Behavior on radius { NumberAnimation { duration: 160 } }

            // ---------------- collapsed icon ----------------
            MouseArea {
                anchors.fill: parent
                visible: !root.expanded
                enabled: !root.expanded && !mem.pinned
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor

                property real pressX: 0
                property real pressY: 0
                property real travel: 0   // total pointer travel, to tell a click from a drag

                onPressed: (mouse) => { pressX = mouse.x; pressY = mouse.y; travel = 0; }
                onPositionChanged: (mouse) => {
                    if (!pressed) return;
                    var dx = mouse.x - pressX, dy = mouse.y - pressY;
                    travel += Math.abs(dx) + Math.abs(dy);
                    root.moveBy(dx, dy);
                }
                onReleased: {
                    root.commitPosition();
                    if (travel <= 4) root.manualOpen = !root.manualOpen;
                }

                Rectangle {
                    anchors.fill: parent
                    radius: card.radius
                    color: pal.primary
                    opacity: parent.pressed ? 0.10 : parent.containsMouse ? 0.08 : 0
                }
                Glyph {
                    anchors.centerIn: parent
                    name: mem.mode === 0 ? "stopwatch" : "hourglass"
                    color: pal.primary
                    size: 24
                }
            }

            // ---------------- expanded panel ----------------
            Column {
                id: content
                visible: root.expanded
                anchors.fill: parent
                anchors.margins: 18
                spacing: 14

                // header
                Item {
                    width: parent.width
                    height: 32

                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8
                        Glyph {
                            anchors.verticalCenter: parent.verticalCenter
                            name: mem.mode === 0 ? "stopwatch" : "hourglass"
                            color: pal.primary
                            size: 20
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: mem.mode === 0 ? "Stopwatch" : "Timer"
                            color: pal.primary
                            font.pixelSize: 16
                            font.weight: Font.Medium
                        }
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        IconBtn {
                            pal: pal
                            width: 32; height: 32
                            kind: "text"; toggle: true
                            glyph: "pin"; glyphSize: 20
                            checked: mem.pinned
                            onClicked: mem.pinned = !mem.pinned
                        }
                        IconBtn {
                            pal: pal
                            width: 32; height: 32
                            kind: "text"
                            glyph: "swap"; glyphSize: 20
                            visible: !root.running
                            onClicked: mem.mode = mem.mode === 0 ? 1 : 0
                        }
                        IconBtn {
                            pal: pal
                            width: 32; height: 32
                            kind: "text"
                            glyph: "chevron"; glyphSize: 20
                            onClicked: { root.manualOpen = false; mem.pinned = false }
                        }
                    }
                }

                // ring + digits
                Item {
                    width: parent.width
                    height: 196

                    Shape {
                        id: ring
                        anchors.centerIn: parent
                        width: 188; height: 188
                        layer.enabled: true
                        layer.samples: 4
                        property real frac: mem.mode === 0
                            ? ((root.swElapsedMs % 60000) / 60000)
                            : (mem.timerDurationMs > 0 ? root.tmRemainingMs / mem.timerDurationMs : 0)

                        ShapePath {
                            strokeWidth: 6
                            strokeColor: pal.secondaryContainer
                            fillColor: "transparent"
                            PathAngleArc {
                                centerX: 94; centerY: 94
                                radiusX: 91; radiusY: 91
                                startAngle: -90; sweepAngle: 360
                            }
                        }
                        ShapePath {
                            strokeWidth: 6
                            strokeColor: pal.primary
                            fillColor: "transparent"
                            capStyle: ShapePath.RoundCap
                            PathAngleArc {
                                centerX: 94; centerY: 94
                                radiusX: 91; radiusY: 91
                                startAngle: -90
                                sweepAngle: mem.mode === 0 ? 360 * ring.frac : -360 * (1 - ring.frac)
                            }
                        }
                    }

                    // "cover art" disc the digits sit on
                    Rectangle {
                        anchors.centerIn: parent
                        width: 168; height: 168; radius: 84
                        color: pal.surfaceHigh
                    }

                    Column {
                        anchors.centerIn: parent
                        spacing: 8
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 134
                            horizontalAlignment: Text.AlignHCenter
                            text: mem.mode === 0 ? root.fmt(root.swElapsedMs, root.swElapsedMs >= 3600000) : root.fmt(root.tmRemainingMs, mem.timerDurationMs >= 3600000)
                            color: pal.primary
                            font.pixelSize: 30
                            font.bold: true
                            font.family: "monospace"
                            fontSizeMode: Text.Fit
                            minimumPixelSize: 16
                        }
                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: 6
                            visible: mem.mode === 1 && !root.running
                            Column {
                                spacing: 4
                                Chip { pal: pal; width: 46; label: "+1m"; onClicked: root.adjustTimer(60000) }
                                Chip { pal: pal; width: 46; label: "−1m"; onClicked: root.adjustTimer(-60000) }
                            }
                            Column {
                                spacing: 4
                                Chip { pal: pal; width: 46; label: "+10s"; onClicked: root.adjustTimer(10000) }
                                Chip { pal: pal; width: 46; label: "−10s"; onClicked: root.adjustTimer(-10000) }
                            }
                        }
                    }
                }

                // controls — same layout as the MPRIS button row:
                // tonal | filled (stretches, morphs while active) | tonal
                Row {
                    width: parent.width
                    height: 56
                    spacing: 4

                    IconBtn {
                        pal: pal
                        width: 56; height: 56
                        kind: "tonal"
                        glyph: "reset"
                        onClicked: root.reset()
                    }
                    IconBtn {
                        pal: pal
                        width: parent.width - 56 * 2 - 4 * 2; height: 56
                        kind: "filled"
                        checked: root.running
                        glyph: root.running ? "pause" : "play"
                        onClicked: root.toggleStart()
                    }
                    IconBtn {
                        pal: pal
                        width: 56; height: 56
                        kind: "tonal"
                        glyph: "flag"
                        enabled: mem.mode === 0
                        onClicked: root.lap()
                    }
                }

                // laps
                Rectangle {
                    width: parent.width
                    height: 12 + 24 + 4 + 66 + 12
                    radius: 16
                    color: pal.surfaceHigh
                    visible: mem.mode === 0 && root.laps.length > 0

                    Item {
                        anchors.fill: parent
                        anchors.margins: 12

                        Item {
                            id: lapHeader
                            width: parent.width
                            height: 24
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Laps"
                                color: pal.primary
                                font.pixelSize: 12
                                font.weight: Font.Medium
                            }
                            Chip {
                                pal: pal
                                anchors.right: parent.right
                                tonal: false
                                label: "Clear"
                                onClicked: root.laps = []
                            }
                        }

                        ListView {
                            anchors.top: lapHeader.bottom
                            anchors.topMargin: 4
                            width: parent.width
                            height: 66
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            model: root.laps.slice().reverse()
                            delegate: Item {
                                width: ListView.view.width
                                height: 22
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "#" + (root.laps.length - index)
                                    color: pal.primary
                                    font.pixelSize: 12
                                }
                                Text {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root.fmt(modelData, false)
                                    color: pal.primary
                                    font.pixelSize: 12
                                    font.family: "monospace"
                                }
                            }
                        }
                    }
                }
            }

            // drag surface for the expanded panel — sits under the content
            // (z: -1) so buttons/rings still get clicks; commits position
            // once per drag instead of every frame.
            MouseArea {
                anchors.fill: parent
                visible: root.expanded
                enabled: !mem.pinned
                z: -1
                propagateComposedEvents: true

                property real pressX: 0
                property real pressY: 0

                onPressed: (mouse) => { pressX = mouse.x; pressY = mouse.y; }
                onPositionChanged: (mouse) => {
                    if (!pressed) return;
                    root.moveBy(mouse.x - pressX, mouse.y - pressY);
                }
                onReleased: root.commitPosition()
            }
        }
    }

    ChronoWidget {}
}
