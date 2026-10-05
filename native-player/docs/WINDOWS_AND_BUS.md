# Windows, PlayerBus and the player window

Phase 2, 2026-10-04; player window replaced 2026-10-05; split into docked panels 2026-10-05. The app runs as Winamp-style panels, each its own OS window: the visualiser (the root window) and the player's main, playlist and library panels. The player's panels share one controller; the visualiser shares nothing with them but an event bus.

## Architecture

```
root Window (OS window 0) = visualiser            Controller = main panel window (OS window 1)
 └ main.gd (composer, window policy, test modes)    player/player_window.gd (Window, borderless, opaque)
    ├ AudioService   (non-visual: playback,          ├ MainPanel (player_main_panel.gd: LCD, sliders,
    │                 analysis capture, playlist)    │            transport, toggles)
    │                                                ├ Dock (player/dock_controller.gd: docking, drags)
    │                                                ├ PlaylistWindow (player/panel_window.gd, own OS window)
    │                                                │  └ PlaylistPanel (player_playlist_panel.gd)
    │                                                └ LibraryWindow (player/panel_window.gd, own OS window)
    │                                                   └ LibraryPanel (player_library_panel.gd)
    ├ SceneDirector  (non-visual: scene list,        Settings (settings_window.gd, normal OS window)
    │                 titles, multi-scene cycling)
    └ Visualiser     (SceneRuntime, debug overlay,
                      fullscreen, visualiser keys,
                      VisualiserFrame: player/visualiser_frame.gd)
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

### The visualiser's frame

With the player present (not `--scene-only`, not a test mode), main.gd makes the root window borderless and calls `Visualiser.set_framed(true)`. The frame (`player/visualiser_frame.gd`) is a `CanvasLayer` (layer 80) in the root viewport: a title strip ("OOZIC VISUALISER", minimise, fullscreen, close), 4-unit side borders, and a bottom bar with ‹ › scene buttons, the scene name LCD and a resize grip, drawn with `player_style.gd` in base units at the player's `ui_scale` (`PlayerBus.player_scale`). The bars have equal height and the sides equal width.

Why an overlay and not a SubViewport: the scene runtime, the transition stage (`get_window()` size and 3D buffer settings), Modern (`get_viewport()` quality settings), the wireframe debug draw and the capture modes all use the root viewport. An overlay leaves all of that, and the render path, untouched; the frame is opaque and covers the window's border, so exactly the inner rect (`VisualiserFrame.inner_rect`) shows the scene. The cost is the hidden border pixels (about 10 % of the window at the default size) instead of a SubViewport's extra full-window copy. Because the bars are symmetric, the camera's centre stays the centre of the visible picture. The `OpaqueAlpha` layer (layer −128) is unchanged; the frame writes alpha 1.

While framed and windowed the root viewport uses `content_scale_aspect = EXPAND` (not the project's KEEP), so the 2D canvas reaches the window edges instead of letterboxing to 1200×760; the 3D view then fills the window at any aspect. Fullscreen hides the frame and goes back to KEEP, exactly as before. The debug overlay and the "Show controls" hint are offset inside the frame. Frame text is drawn at device resolution (the frame Control is scaled, so strings undo the scale and use a larger font size). Double-clicks on the frame's buttons and handles do not toggle fullscreen.

### Window policy (decided; the user was not available)

The original LavaPlay.exe was the program the user launched, and it started LAVA.exe for the visuals. The player is therefore treated as the app:

| Action | Result |
|---|---|
| Quit from the player (× button, ≡ menu Exit, Cmd/Ctrl+Q in either window, or an OS close request on the player window) | Saves window state and the playlist, then quits. No confirmation. |
| Close the visualiser (× on its frame; `hide_visualiser`) | Minimises it to the Dock, leaving fullscreen first. The player's VIS button, the ≡ menu, Ctrl+Shift+V, Settings → Display or F11 bring it back, borderless and in its docked place. |
| Close the playlist or library (× on its title strip) | Hides that panel only (same as PL / LIB). |
| `--scene-only` (no player) | Closing the visualiser or pressing Esc quits. |
| Tab (any window) | Hides or shows all the player's windows (main, playlist, library). While they are hidden, moving the mouse over the visualiser shows a "Show controls · Tab" button for 3 s. |
| Minimise (Ctrl+I, a _ button, the Dock) | The player minimises with its playlist and library (they hide and come back with it: one Dock entry); the visualiser minimises on its own. |

The app never leaves both windows out of sight: hiding the player restores a minimised visualiser, and minimising the visualiser shows a hidden player.

macOS minimises and restores asynchronously, so `main.gd` publishes the window state again once the visualiser's mode has really changed (up to 2 s). macOS also refuses to minimise a borderless window, so the player turns its title bar on for the trip to the Dock and goes borderless again when it comes back (`PlayerWindow.minimize_player`); main.gd does the same for the framed visualiser (`_minimize_root`), and the dock puts it back in its docked place when it returns. macOS ignores (and gets confused by) leaving fullscreen while it is still animating into it, so a request in the first 1.5 s waits until then (`Visualiser.FULLSCREEN_SETTLE_MS`). Back from fullscreen the window keeps the title bar macOS gave it; the visualiser makes it borderless again once its rect has been still for 0.3 s (`Visualiser._restore_border`; changing the style mid-animation leaves a broken frame), and the dock then re-applies its docked rect for 2 s, because macOS may finish its own animation with the old frame.

### Fullscreen and screens

- `Visualiser.set_fullscreen(true)` sets `current_screen` to the screen the window is on before it switches mode, so fullscreen opens on a second monitor when the window is on that monitor.
- On quit, `[windows]` in `user://settings.cfg` stores the visualiser rect and screen and its fullscreen state, the main panel's rect and screen, whether the playlist panel is open (`drawer_open`), its height and width, the time mode and the spectrum mode, the library panel's open state, width, height and view (`library_open`, `library_width`, `library_height`, `library_view`), and `dock` = {version 2, attachments, positions, visualiser_units}: every panel's position and which panel is docked to which edge of which (offsets in base units). The player size is in `[player] ui_size`.
- On start the dock restores positions and attachments, re-places docked panels against their parents at the current scale, then keeps main's group (and each free panel's group) on a connected screen as a whole (`DockLayout.keep_on_screen_shift`: on the screen showing most of main, fully on screen when it fits). A file from the single-window player (no `dock`) is migrated: main at the old `controller_rect`, the playlist below it, the library to its right, the visualiser in its default place. Without the player (`--scene-only --windowed`) the visualiser uses its own saved rect, checked by `WindowLayout.clamp_rect` as before (kept if 64×48 px stay visible on its screen, else moved to the screen it overlaps most, or centred on the primary one).
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
| `player_scale` (pixels per base unit of the player windows) | `player_scale_changed(scale)` | controller; the visualiser frame draws at it |

