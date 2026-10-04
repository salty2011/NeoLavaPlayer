#!/bin/sh
# Build oozic-music-helper as a universal (arm64 + x86_64), ad-hoc signed
# binary at native-player/bin/oozic-music-helper.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$(cd "$HERE/../.." && pwd)/bin"
OUT="$OUT_DIR/oozic-music-helper"
MIN_MACOS="${MIN_MACOS:-12.0}"
BUILD_DIR="${TMPDIR:-/tmp}/oozic-music-helper-build"

mkdir -p "$OUT_DIR" "$BUILD_DIR"

for arch in arm64 x86_64; do
  xcrun swiftc \
    -O -whole-module-optimization \
    -swift-version 5 \
    -target "$arch-apple-macos$MIN_MACOS" \
    -module-name OozicMusicHelper \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$HERE/Info.plist" \
    -framework iTunesLibrary -framework CoreAudio -framework AVFoundation \
    -Xlinker -weak_framework -Xlinker ScreenCaptureKit -framework AppKit \
    -o "$BUILD_DIR/oozic-music-helper-$arch" \
    "$HERE"/Sources/*.swift
done

xcrun lipo -create -output "$OUT" \
  "$BUILD_DIR/oozic-music-helper-arm64" "$BUILD_DIR/oozic-music-helper-x86_64"
xcrun strip -x "$OUT"
codesign --force --sign - --identifier local.oozic.music-helper "$OUT"

echo "built $OUT ($(xcrun lipo -archs "$OUT"), $(wc -c < "$OUT" | tr -d ' ') bytes)"
