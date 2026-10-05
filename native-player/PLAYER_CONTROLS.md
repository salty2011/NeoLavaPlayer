# Player controls

The app is a set of Winamp-style panels, each its own borderless window drawn in the same theme (entirely in code, no bitmap skins, so sharp at any size):

- **Main** (the player): LCD, seek bar, transport, toggles.
- **Playlist** (PL), docked under Main by default.
- **Music library** (LIB), docked to the right of Main when opened.
- **Visualiser** (VIS): the 3D scene in a themed frame (title strip, minimise, fullscreen, close; a bottom bar with the scene name and ‹ › to change scene). By default it sits beside Main and the playlist, as tall as both.

**Moving and docking.** Drag a panel by its title strip (or any empty part of its body; the visualiser by its title strip or bottom bar). While you drag, its edges snap to other panels' edges (side by side or aligned) and to the screen edges within about 10 points. Panels touching Main form a group: dragging Main moves every panel docked to it, directly or through another panel. Dragging any other panel moves only that panel, which detaches it; drop it against a panel's edge and it docks there. Opening the library pushes the panels docked beyond its place (the visualiser) out of the way; closing it lets them slide back.

**Resizing.** The playlist, the library and the visualiser resize from their right edge, bottom edge and corner grip; panels docked against the edge that moves are pushed along so they stay flush. Main has a fixed size per player size.

**Reset window layout** (≡ menu, Ctrl+Shift+R) puts every panel back in the default arrangement and sizes. Architecture and window policy are described in docs/WINDOWS_AND_BUS.md.

## Player window

**Title strip**

- **≡ (menu)**: show/hide visualiser, fullscreen visualiser, choose scene, next/previous scene, playlist panel, music library, add files/folder, import/export .m3u, clear playlist, player size, Settings, Minimise, Exit.
- **_** minimises the player. **×** closes it, which quits the app.

**Display (LCD)**

- **Time** in large digits. Click it to switch between elapsed and remaining time (shown with a minus). It blinks while paused.
- **Spectrum**, fed by the scene analysis (music or the synthetic beat). Click it to cycle spectrum → scope → off.
- **Title**: "N. Artist - Title (length)". It scrolls when it does not fit.
- **Info line**: format and track number, transport state, and "SYNTH BEAT" while the synthetic feed drives scenes. New status messages show here for a few seconds.
- **Scene line**: the scene title and n/N. Click it to choose a scene, or to pin/unpin the scene to the current track.

**Controls**

- **Speaker**: mute. **Volume slider**: click, drag or scroll.
- **LIB**: show or hide the music library browser (Ctrl+Shift+L). **VIS**: show or hide the visualiser. **PL**: show or hide the playlist panel. The LED is lit when the window or panel is shown.
- **Seek bar**: click or drag; the jump happens on release.
- **Transport**: previous, play, pause (also resumes), stop, next, and ⏏ to open files.
- **SHUF**: shuffle. **REP**: repeat off → all → one ("REP 1").
- Double-click an empty part of the body to show or hide the visualiser.

**Playlist panel**

- Entries read "N. Artist - Title" with the length once a track has played. The current track is amber, the selection blue, and tracks that failed to decode are dimmed and struck through.
- Double-click or Enter plays a track. Drag a track to reorder it (an orange line shows where it lands), or use Alt+↑/↓. Delete or Backspace removes it.
- **Search field**: shows only tracks whose title or path contains every word typed. Esc clears it. Keys typed here never reach the player or the scene.
- Bottom bar: **ADD** files (FLAC, MP3 or .m3u), **DIR** a folder with its sub-folders, **REM** the selected track, **LOAD** / **SAVE** an .m3u playlist. The track count and total time sit above it ("+" means some lengths are not known yet).
- Drag the right edge, the bottom edge or the corner grip to resize the panel (at least as wide as Main). × on its title strip closes it (as PL does).

**Music library panel** (LIB). Your Music app library (Apple Music and local files), in its own panel, docked to the right of Main when it opens. docs/APPLE_MUSIC.md explains how the library is read.

