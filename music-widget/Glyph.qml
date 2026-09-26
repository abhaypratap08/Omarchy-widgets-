pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes

/*
 * Glyph — one vector icon, drawn rather than typeset
 * -------------------------------------------------
 * These paths come from Lucide (https://lucide.dev), ISC licensed:
 *
 *   Copyright (c) for portions of Lucide are held by Cole Bemis
 *   2013-2023 as part of Feather (MIT). All other copyright (c)
 *   for portions of Lucide are held by Lucide Contributors 2025.
 *
 * They replace emoji for a reason that is not cosmetic. The transport
 * characters this widget used to draw (U+23EE, U+25B6, U+266B and
 * friends) are claimed by 50-170 installed fonts each, and Qt resolves a
 * font per glyph, so one row of buttons could mix Adwaita Mono, Iosevka,
 * Caskaydia and Noto CJK shapes side by side. These paths are identical on
 * every machine and inherit the theme colour, so they cannot drift from
 * the rest of the card.
 *
 * Every icon is authored on Lucide's 24x24 grid with a 2-unit stroke and
 * scaled to fit. `weight` is in grid units, so the stroke stays
 * proportional at any size.
 */

Item {
    id: glyph

    // One of: play, pause, skip-back, skip-forward, shuffle, repeat,
    // infinity, music, rotate-ccw, x, plus, square.
    property string icon: ""
    property color color: "#ffffff"

    // Stroke width in 24-unit grid space. Lucide's default is 2.
    property real weight: 2

    implicitWidth: 16
    implicitHeight: 16

    // Lucide draws play, pause and square as closed silhouettes rather
    // than outlines, so stroking them alone would leave a hollow triangle
    // or a pair of outlined bars. Those three are filled instead.
    readonly property bool solid: icon === "play"
        || icon === "pause" || icon === "square"

    readonly property var library: ({
        "play": [
            { d: "M5 5a2 2 0 0 1 3.008-1.728l11.997 6.998a2 2 0 0 1 .003 3.458l-12 7A2 2 0 0 1 5 19z" }
        ],
        "pause": [
            { rect: [5, 3, 5, 18, 1] },
            { rect: [14, 3, 5, 18, 1] }
        ],
        "skip-back": [
            { d: "M17.971 4.285A2 2 0 0 1 21 6v12a2 2 0 0 1-3.029 1.715l-9.997-5.998a2 2 0 0 1-.003-3.432z" },
            { d: "M3 20V4" }
        ],
        "skip-forward": [
            { d: "M21 4v16" },
            { d: "M6.029 4.285A2 2 0 0 0 3 6v12a2 2 0 0 0 3.029 1.715l9.997-5.998a2 2 0 0 0 .003-3.432z" }
        ],
        "shuffle": [
            { d: "m18 14 4 4-4 4" },
            { d: "m18 2 4 4-4 4" },
            { d: "M2 18h1.973a4 4 0 0 0 3.3-1.7l5.454-8.6a4 4 0 0 1 3.3-1.7H22" },
            { d: "M2 6h1.972a4 4 0 0 1 3.6 2.2" },
            { d: "M22 18h-6.041a4 4 0 0 1-3.3-1.8l-.359-.45" }
        ],
        "repeat": [
            { d: "m17 2 4 4-4 4" },
            { d: "M3 11v-1a4 4 0 0 1 4-4h14" },
            { d: "m7 22-4-4 4-4" },
            { d: "M21 13v1a4 4 0 0 1-4 4H3" }
        ],
        // The trailing "M11 10h1v4" is the numeral 1, drawn as a path so
        // repeat-one needs no text badge.
        "repeat-1": [
            { d: "m17 2 4 4-4 4" },
            { d: "M3 11v-1a4 4 0 0 1 4-4h14" },
            { d: "m7 22-4-4 4-4" },
            { d: "M21 13v1a4 4 0 0 1-4 4H3" },
            { d: "M11 10h1v4" }
        ],
        "infinity": [
            { d: "M6 16c5 0 7-8 12-8a4 4 0 0 1 0 8c-5 0-7-8-12-8a4 4 0 0 0 0 8" }
        ],
        "music": [
            { d: "M9 18V5l12-2v13" },
            { circle: [6, 18, 3] },
            { circle: [18, 16, 3] }
        ],
        "rotate-ccw": [
            { d: "M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8" },
            { d: "M3 3v5h5" }
        ],
        "x": [
            { d: "M18 6 6 18" },
            { d: "m6 6 12 12" }
        ],
        "plus": [
            { d: "M5 12h14" },
            { d: "M12 5v14" }
        ],
        "square": [
            { rect: [3, 3, 18, 18, 2] }
        ]
    })

    readonly property var parts:
        library[icon] !== undefined ? library[icon] : []

    // The most parts any single icon uses is five (shuffle). A fixed pool of
    // ShapePaths is bound to these accessors because a Repeater delegate
    // must be an Item, and ShapePath is not one.
    readonly property int partCount: parts.length

    function pathAt(i) {
        const p = glyph.parts;
        if (i >= p.length)
            return "";
        const entry = p[i];
        if (entry.d !== undefined)
            return entry.d;
        if (entry.rect !== undefined)
            return rectPath(entry.rect);
        if (entry.circle !== undefined)
            return circlePath(entry.circle);
        return "";
    }

    // Lucide rect: x, y, width, height, corner radius.
    function rectPath(r) {
        const x = r[0], y = r[1], w = r[2], h = r[3], k = r[4];
        return "M" + (x + k) + " " + y
             + "H" + (x + w - k)
             + "A" + k + " " + k + " 0 0 1 " + (x + w) + " " + (y + k)
             + "V" + (y + h - k)
             + "A" + k + " " + k + " 0 0 1 " + (x + w - k) + " " + (y + h)
             + "H" + (x + k)
             + "A" + k + " " + k + " 0 0 1 " + x + " " + (y + h - k)
             + "V" + (y + k)
             + "A" + k + " " + k + " 0 0 1 " + (x + k) + " " + y + "z";
    }

    // Lucide circle: cx, cy, r. Two half-arcs in opposite directions make
    // a closed circle; a single arc would only ever draw a semicircle.
    function circlePath(c) {
        return "M" + (c[0] - c[2]) + " " + c[1]
             + "a" + c[2] + " " + c[2] + " 0 1 0 " + (c[2] * 2) + " 0"
             + "a" + c[2] + " " + c[2] + " 0 1 0 " + (-c[2] * 2) + " 0";
    }

    // Scale the 24x24 authoring grid down to whatever size we were given.
    readonly property real scale: Math.min(width, height) / 24

    Item {
        width: 24
        height: 24
        anchors.centerIn: parent
        scale: glyph.scale

        Shape {
            id: shape
            anchors.fill: parent
            antialiasing: true

            component Stroke: ShapePath {
                id: stroke

                // `svg` is forwarded into the child PathSvg's `path`; PathSvg
                // itself has no `d` property, only `path`. Referenced by id
                // rather than `parent`, because ShapePath is not an Item and
                // so is not the QML object parent of its PathSvg children.
                property string svg: ""

                strokeWidth: glyph.weight * glyph.scale
                strokeColor: glyph.color
                fillColor: glyph.solid ? glyph.color : "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin

                PathSvg { path: stroke.svg }
            }

            Stroke { svg: glyph.pathAt(0) }
            Stroke { svg: glyph.pathAt(1) }
            Stroke { svg: glyph.pathAt(2) }
            Stroke { svg: glyph.pathAt(3) }
            Stroke { svg: glyph.pathAt(4) }
        }
    }
}
