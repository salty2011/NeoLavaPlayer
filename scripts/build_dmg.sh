#!/bin/sh
# Export the macOS app with Godot and wrap it in a drag-to-Applications DMG.
#   scripts/build_dmg.sh [version]
# Needs Godot 4.7.1 with macOS export templates. GODOT overrides the binary
# (default: /Applications/Godot.app/Contents/MacOS/Godot). Output: dist/.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
VERSION=${1:-dev}
NAME="NeoLavaPlayer"
DIST="$ROOT/dist"
STAGE="$DIST/stage"
APP="$STAGE/$NAME.app"
DMG="$DIST/$NAME-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"

# Rebuild the native Music helper so the binary matches its source.
if command -v swiftc >/dev/null 2>&1; then
	sh "$ROOT/native-player/native/music-helper/build.sh"
fi

"$GODOT" --headless --path "$ROOT/native-player" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$ROOT/native-player" --export-release macOS "$APP"
test -d "$APP" || { echo "export failed: $APP missing" >&2; exit 1; }

ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "$DMG"
