# 🎵 Omarchy Music Widget

An **MPRIS now-playing card for Quickshell**, built for **Omarchy** and Hyprland.

A single layer-shell card showing the active player's artwork, title, artist,
seek bar and transport controls, with colors read from the active Omarchy
theme. It is a standalone Quickshell configuration: it imports no private
Omarchy QML modules.

## ✨ Features

- 🎵 MPRIS support for any compatible media player
- 🔀 Player switching when more than one player is connected
- ⏯️ Play/pause, previous, next, and an interactive seek bar
- 🕐 Elapsed and total time
- 🎨 Live Omarchy theme colors, light and dark
- 🛡️ Every control is gated on the player's `canXyz` capability flags, so an
  unsupported button is hidden rather than shown-but-dead
- 📐 Fixed-size surface: no resize-driven flicker

## Requirements

- Omarchy
- Quickshell with `Quickshell.Services.Mpris`
- A Wayland session with layer-shell support

## Install

Copy the directory into your Quickshell configuration directory:

```bash
mkdir -p ~/.config/quickshell
cp -r music-widget ~/.config/quickshell/music-widget
```

Run it as an independent Quickshell configuration:

```bash
quickshell -c music-widget
```

Or run it straight from this repository without installing:

```bash
quickshell -p ./music-widget
```

### As a systemd user unit

`~/.config/systemd/user/qs-music-widget.service` is provided in this
repository's install notes; once copied into place:

```bash
systemctl --user enable --now qs-music-widget
```

## Omarchy theming

The widget follows the same public theme state used by the Omarchy shell:

- `~/.local/state/omarchy/current/theme/colors.toml`
- `~/.local/state/omarchy/current/theme/shell.toml`

A normal `omarchy theme set <name>` switch is detected automatically; the
Quickshell process does not need to restart. Omarchy stages and replaces the
generated theme directory before updating its `theme.name` marker, which is
the signal this widget watches — reading the TOML files before that marker
moves would mean reading a half-written theme.

The TOML parsing is inline and local, so the config stays standalone. It
handles the subset Omarchy generates: `[section]` tables, `key = "value"`
strings, `#` comments, hex colors, `rgb()`/`rgba()` in decimal or hex,
percent alpha, and gradient strings.

## Customization

Options are grouped at the top of `shell.qml`:

| Option | Default | Meaning |
| --- | --- | --- |
| `cardWidth` | `380` | Card width in logical pixels |
| `cardHeight` | `132` | Card height |
| `cornerRadius` | `18` | Corner radius |
| `pad` | `16` | Inner padding |
| `bottomInset` | `34` | Distance from the bottom of the screen |

The card is centred horizontally by deriving `margins.left` from the screen
width, because `PanelWindow.anchors` only understands `left`/`right`/`top`/
`bottom` — there is no `horizontalCenter`. That also makes the card follow the
monitor when it is resized or moved.

## Notes and limits

- `position` is not reactive in Quickshell by design, so a 500 ms timer
  re-emits `positionChanged()` while playing to keep the seek bar moving.
  Without it the bar only jumps on track changes.
- `length` and `position` are in **seconds**, not microseconds.
- Artwork is shown for both `file://` and `http(s)://` art URLs. Qt Quick has
  no network image loader, so a remote URL is fetched with `curl` into
  `$XDG_CACHE_HOME/music-widget` (default `~/.cache/music-widget`) and the
  `Image` is pointed at that copy. Cached files are named after a hash of the
  URL and carry no extension, since Qt detects the format from the file's
  contents. The newest 12 are kept; the on-screen cover and any in-flight
  download are never pruned. Spotify — which only ever publishes `https` art —
  is covered by this path.
- The surface size is constant. Resizing a layer-shell surface makes the
  compositor destroy and recreate it, which is visible as a flicker, so the
  card does not animate its own dimensions.
