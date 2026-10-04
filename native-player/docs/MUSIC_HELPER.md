# oozic-music-helper

A small native macOS command-line tool that gives the Godot player access to
the Apple Music side of the Mac. Godot launches it with
`OS.execute_with_pipe()` and reads its stdout.

- Source: `native-player/native/music-helper/` (Swift, built with plain `swiftc`)
- Build: `native-player/native/music-helper/build.sh` produces a universal
  (arm64 + x86_64), ad-hoc signed binary at `native-player/bin/oozic-music-helper`
  (about 400 KB). The built binary is committed so exports can bundle it
  without Xcode.
- Minimum macOS is 12.0 for `library`/`now`/`watch`/`control`. `tap` needs
  14.2+ for process taps, or 13.0+ for the ScreenCaptureKit fallback.

## Why it exists (DRM boundary)

Apple Music subscription tracks and other streamed tracks are FairPlay
protected. Third-party apps cannot decode them, and this helper does not try
to. There are two paths instead:

1. **Owned, unprotected files** (`playable_file: true` in `library`): Godot
   plays the file at `location` itself.
2. **Everything else** (streaming, cloud-only, protected): the Music app plays
   the track. Godot drives Music with `control`, follows it with `watch`, and
   feeds the visualiser from `tap`, which captures the Music app's output
   audio.

## Contract (frozen)

Every JSON document is a single line terminated by `\n`. Any field not listed
here is additive and may be ignored.

### Exit codes

| code | meaning |
|---|---|
| 0 | success (also: clean exit on SIGTERM/SIGINT/SIGHUP, or when the reader closes the pipe) |
| 1 | usage error / bad arguments / no usable capture backend |
| 2 | `library`: the Music library could not be opened (access denied or unreadable) |
| 3 | permission denied (`tap`: audio capture; `now`/`watch`/`control`: Automation) |
| 4 | `control`: Music is not running, and the command does not launch it |
| 5 | `control play-id`: no library track with that persistent ID |
| 6 | `control`: other AppleScript error |

### Persistent IDs

All ids (`library` tracks and playlists, `now.id`, `control play-id`) are
**16 upper-case hex digits**, e.g. `"1A2B3C4D5E6F7081"`. That is the exact
form AppleScript's `persistent ID` returns, so an id from `library` can go
straight to `control play-id`, and `now.id` can be matched back to a library
track.

### `library [--stats]`

One JSON object on stdout:

```json
{"tracks":[{"id":"…","title":"…","artist":"…","album":"…","album_artist":"…",
  "track_number":1,"disc_number":1,"duration_ms":215000,"genre":"…",
  "location":"/abs/path.mp3","playable_file":true,"protected":false,
  "cloud_only":false,"kind":"MPEG audio file"}],
 "playlists":[{"id":"…","name":"…","track_ids":["…"]}]}
```

- Read with `iTunesLibrary.framework` (`ITLibrary`), a read-only snapshot of
  the Music library. Music does not need to be running.
- Missing strings are `""`, never `null`. Only `location` can be `null`.
- `location` is set only for items with a local file
  (`locationType == file`).
- `playable_file` is `location != null && !protected && ext in {mp3, m4a, aac,
  aiff, aif, wav, flac, alac}`. ALAC files use the `.m4a` extension. The
  helper does **not** check that the file exists. Checking would `stat` paths
  that can sit in TCC-protected folders (Desktop, Documents, external
  volumes) and trigger surprise prompts. Godot must handle an open failure,
  for example a file on an unmounted drive.
- `protected` is `ITLibMediaItem.isDRMProtected`. The framework reports
  `false` for Apple Music catalogue tracks that are not downloaded, so
  `protected:false` does **not** mean decodable. Only `playable_file` is
  authoritative.
- `cloud_only` is `isCloud && location == null`.
- Tracks include media kinds song, music video, and unknown. Movies, TV,
  podcasts, audiobooks and books are left out.
- Playlists leave out the master "Library" list, hidden lists, and the
  media-type views (Music, Movies, TV, Podcasts, and so on). Folders are
  included, and their `track_ids` cover their children. `track_ids` only
  reference tracks present in `tracks`.
