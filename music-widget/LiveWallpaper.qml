pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland

/*
 * LiveWallpaper — album art and lyrics as the desktop background
 * ----------------------------------------------------------------
 * A permanent layer-shell surface on the Background layer showing the
 * current track as atmosphere: heavily blurred artwork, the lyric being
 * sung right now in large type, and a quiet caption underneath. It tracks
 * playback continuously and never appears or disappears.
 *
 * WHY IT IS NOT AN OVERLAY
 *   This started as a workspace-switch overlay -- it bloomed for four
 *   seconds on every switch, which meant reading a Hyprland event socket,
 *   running a long-lived socat, and fading in and out. That was a lot of
 *   machinery to interrupt the desktop every time you moved between
 *   workspaces, and it was unwelcome. Everything about that is gone: there
 *   is no event stream, no trigger and no transition. The surface simply
 *   exists, and the lyrics advance because the song does.
 *
 * WHY Background
 *   It is a wallpaper, so it belongs behind windows rather than over them.
 *   Nothing is ever in the way and there is no input to swallow.
 *
 * COST
 *   A full-screen blur is always composited, so the surface is kept as
 *   cheap as it can be: one image, one blur, two flat overlays. The
 *   surface is opaque, so it also replaces the desktop background instead
 *   of blending with it.
 */

