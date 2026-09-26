# ⏱️ Omarchy Stopwatch Widget

A **stopwatch and countdown timer for Quickshell**, built for **Omarchy** and
Hyprland.

A draggable corner widget: a compact circular bubble showing the time, which
opens into a full control card with a stopwatch and a timer. Standalone
Quickshell configuration — it imports no private Omarchy QML modules.

## ✨ Features

- ⏱️ Stopwatch with centisecond resolution and lap times
- ⏳ Countdown timer with 1/3/5/10/15-minute presets
- 🫧 One tap to expand, drag to reposition anywhere on screen
- 💾 Position, mode, and timer length persist across restarts
- 🎨 Live Omarchy theme colors, light and dark
- 🔒 Stays on screen: the position is clamped to the monitor

## Requirements

- Omarchy
- Quickshell with layer-shell support
- A Wayland session

## Install

```bash
mkdir -p ~/.config/quickshell
cp -r stopwatch ~/.config/quickshell/stopwatch
quickshell -c stopwatch
```

Or run it without installing:

```bash
quickshell -p ./stopwatch
```

### As a systemd user unit

```bash
systemctl --user enable --now qs-stopwatch
```

## Usage

| Action | How |
| --- | --- |
| Open the card | Click the bubble |
| Close the card | `✕` in the header |
| Move the widget | Drag the bubble, or the empty part of the header |
| Stopwatch | `▶` starts, `■` stops, `＋` records a lap, `↺` resets |
| Timer | Pick a preset, then `▶` starts, `↺` resets |

## Theming

The widget reads the same public theme state the Omarchy shell uses:

- `~/.local/state/omarchy/current/theme/colors.toml`
- `~/.local/state/omarchy/current/theme/shell.toml`

Theme switches are detected through the `theme.name` marker, which Omarchy
writes after it has replaced the generated theme directory. Parsing is inline
and local, so the config stays standalone.

## Customization

At the top of `shell.qml`:

| Option | Default | Meaning |
| --- | --- | --- |
| `panelW` / `panelH` | `288` / `300` | Surface size — see the note below |
| `bubbleSize` | `52` | Diameter of the collapsed circle |
| `pad` | `14` | Inner padding of the card |
| `radius` | `16` | Card corner radius |
| `edgeMargin` | `8` | Minimum distance from the screen edge |

## Notes and limits

- **The surface size never changes.** `PanelWindow` surfaces that resize are
  destroyed and recreated by the compositor, which shows up as a flicker.
  Collapsed and expanded therefore share one `288x300` surface and only the
  contents change.
- Because the surface is always full size, `mask` restricts the clickable
  region to whichever part is actually drawn. Without it the collapsed bubble
  would silently swallow clicks across `288x300` of desktop.
- **The surface lives on the Bottom layer, not Background.** Background is
  where the wallpaper is drawn, so a control widget there competes with the
  wallpaper and can be covered when it changes.
- Drag deltas are taken in global coordinates (`mapToGlobal`). The surface is
  what moves during a drag, so item-relative `event.x` would stay pinned under
  the cursor and the widget would refuse to move. `QQuickMouseEvent` also
  exposes no scene coordinates — only `x` and `y`.
- Elapsed time is derived from wall-clock deltas rather than by accumulating a
  tick interval, so a late or skipped tick cannot make the clock drift.
- The bubble shows `M:SS`; the expanded card shows centiseconds in stopwatch
  mode. Both use a monospace font so the text does not jitter as digits change.