- `--stats` writes one JSON timing/count line to **stderr**.
- Failure: exit 2 with a message on stderr.

Performance on the dev machine (1,430 tracks, 9 playlists, 486 KB of JSON):
about 150 ms total. That is 30 ms to open, 124 ms to build (mostly the
framework's first-touch property loading, about 80 µs per item), and under
1 ms to write. On its own, the JSON writer handles 100k synthetic tracks
(40 MB) in about 100 ms. Projection: about 4 s for a 50k-track library, so
call `library` once in the background and cache the result.

### `tap [--app BUNDLE_ID | --system] [--rate 48000] [--backend auto|tap|sck]`

- **stdout**: continuous raw PCM, interleaved stereo float32 little-endian at
  `--rate` (default 48000, accepts 8000–192000). Every write is a whole number
  of frames (8 bytes per frame).
- **stderr**: the first line is the header
  `{"rate":48000,"channels":2,"format":"f32le","source":"app|system","backend":"tap|sck"}`.
  After that come JSON event lines:
  `{"event":"waiting","app":"com.apple.Music"}`,
  `{"event":"attached","backend":"tap","source":"app","pids":[123]}`,
  `{"event":"detached","reason":"app_exited"}`,
  `{"event":"stalled",…}`, `{"event":"fallback","from":"tap","to":"sck",…}`,
  `{"event":"error",…}`, and on denial
  `{"event":"error","error":"permission_denied","message":"…"}` (exit 3).
  The header is written once the backend is chosen. If a permission prompt
  is showing, that waits until the user answers it.
- `--app` (default `com.apple.Music`) taps only that app's processes, matched
  by Core Audio process bundle ID `== id` or `id.*`. If the app is not
  running, the helper writes nothing and keeps polling every second. It
  attaches when the app starts and re-attaches when it restarts. When the app
  is running but paused, the tap delivers digital silence (zeros) at full
  rate.
- `--system` taps all system output except this process.
- `--backend` (additive option; default `auto`):
  - `auto`: use a process tap. If taps are unavailable (macOS older than 14.2)
    or System Audio Recording is denied, fall back to ScreenCaptureKit. If
    that is also denied, exit 3.
  - `tap`: process tap only, with exit 3 on denial. Use this to avoid the
    Screen Recording prompt that the fallback would cause.
  - `sck`: ScreenCaptureKit only.
- Output-device changes (for example headphones unplugged) cause a re-attach.
- If the reader cannot keep up, blocks beyond about 2 s of backlog are
  dropped. Memory does not grow.
- Exits 0 on SIGTERM/SIGINT/SIGHUP, on EPIPE (reader closed the pipe), and
  when re-parented to launchd (the parent died). Taps and aggregate devices
  are destroyed on exit. They are private to the process in any case.
- Debug env vars (not part of the contract): `OOZIC_DEBUG=1` prints IO
  counters to stderr every second. `OOZIC_TAP_SKIP_TCC=1` skips the
  permission gate, which is useful only for checking the plumbing. Without
  permission the tap is silent.

#### How the process-tap path works

The helper finds the target's Core Audio process objects
(`kAudioHardwarePropertyProcessObjectList`, then
`kAudioProcessPropertyBundleID`). It builds a stereo-mixdown
`CATapDescription` (private, unmuted) and calls
`AudioHardwareCreateProcessTap`. It then creates a private aggregate device
with the default output device as its clock and the tap in
`kAudioAggregateDeviceTapListKey`. An IOProc reads the tap stream, and
`AVAudioConverter` converts it to interleaved f32 at `--rate`.

One quirk, observed on macOS 27: a fresh process whose first HAL IO is a tap
aggregate may receive no IO callbacks. The helper therefore runs one silent
0.25 s IO cycle on a plain aggregate of the output device first
(`primeOutputDevice`). A 2 s watchdog repeats the prime and re-attaches once
if the tap still produces nothing (`{"event":"stalled"}`).

### `now`

One line on stdout:

```json
{"running":true,"state":"playing","id":"…","title":"…","artist":"…","album":"…","position":12.345,"duration":215.000,"volume":60}
```

- `state` is `playing | paused | stopped`. Fast-forwarding and rewinding
  count as `playing`.
- `position` and `duration` are in seconds. `volume` is Music's
  `sound volume` (0–100).
- **Never launches Music.** It checks `NSRunningApplication` first, and the
  script starts with an `is running` guard. If Music is not running, it
  prints `{"running":false,"state":"stopped","id":"",…,"volume":0}`. No Apple
  Event is sent in that case, so there is no Automation prompt.
- For radio streams with no track name, `title` falls back to
  `current stream title`.
- If Automation is denied, it prints a line with
  `"error":"automation_denied"` and exits 3.

### `watch [--interval 0.5]`

Prints the same line as `now` every interval (minimum 0.05 s) until killed.
It compiles the AppleScript once and reuses it. Exit codes are as above. It
exits 3 on Automation denial and 0 on SIGTERM, a closed pipe, or parent
death.

### `control <cmd>`

`play | pause | playpause | stop | next | previous | seek SECONDS | volume 0-100 | play-id PERSISTENT_ID`

- Prints one line: `{"ok":true,"command":"seek"}` or
  `{"ok":false,"command":"…","error":"bad_args|not_running|automation_denied|not_found|script_error","message":"…"}`.
- `play`, `playpause` and `play-id` launch Music if needed. All other
  commands return `not_running` (exit 4) when Music is not running.
- `play-id` runs
  `play (first track of library playlist 1 whose persistent ID is "<ID>")`.
  This works for streaming and cloud tracks in the library, since Music
  handles the DRM.
- `volume` sets Music's own volume, not the system volume.

### `permissions` (additive diagnostic)

Prints the status of each permission without prompting, so Godot can show a
setup screen:

```json
{"media_library":"granted|denied|not_determined|unknown","audio_capture":"…","screen_capture":"granted|not_granted","automation_music":"granted|denied|not_determined|unknown_music_not_running","music_running":false}
```

### `version`

Prints `{"version":"1.0.0"}`.

## Permissions (TCC) and attribution

**Attribution:** TCC charges every check to the **responsible process**. A
child started by `fork`/`posix_spawn` inherits its parent's responsibility,
unless the parent opts out with `responsibility_spawnattrs_setdisclaim`, and
Godot does not. So when the Godot app spawns the helper:

- the prompt names **the Godot app**, not the helper,
- the grant is stored for the Godot app's bundle ID or code signature, and
- the usage-description strings come from **the Godot app's Info.plist**. The
  helper's own embedded Info.plist (`__TEXT,__info_plist`, bundle ID
  `local.oozic.music-helper`) does not decide what the user sees.