### Commands (`command_requested(name, args)`)

| Owner | Commands |
|---|---|
| AudioService | `play_pause`, `play`, `pause`, `stop`, `next`, `previous`, `seek{seconds}`, `seek_fraction{fraction}`, `seek_relative{seconds}`, `set_volume{value}`, `volume_step{delta}`, `toggle_mute`, `toggle_shuffle`, `cycle_repeat`, `add_paths{paths, play?}`, `add_directory_path{path, recursive}`, `play_index{index}`, `remove_index{index}`, `move_index{from, to}`, `clear_playlist`, `import_m3u{path}`, `export_m3u{path}`, `add_library_tracks{ids, play?}`, `add_library_playlist{id, play?}`, `set_music_volume_link{on}` |
| MusicBridge (child of AudioService) | `library_refresh`, `open_library` (refreshes the library once per session; see docs/APPLE_MUSIC.md), `reveal_diagnostics` (shows ~/Library/Logs/NeoLavaPlayer/music.log in Finder) |
| SceneDirector | `select_scene{index}`, `next_scene`, `previous_scene` (alphabetical by title), `set_cycling{enabled?, interval?, order?, mode?, musical?, transition?, transition_seconds?}`, `pin_scene`, `unpin_scene` |
| Visualiser | `toggle_fullscreen`, `set_fullscreen{on}`, `escape`, `toggle_debug_overlay`, `cycle_fps_cap`, `set_display{fps_cap?, vsync?, interpolate?, timing?}`, `set_analysis_source{source}`, `set_inspection{on}`, `apply_preset{index}`, `show_recovery_details`, `set_style_flag{flag, on}`, `trigger_effect_preset{index}`, `toggle_text_message`, `show_intro`, `set_tuning{response_slider, brightness_slider}` (0–100; −1 = scene value) |
| ReactivityService | `set_reactivity{sensitivity?, camera_intensity?, effects_intensity?, prefetch?}` |
| main | `quit_app`, `close_controller`, `toggle_visualiser`, `show_visualiser`, `hide_visualiser`, `toggle_controller`, `show_controller`, `hide_controller` (all player windows), `minimize{source:"visualiser"}` |
| Controller (player window) | `toggle_drawer` (playlist panel), `add_tracks` (file dialog), `add_directory` (folder dialog), `remove_track` (the selected track), `open_settings`, `import_m3u_dialog`, `export_m3u_dialog`, `minimize{source:"controller"}`, `show_player_menu`, `show_scene_menu`, `set_player_size{size}`, `toggle_library`, `open_library`, `close_library` (library panel; opening also sends `open_library` for MusicBridge), `reset_layout`, `begin_panel_drag{panel}` and `resize_panel{panel:"visualiser", pixels, axes, start}` (sent by the visualiser frame) |

