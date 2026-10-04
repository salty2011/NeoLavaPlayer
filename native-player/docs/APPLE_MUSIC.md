# Apple Music in the player

The player can play tracks from your Music library, including Apple Music
streaming and iCloud tracks, and the visualiser reacts to them. It does this
through `bin/oozic-music-helper`, a small native tool whose contract is in
[MUSIC_HELPER.md](MUSIC_HELPER.md).

## How it works

Apple Music streaming, cloud and protected tracks are FairPlay DRM. Oozic
never decodes them. The Music app plays them, and Oozic:

1. starts the track with `control play-id <ID>`,
2. follows it with `watch --interval 0.25` (state, position, duration, track id),
3. listens to the Music app's audio with `tap --app com.apple.Music`, which
   streams f32le stereo PCM, and feeds that to the visualiser's analysers.

Owned, unprotected files from the library (`playable_file: true`) play like
any other local file.

### Playlist entries

| Entry | Plays through |
|---|---|
| `/path/song.mp3` | Godot's MP3 loader |
| `/path/song.flac`, `.m4a` (AAC or ALAC), `.aac`, `.aiff`, `.aif`, `.wav`, `.caf`, `.alac` | macOS Core Audio (`afconvert` to 16-bit stereo, off the main thread; `flac_decoder.gd`) |
| `applemusic:<16 hex persistent ID>` | the Music app |
| `.m4p` | refused: protected purchase. Add it from the library instead, where it becomes `applemusic:<ID>` |

`playlist.json` and M3U import/export keep `applemusic:` entries as they are.

### Pieces

| File | Role |
|---|---|
| `music_bridge.gd` (`MusicBridge`, child of AudioService) | Finds the helper, runs it with non-blocking pipes, queues `control` commands one at a time (volume and seek drags coalesce), reads and caches the library, maps exit codes to status text, kills its processes on exit. |
| `apple_music_stream.gd` (`AppleMusicStream`, child of AudioService) | The Music-app player for one `applemusic:` entry: transport mapping, watch parsing, end-of-track detection, tap PCM and tap health. |
| `audio_service.gd` | Routes each entry to Godot playback or AppleMusicStream; owns the playlist and queue (shuffle/repeat). |
| `analysis/reactivity_service.gd` | Treats `applemusic:` entries as live-only (no pre-analysis job, no cache lookup). |
| `player_bus.gd` | Library state and `track_meta()`; see the API below. |

Why a child of AudioService and not an autoload: the helper processes are
playback resources. They start and stop with the service that uses them,
each test's AudioService gets its own bridge, and no window can reach them
except through bus commands.

### Helper location

- Override: `MusicBridge.helper_override` or the `OOZIC_MUSIC_HELPER`
  environment variable (tests use `tools/fake_music_helper.sh`).
- Editor and `--script` runs: `native-player/bin/oozic-music-helper` from the repo.
- Exported app: a binary cannot run from inside the `.pck`. The export ships
  `bin/oozic-music-helper` in the `.pck` (`include_filter`), and at startup it
  is copied to `user://bin/oozic-music-helper` if missing or different (size,
  then MD5) and marked executable. For the default bundle that is
  `~/Library/Application Support/Godot/app_userdata/Oozic Recovery Player/bin/`.

### Library

- At startup the cached library (`user://music-library.json`, the helper's raw
  JSON) loads at once (`library_state = "cached"`).
- A background refresh (`library` on a Thread, about 150 ms for 1,430 tracks)
  then runs if a cache exists or Media access is already granted. Otherwise
  the first `open_library` or `library_refresh` command starts it, so the
  Media & Apple Music prompt appears when you open the library and not at
  launch.

### Streaming transport

