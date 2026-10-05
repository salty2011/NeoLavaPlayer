# Oozic Recovery Player — native Mac recovery in progress

Open `../builds/Oozic Recovery Player.app` on this Mac. This is an ad-hoc-signed universal macOS Godot application. It opens Winamp-style panels that snap and dock together: the **player** (LCD time and spectrum, seek bar, transport), the resizable **playlist** below it, the **music library** (LIB) and the **visualiser** in a matching frame beside them. Drag Main to move the docked group, drag any other panel to detach it, drop it against an edge to dock it; ≡ → Reset window layout (Ctrl+Shift+R) restores the default. It is drawn in code, so it stays sharp on Retina and 4K screens; Settings → Display sets its size. Add FLAC or MP3 files with the ⏏ button or the playlist's ADD button, drop them on either window, or import an .m3u file. Keys work in any window: Space pauses, the arrows seek and change the volume, Tab hides the player, and F11 or a double-click makes the visualiser fullscreen. The original Ctrl accelerators also work. See PLAYER_CONTROLS.md and docs/WINDOWS_AND_BUS.md.

The app opens on Triple Trance, the current fidelity target. Its three heads use recovered Shape/Bump/Cos deformation and original event colors, with textured stems/platform, camera motion, original light settings and a selectable wireframe view. Triple Trance uses recovered fixed-function vertex ambient/diffuse/specular lighting with original shininess and texture modulation. Exact visual parity and the shared random sequence remain unverified.

All 29 recovered LAVA 2.5 and Oozic 3 scene packages are selectable. Original ASHEX/LVC composition, object transforms, hierarchy, cameras, binary meshes and supported parametric models are interpreted at runtime. Hydroid has the tree on the surfboard, its recovered crawl/decay motion, board deformation, moving torus and original audio input formulas. Geometry and textures respond to captured MP3 PCM through the recovered Hann/FFT and per-band/global normalization. Each scene uses its actual frequency ranges.

This remains a recovery project, not verified original playback. The Recovery details button reports missing resources and unsupported behaviors. Modern material/lighting conversion, whole-scene random sequence parity, some effect families, script/timeline behavior and the AK1200 BLOB remain unfinished. All scene packages loading does not establish visual fidelity. The remembered whale and Apple Music analysis remain unresolved.

Phase 1b adds features of the original engine:

- The effect toggles from the scene `Style` mask: texture, wire frame, strobe, colored lighting, dynamic coloring, pause camera, flat shading and lights. They use the original hotkeys (T W S L C P, with Shift+F3/F4).
- The 3D text message (M), for example the "Triple Trance" ring.
- The intro screen from intro.ini (N).
- Response and Brightness, exposed as engine API calls and as the original 0–100 sliders in Settings → Scenes.
- F5–F8 special-effect preset categories.
- Three more effect classes: DefSwitch, DefElastic and DefSuperBump.

See docs/ENGINE_API.md and docs/EFFECTS_RECOVERED.md. Each item there is marked confirmed or inferred.

Phase 2 splits the app into windows:

- **Two independent OS windows** that talk only through the `PlayerBus` autoload. Playback lives in a non-visual service, so the music keeps playing whichever window is hidden or minimised.
- **The player window.** Phase 2 drew the original LAVA! 2.5 and Oozic 3 skins extracted by `tools/extract_skins.py`. They were tiny on high-DPI screens, so they have been replaced by an original, procedurally drawn player (`player/`). The extraction tools and `research/` remain as history.
- **A persistent, editable playlist** with .m3u import/export.
- **Scene titles** read from the ASHEX header.
- **Multi-scene cycling**: 30 s to 1 h, random or alphabetical, or per track.
- **A Settings window** with an Effects tab that wires the Phase 1b engine API.
- **Saved window placement** (position, screen, fullscreen), clamped to the monitors connected now.
- **`--scene-only`**, a screensaver-style mode that runs the visualiser without the player.

See docs/WINDOWS_AND_BUS.md.

Build with Godot 4.7.1 and its macOS export templates, from the repository root:

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path native-player --export-debug macOS '../builds/Oozic Recovery Player.app'
```

Packaged smoke mode accepts `-- --smoke-report=/absolute/path/report.json`. Set `OOZIC_TEST_MP3` to an external MP3 for its external-file decode check. It verifies actual decoding and captured audio, playback, playlist navigation, pause, seek, stop, original band ranges and Hydroid motion, saves a screenshot and exits.

Rendered sweep mode accepts `-- --scene-sweep-report=/absolute/path/report.json`. It plays the bundled local MP3 and renders every scene with its original camera, recording screenshots and per-scene coverage. Current evidence is in `../research/oozic/proof/rendered-scenes` and `../research/oozic/proof/player-runtime-report.json`.

Recovered source assets, static disassembly evidence, numerical tests and notes are retained in `../research/oozic`. Original embedded object previews are isolated thumbnails, not original full-scene reference screenshots. Assets are retained for personal recovery; no redistribution rights have been established.

FLAC playback uses the built-in macOS Core Audio decoder, runs decoding off the UI thread, and loads temporary stereo 16-bit PCM at the source sample rate. The temporary file is removed after loading; your FLAC remains unchanged. No FFmpeg or extra codec is required for playback. High-resolution FLAC is currently reduced to 16-bit for the Godot stream. File picking, drag-and-drop, mixed playlists, seek and audio-driven scenes support FLAC. Packaged evidence: `research/oozic/proof/flac-report.json`.

## Apple Music

Tracks from your Music library can go in the playlist. Owned, unprotected files play directly. Apple Music streaming, iCloud and protected tracks play in the Music app: Oozic starts, pauses, seeks and skips them there, follows what Music is playing, and feeds the visualiser from a capture of the Music app's audio. They are never decoded, because they are DRM-protected, and there is no pre-analysis for them; the visualiser reacts from live analysis. macOS asks once for access to Media & Apple Music, Automation (Music), and System Audio Recording. If audio capture is denied, the visualiser uses a synthetic beat and the status line says what to allow. Test this in an exported app; under the Godot editor the prompts are refused. Local AAC/ALAC (.m4a), AIFF, WAV and CAF files now play too, decoded like FLAC. The LIB button opens a library browser beside the player: songs, artists, albums and playlists, with search, sorting and play/add actions (PLAYER_CONTROLS.md). See docs/APPLE_MUSIC.md.

Transport, playlist, shuffle and loop behaviour are described in PLAYER_CONTROLS.md. The earlier "original 25 FPS Triple Trance limit" was wrong. The original paced at MaxFrameRate (default 60) with per-frame dt. Scenes now run on fixed 60 Hz ticks at any render rate, and rendering defaults to vsync with no cap. See docs/FRAME_TIMING.md. Debug overlay: F3. Silent synthetic input: `--mock-audio`.