PanelWindow {
    id: wallpaper

    // ---- inputs, assigned by the music widget ---------------------------

    // Already a file:// URL into the widget's artwork cache, so the
    // wallpaper never downloads anything of its own.
    property string artSource: ""
    property string trackTitle: ""
    property string trackArtist: ""
    property real positionSec: 0
    property bool hasPlayer: false

    property color textColor: "#f4f4f7"
    property color dimColor: "#9a9aa2"

    // ---- artwork --------------------------------------------------------

    // What the incoming image shows, and what the outgoing one is holding.
    property string incomingArt: ""
    property string outgoingArt: ""

    // ---- geometry -------------------------------------------------------

    // The lyric column sits left of centre and the right side is left
    // deliberately empty.
    readonly property real lyricLeft: width * 0.12
    readonly property real lyricWidth: width * 0.62

    // Type scales with the screen, so the composition is not a 1080p design
    // stretched onto whatever happens to be plugged in.
    readonly property real titleSize: Math.max(26, width * 0.030)
    readonly property real artistSize: Math.max(17, width * 0.018)
    readonly property real metaSize: Math.max(12, width * 0.013)
    readonly property real metaArtistSize: Math.max(11, width * 0.011)

    /* =================================================================
     * Surface
     * ================================================================= */

    color: "transparent"

    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.exclusionMode: ExclusionMode.Ignore
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "lyrics-wallpaper"

    anchors {
        top: true
        left: true
        right: true
        bottom: true
    }

    // Nothing is interactive, and an empty region keeps it that way
    // explicitly rather than by accident.
    mask: Region {}

    /* =================================================================
     * Background: artwork, blurred, darkened, vignetted
     * ================================================================= */

    // Opaque, so this surface is the background rather than a tint over the
    // desktop's own wallpaper.
    Rectangle {
        anchors.fill: parent
        color: "#0b0b0f"
    }

    Item {
        anchors.fill: parent

        // ---- the artwork, as two crossfading layers ----

        // `outgoingArt` is only non-empty during a track change. It is
        // dropped as soon as the incoming layer is fully opaque, so the
        // steady state composites exactly one image.
        Image {
            id: artOld
            anchors.fill: parent
            source: wallpaper.outgoingArt
            fillMode: Image.PreserveAspectCrop
            smooth: true
            mipmap: true
            asynchronous: true
            opacity: 0
        }

        Image {
            id: artNew
            anchors.fill: parent
            source: wallpaper.incomingArt
            fillMode: Image.PreserveAspectCrop
            smooth: true
            mipmap: true
            asynchronous: true

            // Bound to readiness rather than assigned, so pointing the image
            // at a new cover automatically drops it to zero while it
            // decodes and brings it back up when it is usable. The outgoing
            // frame is what is on screen in between, which is why a slow
            // download never flashes a placeholder.
            opacity: status === Image.Ready ? 1 : 0

            onOpacityChanged: {
                if (opacity === 1 && status === Image.Ready)
                    wallpaper.releaseOutgoing();
            }
        }

        // ---- the blur ----

        MultiEffect {
            anchors.fill: parent
            source: artNew
            blurEnabled: true
            // 1.0 is the maximum this Qt build offers; 6.11 has no
            // `blurMaxBlurRadius`, so the radius is not tunable. That is
            // fine, since the point is that the artwork is unrecognisable.
            blur: 1.0
        }

        // ---- dark wash, for text contrast ----

        Rectangle {
            anchors.fill: parent
            color: "#B3080A0C"
        }

        // ---- vignette ----

        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#00000000" }
                GradientStop { position: 0.60; color: "#00000000" }
                GradientStop { position: 1.0; color: "#66000000" }
            }
        }
    }

    /* =================================================================
     * Lyrics
     *
     * Hidden entirely when there is no player, so an idle desktop is just
     * the blurred artwork rather than a panel reading "Not playing".
     * ================================================================= */

    LyricsProvider {
        id: provider
        trackArtist: wallpaper.trackArtist
        trackTitle: wallpaper.trackTitle
    }

    Item {
        id: lyricArea
        x: wallpaper.lyricLeft
        y: wallpaper.height * 0.16
        width: wallpaper.lyricWidth
        height: wallpaper.height * 0.56
        visible: wallpaper.hasPlayer

        LyricsView {
            id: lyrics
            anchors.fill: parent
            lines: provider.synced ? provider.lines : []
            positionSec: wallpaper.positionSec
            textColor: wallpaper.textColor
        }

        // With no usable lyrics the area is not left empty: the track is
        // named instead, so the composition still reads. It stays hidden
        // while a fetch is outstanding rather than flashing a placeholder.
        Column {
            anchors.fill: parent
            spacing: 10
            visible: !provider.synced || provider.lines.length === 0
            opacity: provider.status === "loading" ? 0 : 1

            Behavior on opacity {
                NumberAnimation { duration: 200 }
            }

            Text {
                width: parent.width
                text: wallpaper.trackTitle
                color: wallpaper.textColor
                font.pixelSize: wallpaper.titleSize
                font.weight: Font.Bold
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.WordWrap
                visible: text.length > 0
            }

            Text {
                width: parent.width
                text: wallpaper.trackArtist
                color: wallpaper.dimColor
                font.pixelSize: wallpaper.artistSize
                elide: Text.ElideRight
                maximumLineCount: 1
                visible: text.length > 0
            }
        }
    }

    /* =================================================================
     * Caption, below the lyrics and clearly secondary
     * ================================================================= */

    Column {
        x: wallpaper.lyricLeft
        y: lyricArea.y + lyricArea.height + wallpaper.height * 0.02
        width: wallpaper.lyricWidth
        spacing: 4
        // Only worth showing once there are lyrics above it; otherwise the
        // same track name appears twice.
        visible: wallpaper.hasPlayer && provider.synced
        opacity: 0.55

        Text {
            width: parent.width
            text: wallpaper.trackTitle
            color: wallpaper.textColor
            font.pixelSize: wallpaper.metaSize
            font.weight: Font.DemiBold
            elide: Text.ElideRight
            maximumLineCount: 1
        }

        Text {
            width: parent.width
            text: wallpaper.trackArtist
            color: wallpaper.dimColor
            font.pixelSize: wallpaper.metaArtistSize
            elide: Text.ElideRight
            maximumLineCount: 1
        }
    }

    /* =================================================================
     * Art handoff
     * ================================================================= */

    function setArt(url) {
        const next = url || "";
        if (next === incomingArt)
            return;

        // Freeze whatever is currently on screen as the outgoing frame.
        // Only do so if it really decoded, otherwise there is nothing to
        // hold and the wallpaper would briefly show nothing at all.
        if (incomingArt && artNew.status === Image.Ready) {
            outgoingArt = incomingArt;
            artOld.opacity = 1;
        }

        incomingArt = next;

        if (!next) {
            artOld.opacity = 0;
            releaseOutgoing();
        }
    }

    // Called once the incoming layer is fully opaque: the outgoing frame has
    // nothing left to contribute.
    function releaseOutgoing() {
        if (outgoingArt.length === 0)
            return;
        outgoingArt = "";
        artOld.opacity = 0;
    }

    onArtSourceChanged: setArt(artSource)
}