- **Left:** Songs, Artists, Albums and Playlists with their counts; a state box (CACHED / REFRESHING / READY / ERROR with the last library message, and what to allow in System Settings when access was refused); **REFRESH** reads the library again.
- **Right:** a search field, a breadcrumb, sortable column headers and the list. Artists, Albums and Playlists list their groups first; double-click, Enter or → opens one (an album in disc and track order), and ‹, ← or Backspace goes back. Songs lists every track.
- **Search** filters the current view by title, artist and album; case and accents are ignored ("cafe" finds "Café"), and every word must match. Esc clears it; ↓ or Enter moves to the list.
- **Sorting:** click a column header for ascending (▲), again for descending (▼), a third time for the original order.
- **Badges:** a small broadcast mark is an Apple Music / streaming track (it plays in the Music app); a page mark is a local file Oozic decodes itself. Hover a row for the details.
- **Selecting:** click; Cmd/Ctrl-click adds or removes a row; Shift-click or Shift+↑/↓ selects a range; Cmd/Ctrl+A selects all; Esc clears.
- **Acting:** double-click a track, or press Enter, to add it (or the selection) to the end of the playlist and play it. **PLAY** replaces the playlist with the selection and plays; **ADD** appends it. With albums, artists or playlists selected these act on all their tracks. Inside an album, artist or playlist, **PLAY ALL** / **ADD ALL** act on the whole group. Right-click a row for the same actions plus "Play album", "Add album", "Play artist", "Add artist", "Show album" and "Show artist".
- **First run:** before the library has been read the panel offers **LOAD MUSIC LIBRARY**. That is when macOS asks for access to Media & Apple Music. If access is refused, the state box says what to allow and the button becomes **TRY AGAIN**.
- Drag the corner grip, right edge or bottom edge to resize it. The open state, size and current view (source, album/artist/playlist, sort) are restored at the next start. × on the library closes only the library.

**Size.** The player renders at the screen's own scale (2 on Retina) times the player size chosen in Settings → Display or the ≡ menu: 1x, 1.5x, 2x (default) or 3x. At 2x the player is 550 points wide. It re-scales at once when the size changes or the window moves to a screen with another scale.

You can also drop files, folders or .m3u playlists on either window.

### Playback

- **Adding and starting.** Adding files starts the first new track.
- **Repeat.** Cycles off → all (playlist) → one (song). The default is all, for continuous playback.
- **Shuffle.**
  - Shuffle is our addition; the original had loop modes only.
  - It avoids repeating the current track.
  - With loop off, playback stops after every track has played.
- **Previous.** Restarts the track after 3 s; otherwise it goes to the preceding track or the shuffle history.
- **Unplayable tracks.** Tracks that fail to decode are skipped, never retried in a loop, and excluded from shuffle.
- **Track ending during a load.** The advance is queued.
- **FLAC size limit.** A FLAC file over 1.5 GB of decoded PCM is refused.
- **Volume and mute.** Both act on the Master bus, so scene analysis keeps working while muted.
- **Persistence.**
  - The playlist (`user://playlist.json`) is saved on every change and restored at the next start without autoplay.
  - Volume, mute, shuffle, repeat and the player size (`ui_size`) are kept in `user://settings.cfg [player]`.
  - Every panel's position, which panel is docked to which, the playlist and library open state and size, the visualiser's size, the time mode and the spectrum mode are kept in `[windows]` (`dock`), and come back clamped to the screens connected now. A layout saved by the older single-window player is converted on first start.

## Keys (in any window)

| Key | Action |
|---|---|
| Space, Ctrl/Cmd+P | Play / pause |
| Ctrl+U | Pause |
| Ctrl+S | Stop |
| Ctrl+N / Ctrl+B | Next / previous track |
| ← / → | Seek −5 s / +5 s |
| ↑ / ↓ | Volume ±5% |
| Ctrl+M | Mute |
| Ctrl+O | Repeat mode |
| Ctrl+R | Shuffle |
| Ctrl+L | Playlist panel |
| Ctrl+Shift+L | Music library panel |
| Ctrl+Shift+V | Show or hide the visualiser |
| Ctrl+Shift+R | Reset the window layout |
| Ctrl+A / Shift+A | Add files / add folder |
| Ctrl+D | Remove the selected track |
| Ctrl+T | Settings |
| Ctrl+I | Minimise the player (with its playlist and library) or the visualiser, whichever the key was pressed in |
| Ctrl+Q | Quit |
| Tab | Show or hide the player's windows |
| F11, Ctrl+F, double-click the visualiser, its frame's ⛶ button | Toggle visualiser fullscreen, on its current screen (without the frame; back to its docked place after) |
| Esc | Leave fullscreen. In `--scene-only`, quit |
| Page Up / Page Down | Previous / next scene (alphabetical by title) |
| F3 | Debug overlay |
| F4 | Session-only frame-cap cycle: 30 → 60 → 144 → Uncapped → Original (60) |

The Ctrl keys are the original LavaPlay/OZPlay3 accelerators. Cmd works the same as Ctrl. When the playlist has keyboard focus it keeps ↑/↓, Home/End, Page Up/Down, Enter and Delete for itself; while the search field has focus, no player keys apply. The focused library list likewise keeps the arrows, Home/End, Page Up/Down, Enter, Backspace, Esc and Cmd/Ctrl+A.

