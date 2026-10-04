# NeoLavaPlayer

A native macOS recreation of the 1999 **LAVA!** / **Oozic** music visualiser, built in Godot 4. It plays your music and drives the original 3D scenes from the audio, with an optional modern rendering mode.

**Download:** the latest build of `main` is on the [Releases page](../../releases/tag/latest) (`NeoLavaPlayer-latest.dmg`). The app is not signed with an Apple Developer ID, so the first time you open it, right-click the app and choose **Open**, or allow it under System Settings › Privacy & Security.

## Features

- **All 29 scenes from LAVA! 2.5 and Oozic 3**, interpreted at runtime from their original scene packages: meshes, effects, cameras, lighting and 3D text.
- **Music-reactive:** an FFT and per-band analysis like the original's, plus beat, BPM and section tracking (builds, drops, breakdowns). Local files are pre-analysed so the scene can anticipate drops.
- **Classic and Modern rendering.** Classic matches the original look. Modern adds upscaled textures, soft shadows, bloom, fog, particles and a virtual camera director. F9 switches between them.
- **Winamp-style player:** an original, vector-drawn player window with a playlist and a music library browser, sharp on Retina and 4K screens.
- **Formats:** MP3, FLAC, AAC/M4A, ALAC, AIFF, WAV and CAF.
- **Apple Music:**
  - Browse your Music library.
  - Songs you own play directly.
  - Streaming songs play in the Music app while NeoLavaPlayer visualises their audio and controls the Music app. macOS asks for the Media & Apple Music, Automation and System Audio Recording permissions the first time each is needed.

Details are in [`native-player/README.md`](native-player/README.md), [`native-player/PLAYER_CONTROLS.md`](native-player/PLAYER_CONTROLS.md) and [`native-player/docs/`](native-player/docs).

## Building

You need:
- macOS 12 or later
- [Godot 4.7.1](https://godotengine.org/download/archive/4.7.1-stable/) with its macOS export templates
- Xcode command-line tools, for the Music helper

```sh
GODOT=/Applications/Godot.app/Contents/MacOS/Godot sh scripts/build_dmg.sh
```

This writes `dist/NeoLavaPlayer-dev.dmg`. To run from source, open `native-player/project.godot` in Godot.

To run the tests headless, from `native-player/`:

```sh
godot --headless --audio-driver Dummy --path . --script res://test_scene_runtime.gd
```

`test_legacy_lighting.gd` and `test_windows_live.gd` need a window.

GitHub Actions (`.github/workflows/build.yml`) does the following on every push to `main`:
1. Runs the tests.
2. Builds the DMG and keeps it as a workflow artifact.
3. Replaces the `latest` pre-release with the new DMG.

## Original content

The scene packages in `native-player/scenes/`, the textures they use, and the upscaled textures derived from them in `native-player/modern_assets/` come from the original LAVA! and Oozic products, which Creative distributed with its Sound Blaster Live! cards. They belong to their respective rights holders and are included only so this preservation project can show the scenes. The three LVT2 flower textures were never recovered; procedurally generated reconstructions are used instead, and the app labels them as such. If you hold rights to this material and want it removed, please open an issue.

None of the original player's program code is included. The player and engine are a new implementation.