### Keys

Each window passes its key presses to `PlayerBus.handle_key(event, source)` (the playlist and library windows go through `PlayerWindow.handle_window_key`, which leaves keys to a focused search field or list; their source is "controller"):

1. **Scene runtime first.** Unmodified non-player keys and Shift+F3/F4 go to `scene_key_handler`. The visualiser sets it to `OriginalHotkeys.handle(runtime, event)`: T W S L C P toggle style flags, M is 3D text, N is intro, F5–F8 are special effects, and Shift+F3/F4 are flat shading and lights. A handled key publishes its status text.
2. **Player hotkeys.** Otherwise `hotkeys.gd` maps the key to a command, which is sent with `args.source` set to the window name. Auto-repeat only seeks and changes volume.

The full key list is in `PLAYER_CONTROLS.md`.

## Player window

`player/` holds the player. It replaced the extracted LAVA! 2.5 / Oozic 3 bitmap skins (and the optional "Modern" skin), which were fixed-size bitmaps and tiny on high-DPI screens. `tools/extract_skins.py`, `tools/make_modern_skin.py` and `research/` stay as history; the app no longer loads skins.

| File | Role |
|---|---|
| `player_window.gd` | The main panel's `Window` and the player's controller: scale and sizes of every panel, the panel windows, dialogs, ≡ and scene menus, keys from every player window, the player-level bus commands. |
| `panel_window.gd` | A borderless OS window for one panel (playlist, library) at the player's scale; hands keys, drops and close to the controller. |
| `dock_layout.gd` | Pure docking maths: snapping, touching sides, attachments, groups, reflow (hidden panels collapse), resize push, keep-on-screen, default layout, load/migrate. |
| `dock_controller.gd` | Owns panel rects and attachments; drags (mouse polled in screen coordinates), resizes, show/hide, reset, save/restore. |
| `visualiser_frame.gd` | The visualiser's themed frame (see above). |
| `player_main_panel.gd` | Main panel, 275 x 116 base units. `BUTTONS` lists every control with its bus command. |
| `player_playlist_panel.gd` | Playlist panel: custom-drawn list, search field, bottom bar, resize handles. |
| `player_library_panel.gd` | Music library panel, right of the player column: sources, state box, search, sortable virtualised list, actions (docs/APPLE_MUSIC.md). |
| `library_model.gd` | Pure library view model: rows, search, sorting, selection to bus commands. |
| `player_widgets.gd` | Button, slider, seven-segment time, spectrum/scope, scrolling title. |
| `player_style.gd` | Palette, system fonts, bevels, glyphs, seven-segment digits. |
| `player_format.gd` | Pure helpers: `display_title(entry)`, times, filter, totals, scaling math. |