If the responsible app's Info.plist lacks the key, TCC refuses without
showing any prompt. This was reproduced while building the helper. The
helper ran under Claude Code (`com.anthropic.claude-code`), which has no
`NSAudioCaptureUsageDescription`. `TCCAccessRequest(kTCCServiceAudioCapture)`
returned false at once, the status stayed `not_determined`, and `tap` exited
3 with "denied without a prompt … must declare NSAudioCaptureUsageDescription".

| Feature | TCC service | System Settings pane | Info.plist key needed by the **parent app** | Notes |
|---|---|---|---|---|
| `library` | `kTCCServiceMediaLibrary` | Privacy & Security > Media & Apple Music | `NSAppleMusicUsageDescription` | Exit 2 when denied |
| `tap` (process tap) | `kTCCServiceAudioCapture` | Privacy & Security > Screen & System Audio Recording > **System Audio Recording Only** | `NSAudioCaptureUsageDescription` | Without a grant the tap is *silent* rather than failing. The helper therefore preflights and requests through the private TCC SPI (`TCCAccessPreflight`/`TCCAccessRequest`, loaded with `dlopen`). The prompt appears on the first `tap`. |
| `tap` fallback (ScreenCaptureKit) | `kTCCServiceScreenCapture` | Privacy & Security > Screen & System Audio Recording | none (no usage-string key exists) | `CGRequestScreenCaptureAccess()` prompts once. A grant only takes effect after the app is **relaunched**. The system also shows periodic "is still recording" reminders. |
| `now`/`watch`/`control` | `kTCCServiceAppleEvents` (target `com.apple.Music`) | Privacy & Security > Automation > *App* > Music | `NSAppleEventsUsageDescription` | Prompted on the first Apple Event while Music is running. Error -1743 means exit 3. |