Original visualiser keys (recovered from LAVA.exe; see docs/ENGINE_API.md). Loading a scene resets the toggles to that scene's `Style` defaults.

- **T** texture, **W** wire frame, **S** strobe, **L** colored lighting, **C** dynamic coloring, **P** pause camera.
- **Shift+F3** flat shading (F3 in the original) and **Shift+F4** lights (F4 in the original).
- **M** shows or hides the 3D text message, and **N** shows the intro screen.
- **F5–F8** step through the scene's special-effect categories.

## Settings (Ctrl+T or the ≡ menu)

- **Scenes**
  - The scene list by title, from the ASHEX 3D-text line (for example LVT2 "Dancing Well", LVT3 "Triple Trance"). The folder name is used when a scene has no title line.
  - The special-effects preset.
  - **Multi-scene** cycling (the original options):
    - interval 30 s, 1, 2, 3, 5, 10, 30 min or 1 h;
    - random or alphabetical order;
    - our addition: also change scene when the track changes.
    - These are saved in `[scenes]`.
  - **Response** and **Brightness**: the original 0–100 sliders. Response is 2^(s·0.02−1) times scene time, and Brightness is s·0.01, the light ambient multiplier. They apply per scene, and "Scene values" resets them.
- **Effects.** The original Effects tab: Style toggles, F5–F8 special-effect categories, 3D text and intro.
- **Display**
  - Show/hide and fullscreen the visualiser.
  - Frame cap: Original (60 fps) / 30 / 60 / 144 / Uncapped. The default is Uncapped.
  - VSync, on by default.
  - Smooth motion.
  - Fixed 60 Hz ticks or per-frame dt.
  - Scene input: music analysis or the silent synthetic beat.
  - Player size: 1x, 1.5x, 2x (default) or 3x, on top of the screen scale.
  - The Settings window follows the screen scale and the player size (0.75, 1 and 1.25 times the screen scale at 1x, 2x and 3x), and shrinks if it would not fit the screen.
  - See docs/FRAME_TIMING.md.
- **Playlist.** Import or export .m3u, add files or a folder, clear.
- **Scene tools.** Inspect objects and recovery details.

## Command-line flags (after `--`)

- `--mock-audio[=bpm]`: drive scenes from the silent synthetic feed. Not saved.
- `--scene-only [--windowed]`: run the visualiser alone, screensaver-style. It is fullscreen with the cursor hidden, uses mock input unless tracks are given, and Esc quits.
- `--play=/path/file.mp3` (repeatable): add these tracks and start playing.
- `--drawer`: open the playlist panel. `--player-size=1|1.5|2|3`: session-only player size. (`--skin=` is gone and ignored.)
- `--no-persist`: do not read or write the playlist, the window layout or the saved scene.
- `--debug-overlay`: start with the overlay shown.
- `--capture=/abs/visualiser.png [--capture-controller=/abs/player.png] --quit-after=seconds`: save the window(s), then quit.

Always use `--audio-driver Dummy` for automated runs, for example:

```sh
Godot --audio-driver Dummy --path native-player -- --mock-audio --no-persist --capture=/tmp/v.png --capture-controller=/tmp/p.png --quit-after=4
```

## Validation

Headless (`Godot --headless --audio-driver Dummy --path native-player --script res://<test>.gd`):

- `test_player_ui.gd` (the player UI: scaling, every control's command, menus, hit areas, playlist editing)
- `test_library_browser.gd` (the library browser on a synthetic library: views, search, sorting, selection, the commands of every action, states, 20k-track speed, Settings scale)
- `test_player_controls.gd`
- `test_windows_bus.gd`
- `test_docking.gd` (snapping, groups, detach/re-dock, resize pushing neighbours, layout save/restore/migration/reset, with the split windows)
- `test_playback_queue.gd`
- `test_frame_rate_independence.gd`
- the other `test_*.gd` files

Windowed: `test_windows_live.gd` and `test_legacy_lighting.gd`. Proof captures of the player in several states: `Godot --audio-driver Dummy --path native-player --script res://tools/capture_player.gd -- <out_dir> size=2`. With the library open, on the synthetic library: `tools/capture_library.gd -- <out_dir> size=2` (proofs in `research/oozic/proof/ui-library/`). The docked panels with the visualiser, default and alternative layouts at 1x/2x: `tools/capture_docking.gd -- <out_dir>` (proofs in `research/oozic/proof/ui-docking/`).

The `--smoke-report`, `--scene-sweep-report`, `--reference-report` and `--flac-report` modes still work. They run single-window, except the reference mode, which also captures the player window as `tripletrance-controls.png`.
