# Windows, PlayerBus and the player window

Phase 2, 2026-10-04; player window replaced 2026-10-05. The app runs as two independent OS windows: the visualiser and the player. They share nothing but an event bus.

## Architecture

```
root Window (OS window 0) = visualiser            Controller (OS window 1)
 └ main.gd (composer, window policy, test modes)    player/player_window.gd (Window, borderless, opaque)
    ├ AudioService   (non-visual: playback,          ├ MainPanel (player_main_panel.gd: LCD, sliders,
    │                 analysis capture, playlist)    │            transport, toggles)
    │                                                └ PlaylistPanel (player_playlist_panel.gd)
    ├ SceneDirector  (non-visual: scene list,        Settings (settings_window.gd, normal OS window)
    │                 titles, multi-scene cycling)
    └ Visualiser     (SceneRuntime, debug overlay,
                      fullscreen, visualiser keys)
PlayerBus (autoload) ── state + signals + commands ── used by every box above
ReactivityService (autoload) ── one reactivity hub + reaction channels for every scene (docs/REACTIVITY_API.md)
```

- `project.godot` sets `display/window/subwindows/embed_subwindows=false`, so every `Window` node is a real OS window, and `per_pixel_transparency/allowed=true` (left on; the player window itself is opaque now).
- Neither window references the other's nodes. Windows read `PlayerBus` state, listen to its signals and send `PlayerBus.command(name, args)`. Services handle the commands they own and ignore the rest.
- Audio playback lives in `AudioService`, a plain `Node` under the root. Neither window owns it, so hiding, minimising or closing a window never stops the music.

### Why the visualiser is the main (root) window

- The scene runtime, camera and `World3D` stay in the root viewport. `scene_runtime.gd` needed no change, and the smoke, sweep, reference and capture modes still read `get_viewport()`.
- macOS fullscreen (F11, Ctrl+F, double-click) behaves best on the main window, including the Space it creates on the window's current screen.
- `--scene-only` simply skips creating the controller.
- Trade-off: Godot cannot hide its main window (`Can't change visibility of main window`). "Closing" the visualiser therefore minimises it to the Dock.

### Window policy (decided; the user was not available)

The original LavaPlay.exe was the program the user launched, and it started LAVA.exe for the visuals. The player is therefore treated as the app:

| Action | Result |
|---|---|
| Quit from the player (× button, ≡ menu Exit, Cmd/Ctrl+Q in either window, or an OS close request on the player window) | Saves window state and the playlist, then quits. No confirmation. |
| Close the visualiser (red button) | Minimises it to the Dock, leaving fullscreen first. The player's VIS button, the ≡ menu, Settings → Display or F11 bring it back. |
| `--scene-only` (no player) | Closing the visualiser or pressing Esc quits. |
| Tab (either window) | Hides or shows the player. While it is hidden, moving the mouse over the visualiser shows a "Show controls · Tab" button for 3 s. |
| Minimise (Ctrl+I, the player's _ button, the Dock) | Applies only to the window it was pressed in. Each window minimises on its own. |

The app never leaves both windows out of sight: hiding the player restores a minimised visualiser, and minimising the visualiser shows a hidden player.

macOS minimises and restores asynchronously, so `main.gd` publishes the window state again once the visualiser's mode has really changed (up to 2 s). macOS also refuses to minimise a borderless window, so the player turns its title bar on for the trip to the Dock and goes borderless again when it comes back (`PlayerWindow.minimize_player`).

### Fullscreen and screens

- `Visualiser.set_fullscreen(true)` sets `current_screen` to the screen the window is on before it switches mode, so fullscreen opens on a second monitor when the window is on that monitor.
- On quit, `[windows]` in `user://settings.cfg` stores the visualiser rect and screen and its fullscreen state, plus the player position and screen, whether the playlist panel is open (`drawer_open`), its height, the time mode and the spectrum mode, and the library panel's open state, width, height and view (`library_open`, `library_width`, `library_height`, `library_view`). The player size is in `[player] ui_size`.
- On start, `WindowLayout.clamp_rect` checks each saved rect against the screens connected now. A window keeps its place if at least 64×48 px of it is visible on its saved screen. Otherwise it moves to the screen it overlaps most, or is centred on the primary screen if it overlaps none (a monitor that has gone). It is also shrunk to fit and pushed fully on screen.
- `--no-persist` skips all of this. Automated test modes also skip it.

### Scene-only / screensaver mode

`Godot … -- --scene-only [--windowed] [--play=/path/track.mp3 …] [--mock-audio]`

- Starts fullscreen with the mouse cursor hidden, and no player window.
- With no `--play=`, it uses the silent synthetic feed.
- Visualiser keys still work: Space, arrows, Page Up/Down to change scene, F3, the original T/W/S/… keys, and so on. Esc quits.

## PlayerBus API

`player_bus.gd`, registered as the autoload `PlayerBus`. Code reaches it through `preload("res://player_bus.gd").instance()`. Autoload globals do not exist under `--script`, which the tests use, so `instance()` creates the bus there.

### State and signals

| Property | Signal | Published by |
|---|---|---|
| `transport` ("stopped", "playing", "paused", "loading") | `transport_changed(state)` | AudioService |
| `track_index`, `track_title` | `track_changed(index, title)` | AudioService |
| `position`, `duration` (s) | `position_changed(pos, dur)` | AudioService (per frame while playing) |
| `playlist`, `failed_tracks` | `playlist_changed()` | AudioService |
| `volume` (0–1), `muted` | `volume_changed(volume, muted)` | AudioService |
| `shuffle`, `repeat_mode` (0 off, 1 all, 2 one) | `modes_changed(shuffle, repeat)` | AudioService |
| `scenes` [{name, title, version, path}] | `scene_list_changed()` | SceneDirector |
| `scene_index`, `scene_reason` | `scene_changed(index)`, `scene_prepare(index)` | SceneDirector. The visualiser loads or blends to the scene on `scene_changed`; `scene_prepare` lets it build the next scene early (index -1 cancels). See TRANSITIONS.md |
| `cycling` {enabled, interval, order, mode, musical, transition, transition_seconds, per_track (alias)} | `cycling_changed()` | SceneDirector |
| `scene_pins` {track path: scene folder} | `scene_pins_changed()` | SceneDirector; stored with the playlist by AudioService |
| `response`, `brightness` (engine values) | `tuning_changed(r, b)` | Visualiser |
| `scene_info` {presets, preset_index, tuning_supported, response_slider, brightness_slider, style_flags[], effect_categories[], text_message} | `scene_info_changed()` | Visualiser |
| `last_analysis` {band_a, global_s, beat, …} | `analysis_frame(signals)` | Visualiser (per scene tick) |
| `reactivity` {sensitivity, camera_intensity, effects_intensity, prefetch, source, analysing, track_bpm} | `reactivity_changed()` | ReactivityService (docs/REACTIVITY_API.md) |
| `analysis_source` ("real", "mock"), `mock_params` {bpm, schedule} | `analysis_source_changed(source)` | Visualiser |
| `library` {tracks, order, playlists, artists, albums, by_location, count, updated}, `library_state` ("empty", "cached", "refreshing", "ready", "error"); `track_meta(path)` → {title, artist, album, duration, source} | `library_changed()` | MusicBridge (docs/APPLE_MUSIC.md) |
| `status` | `status_changed(text)` | anyone |
| `visualiser_visible`, `visualiser_fullscreen`, `controller_present`, `controller_visible`, `drawer_open` (playlist panel open) | `windows_changed()` | main / controller |

### Commands (`command_requested(name, args)`)

| Owner | Commands |
|---|---|
| AudioService | `play_pause`, `play`, `pause`, `stop`, `next`, `previous`, `seek{seconds}`, `seek_fraction{fraction}`, `seek_relative{seconds}`, `set_volume{value}`, `volume_step{delta}`, `toggle_mute`, `toggle_shuffle`, `cycle_repeat`, `add_paths{paths, play?}`, `add_directory_path{path, recursive}`, `play_index{index}`, `remove_index{index}`, `move_index{from, to}`, `clear_playlist`, `import_m3u{path}`, `export_m3u{path}`, `add_library_tracks{ids, play?}`, `add_library_playlist{id, play?}` |
| MusicBridge (child of AudioService) | `library_refresh`, `open_library` (refreshes the library once per session; see docs/APPLE_MUSIC.md) |
| SceneDirector | `select_scene{index}`, `next_scene`, `previous_scene` (alphabetical by title), `set_cycling{enabled?, interval?, order?, mode?, musical?, transition?, transition_seconds?}`, `pin_scene`, `unpin_scene` |
| Visualiser | `toggle_fullscreen`, `set_fullscreen{on}`, `escape`, `toggle_debug_overlay`, `cycle_fps_cap`, `set_display{fps_cap?, vsync?, interpolate?, timing?}`, `set_analysis_source{source}`, `set_inspection{on}`, `apply_preset{index}`, `show_recovery_details`, `set_style_flag{flag, on}`, `trigger_effect_preset{index}`, `toggle_text_message`, `show_intro`, `set_tuning{response_slider, brightness_slider}` (0–100; −1 = scene value) |
| ReactivityService | `set_reactivity{sensitivity?, camera_intensity?, effects_intensity?, prefetch?}` |
| main | `quit_app`, `close_controller`, `toggle_visualiser`, `show_visualiser`, `hide_visualiser`, `toggle_controller`, `show_controller`, `hide_controller`, `minimize{source:"visualiser"}` |
| Controller (player window) | `toggle_drawer` (playlist panel), `add_tracks` (file dialog), `add_directory` (folder dialog), `remove_track` (the selected track), `open_settings`, `import_m3u_dialog`, `export_m3u_dialog`, `minimize{source:"controller"}`, `show_player_menu`, `show_scene_menu`, `set_player_size{size}`, `toggle_library`, `open_library`, `close_library` (library panel; opening also sends `open_library` for MusicBridge) |

### Keys

Each window passes its key presses to `PlayerBus.handle_key(event, source)`:

1. **Scene runtime first.** Unmodified non-player keys and Shift+F3/F4 go to `scene_key_handler`. The visualiser sets it to `OriginalHotkeys.handle(runtime, event)`: T W S L C P toggle style flags, M is 3D text, N is intro, F5–F8 are special effects, and Shift+F3/F4 are flat shading and lights. A handled key publishes its status text.
2. **Player hotkeys.** Otherwise `hotkeys.gd` maps the key to a command, which is sent with `args.source` set to the window name. Auto-repeat only seeks and changes volume.

The full key list is in `PLAYER_CONTROLS.md`.

## Player window

`player/` holds the player. It replaced the extracted LAVA! 2.5 / Oozic 3 bitmap skins (and the optional "Modern" skin), which were fixed-size bitmaps and tiny on high-DPI screens. `tools/extract_skins.py`, `tools/make_modern_skin.py` and `research/` stay as history; the app no longer loads skins.

| File | Role |
|---|---|
| `player_window.gd` | The `Window`: scale and size, window drag and resize, dialogs, ≡ and scene menus, keys, the window-level bus commands. |
| `player_main_panel.gd` | Main panel, 275 x 116 base units. `BUTTONS` lists every control with its bus command. |
| `player_playlist_panel.gd` | Playlist panel: custom-drawn list, search field, bottom bar, resize handles. |
| `player_library_panel.gd` | Music library panel, right of the player column: sources, state box, search, sortable virtualised list, actions (docs/APPLE_MUSIC.md). |
| `library_model.gd` | Pure library view model: rows, search, sorting, selection to bus commands. |
| `player_widgets.gd` | Button, slider, seven-segment time, spectrum/scope, scrolling title. |
| `player_style.gd` | Palette, system fonts, bevels, glyphs, seven-segment digits. |
| `player_format.gd` | Pure helpers: `display_title(entry)`, times, filter, totals, scaling math. |

**Layout.** Like Winamp 2 in proportion only; all artwork is original and drawn in code (`_draw` polygons and lines, `StyleBoxFlat`, `SystemFont`). Main panel: title strip (≡ menu, minimise, close), an amber LCD (seven-segment time, spectrum, scrolling title, info line, scene line), mute + volume, LIB / VIS / PL toggles, seek bar, transport (previous, play, pause, stop, next, open), SHUF / REP and a lava mark. Playlist panel below it: list, search field, track count and total time, ADD / DIR / REM, free space (for LIB and later buttons), LOAD / SAVE and a resize grip. Library panel to the right of both (LIB): sources and state on the left; search, breadcrumb, sortable list and PLAY / ADD on the right; its own corner grip and right and bottom edges resize it.

**Every control is a bus command.** Including window chores (≡ sends `show_player_menu`, PL sends `toggle_drawer`, ADD sends `add_tracks`), which the player window answers itself. So a key, a menu entry, the Settings window or a later library window reaches the same code, and the tests check each control by recording bus commands.

**One window that grows, not a docked second window.** The playlist panel is part of the player window, and opening it makes the window taller. Two OS windows would have to be moved together on every drag (macOS moves windows asynchronously, so a docked pair lags and drifts), would each need focus, key routing and close handling, and would make "quitting the player quits the app" ambiguous. One window keeps the close policy, key routing and saved position as they were. The cost: the playlist cannot be undocked. The music library follows the same rule. It is a third panel on the right and the window widens (`PlayerFormat.window_base_size`). It has its own height (`library_height`) but is never shorter than the player column; when it is taller, a plain body fills the column under the main panel. The library's × only hides the panel; × on the main panel still quits. Its width is clamped between 250 units and the screen width.

**Scaling.** Everything is laid out in base units and rendered at `ui_scale = screen scale x user size` through `Window.content_scale_factor`; the window is `base size x ui_scale` physical pixels (rounded up to even). The screen scale comes from `DisplayServer.screen_get_scale` (2 on Retina); the user size is 1x, 1.5x, 2x (default) or 3x (Settings → Display, the ≡ menu, `[player] ui_size`, or `--player-size=` for one session). At the default the player is 550 points wide on any screen. Because the canvas is scaled, not a bitmap, text and lines stay sharp. The window re-scales when the size changes, on `NOTIFICATION_WM_DPI_CHANGE`, and on a twice-a-second check of the current screen's scale (moving to another monitor). Menus use `screen scale x clamp(0.6 x user size, 1, 1.8)`.

**Position and size.** The window is borderless and opaque. Dragging the title strip or the body calls `Window.start_drag()`. The playlist height is in base units; the grip and bottom edge resize it, clamped between 84 units and the screen height. After any size change the window is kept on its screen (`WindowLayout.clamp_rect`).

**Titles.** `player_format.gd::display_title(entry)` is the only place a playlist entry becomes text: the file name without extension, underscores and leading track numbers removed ("01 - Artist - Title.flac" -> "Artist - Title"). An entry that is not a file path may carry a label after `|` (for example `applemusic:<id>|Artist - Title`). Extend this function for tags or other sources.

**Durations.** The bus does not publish per-track lengths, so the playlist learns each one when the track plays (`position_changed`) and keeps it for the session. The total shows "+" while some are unknown.

**Spectrum.** It uses `analysis_frame` (`band_a`, `global_s`), the same data the scenes get, spread over 19 bars with a small animated variation. It is a display of the scene analysis, not a real FFT of the output; the scope view is drawn from the same band levels.

### Persistence of the playlist

`user://playlist.json` holds `{format, tracks, current}`. It is written on every edit and on quit, and restored at start without autoplay.

The original kept an MFC-serialised `Lava.mvl` (Oozic: `Oozic.mvl`) next to the EXE. We do not read or write `.mvl`. Import and export use `.m3u`, which the original did not support.

## Tests

- `test_windows_bus.gd` (headless) covers:
  - the hotkey map and Cmd = Ctrl;
  - bus routing, with the scene runtime claiming keys first;
  - echo filtering;
  - rect clamping: a missing monitor, an unplugged monitor, a rect straddling two screens, an oversized rect;
  - settings section merging;
  - ASHEX titles;
  - cycling order and timer;
  - the visualiser with no controller on mock input.
- `test_scene_transitions.gd` (headless) covers transitions (docs/TRANSITIONS.md): every style completes and frees the old runtime and stage without leaking nodes, rapid changes, Cut, resize, by-track cycling, musical scheduling on a mock 128 BPM hub, section mode and pins.
- `test_player_ui.gd` (headless) covers the player: scaling math at 1x/1.5x/2x/3x, window size and content scale per size, titles/filter/totals, hit areas (inside their panel, no overlaps, at least 9 units), the bus command of every button, slider, menu entry and the scene line, playlist double-click / drag / Delete / Alt+arrows / Enter, filtered drag, remove selected, durations, the window-level commands, grip resize, keys from the player and the search field, Settings size choice and its persistence.
- `test_library_browser.gd` (headless) covers the library browser and the Settings window scale (see docs/APPLE_MUSIC.md).
- `test_player_controls.gd` (headless) covers the whole app through the bus and both windows' input, playlist edits, m3u, persistence and the engine API wiring.
- `test_windows_live.gd` (**windowed**) checks:
  - the player is a separate, non-embedded, borderless OS window sized at screen scale x user size;
  - the playlist panel grows and shrinks the window, and a size change re-scales live;
  - closing the visualiser minimises it and the player stays;
  - each window minimises independently;
  - fullscreen opens on the current screen and returns to windowed.
  - Each step waits for the window state with a timeout, because macOS animates window changes.
- Proof images: `tools/capture_player.gd` (states) and `--capture-controller=` (live run) write to `research/oozic/proof/ui-player/`.