**Layout.** Like Winamp 2 in proportion (and in docking, below); all artwork is original and drawn in code (`_draw` polygons and lines, `StyleBoxFlat`, `SystemFont`). Main panel: title strip (≡ menu, minimise, close), an amber LCD (seven-segment time, spectrum, scrolling title, info line, scene line), mute + volume, LIB / VIS / PL toggles, seek bar, transport (previous, play, pause, stop, next, open), SHUF / REP and a lava mark. Playlist panel (its own window, docked below by default): title strip with ×, list, search field, track count and total time, ADD / DIR / REM, free space, LOAD / SAVE and a resize grip. Library panel (LIB, its own window, docked to the right of main): sources and state on the left; search, breadcrumb, sortable list and PLAY / ADD on the right; its own corner grip and right and bottom edges resize it.

**Every control is a bus command.** Including window chores (≡ sends `show_player_menu`, PL sends `toggle_drawer`, ADD sends `add_tracks`), which the player window answers itself. So a key, a menu entry, the Settings window or a later library window reaches the same code, and the tests check each control by recording bus commands.

**Docked windows (Winamp 2 style).** Each panel is its own borderless OS window; `dock_controller.gd` keeps them together. An earlier version used one growing window because a docked pair "lags and drifts" on macOS when the second window chases the first's window-moved notifications. The dock avoids that: a press on a title strip (or the visualiser's frame, through `begin_panel_drag`) starts a drag, and every frame `_process` reads the mouse in screen coordinates (`DisplayServer.mouse_get_position`) and sets the position of every moving window from the same delta in that one call. No window follows another.

- **Snapping.** While dragging, the moving panel's (or group's) edges snap to other panels' edges (side by side, or aligned flush) when the panels are level, and to screen edges from the inside, within `DockLayout.MAGNET_POINTS` (10 points, × the screen scale in pixels).
- **Groups.** On release a panel docks to what it touches: an attachment {to, side, offset in base units}. Attachments form trees; main is never attached, so main's group is everything chained to it (`group_of`). Dragging main moves its group, hidden panels included; dragging another panel moves it alone and detaches it.
- **Hidden panels collapse.** A closed panel keeps its attachment and has no thickness along it, so a panel docked beyond it slides against its parent, and slides out again when it opens (`reflow`). That is how the library opens between main and the visualiser by default. A panel opened where another now sits, docked to the same edge, takes that place and the other docks beyond it.
- **Resizing** (playlist, library, visualiser: right edge, bottom edge, grip) pushes the panels against the moved edges, and the ones beyond them (`push_neighbours`). Scale changes re-place every docked panel against its parent, so the group stays flush at any size.
- **Default layout** (`DockLayout.default_layout`; ≡ → Reset window layout, Ctrl+Shift+R): playlist below main; library to the right of main (closed until LIB); visualiser to the right of the library's place, top-aligned, as tall as the player column (116 + 174 units), 16:10 but narrowed to fit the screen; the group centred on main's screen. Chosen over "visualiser above" because the column (main, playlist) plus a 16:10 picture on top is too tall for a laptop screen at the default 2x, while side by side fits a 1470-point-wide screen; it keeps the controls at eye level with the picture and the group is one clean rectangle. Opening the library pushes the visualiser out, as the old window widened.
- **Positions** are physical pixels, kept on whole points (macOS rounds odd pixel positions on 2x screens). The dock keeps main's group on screen after a size change or a panel opening.
- **Close policy** is unchanged: × on main quits; × on the playlist or library closes that panel; × on the visualiser minimises it.