| Player action | Music app |
|---|---|
| play an `applemusic:` entry | `control play-id ID`, then `volume` (our volume) |
| pause / resume | `control pause` / `control play` |
| play after Stop, or after Music moved to another track | `control play-id ID` (Music forgets the track on stop) |
| stop | `control stop` |
| seek, seek_fraction, seek_relative | `control seek S` |
| volume, mute | `control volume 0–100` (Music's own volume; mute sends 0) |
| next / previous | our playlist (shuffle and repeat from `playback_queue.gd`) |
| a file entry after an `applemusic:` entry | `control pause`; watch and tap stop |
| quit while a Music track plays | `control pause` (synchronous) |

- After each command a 0.9 s hold keeps the new state and position, so a
  watch line from before the command does not undo it.
- **End of track.** Our track was within 3 s of its end and Music then reports
  another track (its own auto-advance) or `stopped`: we advance our playlist
  and issue `play-id` for the next entry at once. If the playlist is finished,
  Music is paused.
- **Music went elsewhere** (you picked another track in Music before ours
  ended, or Music quit): Oozic stops following ("Music switched to another
  track. Press Play to return to your playlist.") and does not fight it.
- If Music has not reported our track 15 s after `play-id`, the transport stops
  with "Music didn't start the track".

### Analysis

- The tap is started with `--rate` equal to the classic analysers' rate
  (`AudioInputs.sample_rate`, the mix rate up to 48 kHz), so no resampling is
  needed. `AudioService.pcm_rate()` reports it, and ReactivityService builds
  its LiveAnalyzer at that rate.
- Frames go to `inputs.push()` (classic scenes) and `reactivity.push_pcm()`
  (reaction channels) exactly like captured file audio, and only while Music
  is playing. When Music is paused the tap sends zeros, and those are dropped.
- Streams are never pre-analysed. The reactivity source stays `live` for them.
- **Fallback.** If the tap exits 3 (permission), delivers no data for 3 s
  while playing (`stalled`), or delivers digital silence for 8 s while playing
  and not muted (`silent`), the classic scenes sample a 120 BPM synthetic beat
  (`AudioService.fallback_feed`) and the reactivity layer switches to its
  synthetic source. The status line says what to allow. Real sound switches
  both back. If the user already chose the synthetic input, nothing changes.
- The tap captures Music's output after Music's own volume. The analysers
  normalise adaptively, so a low volume mainly lowers the global level.

## Library browser

The LIB button (Ctrl+Shift+L, ≡ menu) opens `player/player_library_panel.gd`,
attached to the right of the player in the same window. PLAYER_CONTROLS.md
describes what the user sees; this section covers how it works.

- **Model.** `player/library_model.gd` turns `PlayerBus.library` into rows. A
  view is `{source, group, query, sort_key, sort_desc}`. Folded search keys
  (lower case, accents removed) and the whole-library sort orders are built
  once per library change. Sorting uses a native `PackedStringArray.sort()` on
  "key + separator + index" strings. On a 20k-track synthetic library: indexing
  about 0.4 s (once per refresh), a search about 6 ms, a cached re-sort plus
  search about 9 ms.
- **Drawing.** The list draws only the rows in view (`LibraryList.visible_range`)
  and elides long cells (`Style.elide`, cached), so drawing cost does not grow
  with the library.
- **Groups.** Artists are track artists, as in `library.artists`, so "A feat. B"
  is its own entry. Albums are keyed by album artist and title and listed in
  disc/track order. Playlists keep the Music app's order.
- **Actions and commands.**

  | Action | Commands |
  |---|---|
  | Double-click a track, Enter | `add_library_tracks {ids, play: true}` (appends, plays the first added) |
  | PLAY, "Play …" | `clear_playlist`, then `add_library_tracks {ids, play: true}` |
  | ADD, "Add …" | `add_library_tracks {ids, play: false}` |
  | Playlist rows, PLAY ALL / ADD ALL inside a playlist | as above, with one `add_library_playlist {id, play}` per playlist (only the first plays) |
  | REFRESH, LOAD MUSIC LIBRARY / TRY AGAIN | `library_refresh` |
  | Opening the panel | `open_library` (MusicBridge refreshes once per session) |

- **States.** `library_state` drives the state box and the empty view. `empty`
  shows LOAD MUSIC LIBRARY; pressing it is when macOS shows the Media & Apple
  Music prompt. `refreshing` blinks the LED. `ready` shows the bridge's status
  line, `cached` the cache date. `error` shows the bridge's message, where to
  allow access, and TRY AGAIN when there is no cached data.
- **Badges.** `playable_file` false (streaming, cloud, protected) shows the
  broadcast mark; true shows the file mark.
- **Persistence.** `[windows] library_open, library_width, library_height,
  library_view` in `user://settings.cfg`.

## PlayerBus API (for the library browser)

| Member | Shape |
|---|---|
| `signal library_changed()` | data or state changed |
| `var library: Dictionary` | `{tracks: {id: track}, order: [id], playlists: [{id, name, track_ids}], artists: {name: [id]}, albums: {"<album artist> — <album>": {title, artist, track_ids}}, by_location: {path: id}, count, updated}`. Each `track` is the helper's object (`id, title, artist, album, album_artist, track_number, disc_number, duration_ms, genre, location, playable_file, protected, cloud_only, kind`) plus `entry`, the playlist entry it adds. Album track lists are in disc/track order. `track_ids` only reference known tracks. |
| `var library_state: String` | `"empty" \| "cached" \| "refreshing" \| "ready" \| "error"` |
| `func track_meta(path) -> Dictionary` | `{title, artist, album, duration (s, 0 unknown), source: "file" \| "applemusic"}`. Library lookup for `applemusic:` and known file paths, otherwise the file name. |
| `const APPLE_MUSIC_PREFIX` | `"applemusic:"` |
| `const AUDIO_EXTENSIONS`, `const AUDIO_FILE_FILTERS` | playable local extensions; `FileDialog.filters` for add-files pickers |

Commands:

| Command | Handled by |
|---|---|
| `library_refresh` | MusicBridge: background `library` read |
| `open_library` | MusicBridge refreshes once per session if it has not already; the player window opens the library panel |
| `toggle_library` / `close_library` | Player window: LIB button, Ctrl+Shift+L, ≡ menu (opening sends `open_library`) |
| `add_library_tracks {ids: [id], play: bool}` | AudioService: appends entries (file path or `applemusic:<ID>`), optionally plays the first |
| `add_library_playlist {id, play: bool}` | AudioService: the playlist's tracks, as above |

`player/player_format.gd display_title()` uses `track_meta` for `applemusic:`
and library-known files ("Artist - Title").

## Permissions

All three prompts name **Oozic** (the app that launches the helper), use the
strings from the app's Info.plist (set in `export_presets.cfg`), and are
stored for the app's bundle ID or signature.

| When | Prompt / setting | Without it |
|---|---|---|
| first library read | Privacy & Security › Media & Apple Music (`NSAppleMusicUsageDescription`) | status: "Couldn't read your Music library…" (helper exit 2) |
| first `play-id` / `watch` with Music running | Privacy & Security › Automation › Oozic › Music (`NSAppleEventsUsageDescription`) | status: "To control Music, allow Oozic under … Automation › Music." (exit 3) |
| first tap | Privacy & Security › Screen & System Audio Recording › System Audio Recording Only (`NSAudioCaptureUsageDescription`) | synthetic beat + status pointing at that pane (exit 3) |

The tap uses `--backend tap` (Core Audio process taps, macOS 14.2+), so it does
not raise the Screen Recording prompt. On older macOS (exit 1) it retries once
with `--backend auto`, the ScreenCaptureKit fallback, which does prompt for
Screen Recording and needs a relaunch after the grant.

Ad-hoc signatures change on every export, so macOS may ask again after a
rebuild. Reset with `tccutil reset MediaLibrary|AppleEvents|AudioCapture local.oozic.recoveryplayer`.

## Limits

- DRM: streaming and protected tracks are never decoded. There is no waveform,
  no pre-analysis, no cached analysis, and no prefetch for them. Reactions use
  the live analyser only, so beat tracking needs a few seconds to lock on.
- Playback happens in the Music app: audio device, EQ and crossfade settings are
  Music's. Turn off Music's crossfade so end-of-track detection stays clean.
- Gapless: after Music auto-advances, there can be a fraction of a second of
  its next track before our next `play-id` lands.
- Volume and mute set Music's own volume, and Music keeps that value after
  Oozic quits.
- **Editor vs exported app.** Under the Godot editor (or `--script`), the
  responsible process is Godot.app or the terminal, whose Info.plist lacks the
  keys above. The tap is refused without a prompt there, and Automation likely
  is too. Test Apple Music in an exported build. The library may work if the
  launching app already has Media access.
- Running the exported binary directly from a terminal also attributes TCC to
  the terminal, not to Oozic. Launch the `.app` from Finder or with `open` to
  get Oozic's own prompts.

## Diagnostics

- `-- --music-library-report` refreshes the library, prints
  `MUSIC_LIBRARY {...counts...}` and quits.
- `-- --music-permissions-report` prints `MUSIC_PERMISSIONS {...}` (the
  helper's `permissions`, which never prompts) and quits.
- F3 overlay: `react.source` shows `live` or `mock`.

## Tests

- `test_music_bridge.gd` drives AudioService against `tools/fake_music_helper.sh`,
  selected with `OOZIC_MUSIC_HELPER`.
- `test_audio_formats.gd` covers the local formats (fixtures made with `afconvert`).
- `test_library_browser.gd` covers the browser on a synthetic library
  (`library_fixture.gd`: made-up artists and titles, 1,430 and 20,000 tracks):
  views and counts, search, sorting, drill-in, multi-select, the commands and
  ids of every action, states, virtualised rows, resize and persistence.
