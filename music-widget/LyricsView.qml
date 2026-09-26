pragma ComponentBehavior: Bound

import QtQuick

/*
 * LyricsView — the scrolling lyric column
 * ---------------------------------------
 * Shows a window of lines around the one currently being sung. The active
 * line stays in a fixed focal band while the surrounding lines move past
 * it, so the column reads as a continuously scrolling viewport rather than
 * a set of pages that jump.
 *
 * WHY ONE DELEGATE PER LINE
 *   The model is the track's full lyric list and does not change while the
 *   track plays. Only the y, opacity and size *bindings* move when the
 *   active line advances, so the rows are animated rather than rebuilt. A
 *   windowed model would be rebuilt on every line change and the scroll
 *   would jump instead of easing.
 */

Item {
    id: view

    // ---- inputs ---------------------------------------------------------

    // Records of { t: <seconds>, text: <line> }, ascending.
    property var lines: []
    property real positionSec: 0

    // How many lines to show either side of the active one.
    property int window: 4

    // ---- responsive type ------------------------------------------------
    //
    // Everything is derived from the column's own width rather than fixed in
    // pixels, so the composition holds on a 13" laptop and a 4K monitor
    // alike. The floors stop the type from becoming unreadably small on a
    // narrow screen.

    readonly property real activeSize: Math.max(30, width * 0.052)
    readonly property real nearSize: Math.max(21, width * 0.034)
    readonly property real farSize: Math.max(18, width * 0.028)
    readonly property real gap: Math.max(14, width * 0.024)

    readonly property real pillPadH: Math.max(18, width * 0.033)
    readonly property real pillPadV: Math.max(8, width * 0.013)
    readonly property real pillRadius: Math.max(12, activeSize * 0.44)

    property color textColor: "#ffffff"
    property real pillOpacity: 0.10
    property real duration: 420

    // ---- derived --------------------------------------------------------

    // Index of the last line at or before the playhead. Before the first
    // stamp nothing is being sung yet, so the first line is used.
    readonly property int activeIndex: {
        if (!lines || lines.length === 0)
            return -1;
        const at = Math.max(0, positionSec);
        let found = 0;
        for (let i = 0; i < lines.length; i++) {
            if (lines[i].t <= at)
                found = i;
            else
                break;
        }
        return found;
    }

    readonly property bool hasActive: activeIndex >= 0

    // Where the focal band sits vertically inside the column. Slightly above
    // centre reads better than dead centre, because the eye lands on the
    // upper third of a screen more naturally.
    readonly property real focalY: height * 0.46

    readonly property real rowHeight: activeSize + gap

    // Opacity falls off with distance and never quite reaches zero, so the
    // column keeps a sense of what comes next.
    function opacityForDistance(distance) {
        const d = Math.abs(distance);
        if (d === 0)
            return 1.0;
        if (d === 1)
            return 0.45;
        if (d === 2)
            return 0.30;
        if (d === 3)
            return 0.20;
        return 0.12;
    }

    function sizeForDistance(distance) {
        const d = Math.abs(distance);
        if (d === 0)
            return activeSize;
        if (d === 1)
            return nearSize;
        if (d === 4)
            return farSize - 2;
        return farSize;
    }

    /* =================================================================
     * Column
     * ================================================================= */

    Repeater {
        model: view.lines

        delegate: Item {
            id: row

            required property int index
            required property var modelData

            readonly property int distance: index - view.activeIndex
            readonly property bool isActive: distance === 0
            readonly property bool inWindow:
                view.hasActive && distance >= -view.window && distance <= view.window

            // The active line sits exactly on the focal centre; the others
            // are offset from it by whole row heights.
            y: view.focalY + distance * view.rowHeight
            width: view.width
            height: Math.max(view.activeSize, sizeForDistance(distance)) + 8

            visible: inWindow
            opacity: opacityForDistance(distance)

            Behavior on y {
                NumberAnimation {
                    duration: view.duration
                    // Decelerating: the column settles rather than gliding
                    // to a stop, which suits a slow lyric.
                    easing.type: Easing.OutQuint
                }
            }

            Behavior on opacity {
                NumberAnimation { duration: view.duration }
            }

            // ---- glass pill behind the active line ----

            Rectangle {
                id: pill
                anchors.verticalCenter: parent.verticalCenter
                x: -view.pillPadH
                // Width tracks the text, so a short line gets a short pill
                // instead of a full-width bar.
                width: label.implicitWidth + view.pillPadH * 2
                height: label.implicitHeight + view.pillPadV * 2
                radius: view.pillRadius
                color: Qt.alpha("#ffffff", view.pillOpacity)
                border.width: 1
                border.color: Qt.alpha("#ffffff", 0.14)

                // The pill and its text travel together, so the highlight
                // appears to move with the line rather than cross-fading in
                // place.
                opacity: row.isActive ? 1 : 0
                Behavior on opacity {
                    NumberAnimation { duration: view.duration }
                }
            }

            // ---- the line itself ----

            Text {
                id: label
                anchors.verticalCenter: parent.verticalCenter
                x: 0
                text: row.modelData.text
                color: view.textColor
                font.pixelSize: view.sizeForDistance(row.distance)
                font.weight: row.isActive ? Font.Bold : Font.Medium

                // Wrapping is off: a lyric is a phrase, and a single
                // unbroken line is what the reference composition uses.
                // Elide rather than overflow the column.
                elide: Text.ElideRight
                maximumLineCount: 1
                width: Math.min(implicitWidth, view.width)
            }
        }
    }
}
