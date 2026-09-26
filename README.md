# Omarchy Widgets

Standalone Quickshell widgets and services for Omarchy. Each directory is an independent Quickshell configuration with its own `shell.qml`; there is no build step or package manager.

## ✨ Introducing the new look

Three widgets, all rebuilt. Here is what changed.

### 🎵 The music widget grew a second surface

**Before:** a `380x132` card in the corner. Artwork, seek bar, transport. Fine —
and then you looked away from it and the desktop was just a picture.

**After:** the same card, *plus* a full-screen surface on the Background layer
that turns the current track into the desktop itself. The album art is blurred
past recognition, and the lyric being sung right now is set large in the
left-centre, advancing line by line as the song plays.

- 📜 **Real synchronised lyrics**, timestamped, with the active line held in a
  translucent glass pill while the surrounding lines fade out by distance
- 🎚️ **Nine lines of context** around the active one, so you always know what
  is coming and what just passed
- 🌊 **Continuous scroll.** The active line stays put in the focal band and the
  rest of the lyric moves around it — no page-flipping between blocks
- 🔁 **Crossfades on every track change.** The old cover stays on screen until
  the new one has actually decoded, so a slow download never flashes a
  placeholder
- 🛟 **Graceful when a track has no lyrics.** The artist and title take the
  lyric's place instead of an empty box
- ♻️ **Downloads nothing extra.** It reads the artwork cache the card already
  maintains and fetches lyrics in advance on the track change, not when you
  switch workspaces
- 🖼️ **No sharp cover, anywhere.** The artwork is atmosphere, never content

Measured at **60 fps** at `1536x864` with the full-screen blur running
permanently.

### 🖼️ The album wallpaper stopped showing you the album cover

**Before:** raw album art, dropped onto the desktop. Which is a photo of an
album, on your wallpaper, at full sharpness, competing with your icons.

**After:** art that has been blurred until *nothing* recognisable survives, with
its colour pushed back up and laid over a flat tone sampled from the cover
itself. You get the mood of the record, not its photography.

- 🎨 **Detail removed, not softened** — around **97% less edge energy** and
  **79–84% less contrast** than the original
- 💧 **Colour restored deliberately.** Blurring averages hues toward grey, so
  saturation is boosted in two stages to compensate
- 🗃️ **Its own cache directory,** pruned on its own schedule, so blurred files
  can never evict the sharp originals you still need
- 🧯 **Fails safe.** If the blur cannot be produced, the sharp cover is used
  instead of leaving you with no wallpaper at all
- 🔄 **Hands the desktop back.** The original wallpaper is restored when
  playback pauses or stops

### ⏱️ The stopwatch got honest about time

**Before:** a timer that could drift, and a panel that flickered when it
changed size.

**After:** elapsed time is derived from wall-clock deltas rather than by
adding up tick intervals, so a late or skipped tick cannot make the clock
lie. The surface is a constant size, so the compositor never destroys and
recreates it.

- ⏱️ Centisecond stopwatch with lap times
- ⏳ Countdown with 1/3/5/10/15-minute presets
- 🫧 One tap to expand, drag anywhere to reposition, clamped to the monitor
- 💾 Position, mode and timer length survive a restart
- 🎨 Live theme colours, light and dark, with no restart

## Modules

| Module | Description |
| --- | --- |
| `music-widget/` | MPRIS now-playing card, plus a live wallpaper that tracks the current track with synchronised lyrics |
| `stopwatch/` | Draggable stopwatch and countdown timer with laps and persistence |
| `album-wallpaper/` | MPRIS service that uses blurred, saturation-boosted album art as the Omarchy desktop background |

## Requirements

- Omarchy
- Quickshell
- `curl` for remote MPRIS album art and for lyric lookups
- ImageMagick (`magick`) for the album wallpaper's blur treatment
- `socat` only if you use the old workspace-switch overlay; the live
  wallpaper needs no event socket

## Install

Copy the desired module directories into your Quickshell configuration directory:

```bash
mkdir -p ~/.config/quickshell
cp -r music-widget ~/.config/quickshell/music-widget
cp -r stopwatch ~/.config/quickshell/stopwatch
cp -r album-wallpaper ~/.config/quickshell/album-wallpaper
```

Run a module by its installed configuration name:

```bash
quickshell -c music-widget
quickshell -c stopwatch
quickshell -c album-wallpaper
```

Or run one directly from this repository:

```bash
quickshell -p ./music-widget
quickshell -p ./stopwatch
quickshell -p ./album-wallpaper
```

Stop an installed configuration with:

```bash
quickshell -c <config-name> kill
```

## Running as systemd user units

Running a widget by hand leaves stray processes behind whenever the launching
shell exits, and stacked instances of the same widget draw on top of each
other. Unit files are provided so each widget is supervised by systemd and
started exactly once at login:

| Unit file | Module |
| --- | --- |
| `systemd/qs-music-widget.service` | `music-widget` |
| `systemd/qs-stopwatch.service` | `stopwatch` |
| `systemd/qs-album-wallpaper.service` | `album-wallpaper` |

```bash
mkdir -p ~/.config/systemd/user
cp systemd/*.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now qs-music-widget qs-stopwatch qs-album-wallpaper
```

Check or control them with:

```bash
systemctl --user status qs-music-widget
systemctl --user restart qs-stopwatch
journalctl --user -u qs-music-widget -n 40 --no-pager
```

## Omarchy integration

The visual widgets read Omarchy's generated theme state from:

- `~/.local/state/omarchy/current/theme/colors.toml`
- `~/.local/state/omarchy/current/theme/shell.toml`

They watch Omarchy's stable `theme.name` marker and reload the generated files after `omarchy theme set <name>` without requiring a Quickshell restart. Omarchy stages and replaces the generated theme directory before writing that marker, so these widgets do not need to import the Omarchy shell's private QML modules.

The album wallpaper service uses Omarchy's public interface:

```bash
omarchy theme bg set <path>
```

It snapshots the target of `~/.local/state/omarchy/current/background` before applying album art and restores that path after playback pauses or stops.

Two limits are worth knowing:

- Omarchy writes `theme.name` *before* it updates the background link, and `omarchy theme refresh` rewrites that marker while deliberately leaving the background untouched. The service reacts to the marker by re-reading the background with a bounded retry, refusing to accept a snapshot that is still the previous album artwork. A refresh that never changes the background therefore gives up after its retries and keeps the current artwork rather than restoring an old wallpaper.
- The original wallpaper is held in memory only. If the Quickshell process is killed or reloaded while album art is active, the snapshot is lost and the artwork is not cleaned up on the next start. Toggle the service off before restarting it if you need the desktop restored.

## Layer-shell notes

Both visual widgets follow the same rules, learned the hard way:

- `PanelWindow.anchors` only understands `left`, `right`, `top`, and
  `bottom`. There is no `horizontalCenter`, so a centred card has to derive
  its margin from the screen width.
- A layer-shell surface that changes size is destroyed and recreated by the
  compositor, which is visible as a flicker. Both widgets keep a constant
  surface size and change only their contents.
- An interactive widget belongs on the Bottom layer, not Background.
  Background is where the wallpaper is drawn, so a control widget there can
  be covered when the wallpaper changes.
- If a surface is larger than what it draws, set `mask` so the clickable
  region matches the visible part. Otherwise the transparent remainder
  swallows clicks meant for the desktop.

## Album wallpaper IPC

```bash
quickshell ipc call albumwallpaper toggle
quickshell ipc call albumwallpaper status
```

The service changes the live desktop background while enabled. Keep this in mind before running it in unattended startup configurations.