### What the Godot export needs

The Godot 4.7.1 macOS export preset (`native-player/export_presets.cfg`)
now has items 1–3 and uses the `.pck` + `user://` alternative in item 4
(see [APPLE_MUSIC.md](APPLE_MUSIC.md)).

1. **Info.plist keys**, through `application/additional_plist_content`:
   ```xml
   <key>NSAppleMusicUsageDescription</key><string>OozicPlayer reads your Music library so you can play your own tracks.</string>
   <key>NSAudioCaptureUsageDescription</key><string>OozicPlayer listens to the Music app's audio so the visualiser can react to it.</string>
   <key>NSAppleEventsUsageDescription</key><string>OozicPlayer controls the Music app (play, pause, skip).</string>
   ```
2. **Entitlement** `codesign/entitlements/apple_events = true`. This is only
   strictly needed if the app or helper is signed with the hardened runtime.
   It costs nothing either way.
3. **App Sandbox off**, which is the current preset. Sandboxed apps cannot
   send Apple Events to Music without temporary-exception entitlements.
4. **Where the binary lives.** It is recommended to embed it in the bundle as
   a helper executable. Godot's `codesign/entitlements/app_sandbox/helper_executables`
   copies the listed files into `Contents/Helpers/` and signs them. At
   runtime the path is
   `OS.get_executable_path().get_base_dir().path_join("../Helpers/oozic-music-helper")`.
   Check after export with `codesign -dv --entitlements - <app>/Contents/Helpers/oozic-music-helper`.
   If the export signs the helper with the hardened runtime, it must also
   carry `com.apple.security.automation.apple-events`, because the helper is
   the process that sends the events. Ad-hoc signing without the hardened
   runtime, which is what `build.sh` produces, needs no entitlements.
   - **Alternative:** ship it inside the `.pck` (add `oozic-music-helper`
     to `include_filter`) and copy it to `user://` at first run. This works.
     The ad-hoc signature is embedded and survives the copy. Files the app
     writes itself are not quarantined, because Godot does not set
     `LSFileQuarantineEnabled`. You must then
     `OS.execute("/bin/chmod", ["+x", path])`, since the `.pck` loses the
     exec bit. Attribution is the same, because responsibility follows the
     parent process, not the file location. The downside is that the helper
     sits outside the signed and notarized bundle, which is fine for local
     builds and weaker for distribution.
   - A binary cannot be executed from inside the `.pck`. It has to be a real
     file.
5. **Running from the Godot editor.** The game process is spawned by
   `Godot.app` (`org.godotengine.godot`), which becomes the responsible
   process. Godot 4.7.1's Info.plist declares only
   `NSMicrophoneUsageDescription`. In the editor, `tap` will therefore be
   refused without a prompt (exit 3). `now`/`control` Automation prompts
   are likely refused too. Test those in an exported build that has the keys
   above. `library` may work if the editor already holds the Media grant.

### Re-prompting during development

An ad-hoc signature changes on every rebuild. TCC may then treat the
**parent** app as a new identity and prompt again or ignore an earlier
grant. To reset: `tccutil reset AudioCapture <bundle-id>`,
`tccutil reset AppleEvents <bundle-id>`, `tccutil reset MediaLibrary <bundle-id>`.

## Integration sketch (GDScript)

```gdscript
var h := OS.execute_with_pipe(helper_path, ["tap", "--app", "com.apple.Music", "--rate", "48000"])
var pcm: FileAccess = h["stdio"]   # read f32le stereo frames
var err: FileAccess = h["stderr"]  # first line: header JSON; then events
# stop: close the pipes (helper exits 0 on its next write) or OS.kill(h["pid"])
```

Godot's `OS.kill()` sends SIGKILL on Unix, so the helper's cleanup does not
run. That is harmless. The tap and aggregate device are created *private*,
and coreaudiod destroys them when the owning process dies. When the parent
quits without killing the helper, the helper sees EPIPE or notices it has
been re-parented to launchd within about 1 s, and exits.

Read stderr as well as stdout, or at least drain it. A full stderr pipe
blocks the helper's event writes.