The cost: four windows to keep in step. A drag moves at the app's frame rate (set by the visualiser), and the real feel of a drag can only be judged by hand.

**Scaling.** Everything is laid out in base units and rendered at `ui_scale = screen scale x user size` through `Window.content_scale_factor`; the window is `base size x ui_scale` physical pixels (rounded up to even). The screen scale comes from `DisplayServer.screen_get_scale` (2 on Retina); the user size is 1x, 1.5x, 2x (default) or 3x (Settings → Display, the ≡ menu, `[player] ui_size`, or `--player-size=` for one session). At the default the player is 550 points wide on any screen. Because the canvas is scaled, not a bitmap, text and lines stay sharp. The window re-scales when the size changes, on `NOTIFICATION_WM_DPI_CHANGE`, and on a twice-a-second check of the current screen's scale (moving to another monitor). Menus use `screen scale x clamp(0.6 x user size, 1, 1.8)`.

**Position and size.** Every player window is borderless and opaque. Dragging a title strip or a panel body starts a dock drag (above). Panel sizes are in base units: the playlist is at least 275 × 84, the library at least 250 × 116, the visualiser at least 200 × 120, all at most the screen.

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
- `test_docking.gd` (headless) covers docking: snap maths (outer and flush edges, magnet, screen edges, level-only), touching sides, attachments, transitive groups, cycles, reflow and hidden-panel collapse, re-validation after moves, resize push, keep-on-screen, default layout, migration; and with the real split windows: the default dock, group drag in one step with snapping, detach and re-dock, the alternative layout (visualiser left, playlist right), visualiser and playlist resizes pushing neighbours, the library opening between main and the visualiser, scale change, closing panels, Tab, reset, save/restore (also from a gone monitor) and migration, the frame's buttons and drag/resize commands.
- `test_player_ui.gd` (headless) covers the player: scaling math at 1x/1.5x/2x/3x, window size and content scale per size, titles/filter/totals, hit areas (inside their panel, no overlaps, at least 9 units), the bus command of every button, slider, menu entry and the scene line, playlist double-click / drag / Delete / Alt+arrows / Enter, filtered drag, remove selected, durations, the window-level commands, grip resize, keys from the player and the search field, Settings size choice and its persistence.
- `test_library_browser.gd` (headless) covers the library browser and the Settings window scale (see docs/APPLE_MUSIC.md).
- `test_player_controls.gd` (headless) covers the whole app through the bus and both windows' input, playlist edits, m3u, persistence and the engine API wiring.
- `test_windows_live.gd` (**windowed**) checks:
  - main, playlist and library are separate, non-embedded, borderless OS windows sized at screen scale x user size;
  - the visualiser is borderless with its frame drawn to the window edges;
  - real window positions follow the dock: default layout, a group drag moving every window in the same step, the library opening between main and the visualiser, a live re-scale;
  - closing the visualiser minimises it (title bar put back for the Dock) and the player stays; it comes back borderless in place;
  - the player minimises with its panels and brings them back;
  - fullscreen opens on the current screen without the frame and returns to the docked rect.
  - Each step waits for the window state with a timeout, because macOS animates window changes.
- Proof images: `tools/capture_player.gd` (states) and `--capture-controller=` (live run, main window only) write to `research/oozic/proof/ui-player/`; `tools/capture_docking.gd` writes composites of the docked windows (default, library open, alternative layout; 1x and 2x) to `research/oozic/proof/ui-docking/` (`tools/layout_shot.gd` pastes each window's own capture at its dock position).
