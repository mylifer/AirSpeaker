#!/usr/bin/env bash
# Swift menü çubuğu uygulamasını derler ve build/AirSpeaker.app olarak paketler.
# Kullanım: scripts/build-app.sh [debug|release] [--universal]
#   --universal  arm64 + x86_64 (Apple Silicon + Intel) tek ikili; dağıtım için.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="release"
UNIVERSAL=0
for argument in "$@"; do
  case "$argument" in
    debug|release) CONFIG="$argument" ;;
    --universal) UNIVERSAL=1 ;;
    *) echo "Kullanım: $0 [debug|release] [--universal]" >&2; exit 64 ;;
  esac
done

VERSION="$(cat "$ROOT/VERSION")"
APP="$ROOT/build/AirSpeaker.app"
cd "$ROOT"

if [[ $UNIVERSAL == 1 ]]; then
  binaries=()
  for arch in arm64 x86_64; do
    swift build -c "$CONFIG" --arch "$arch" --product AirSpeaker
    binaries+=("$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)/AirSpeaker")
  done
  BINARY="$ROOT/build/AirSpeaker-universal"
  mkdir -p "$ROOT/build"
  lipo -create -output "$BINARY" "${binaries[@]}"
else
  swift build -c "$CONFIG" --product AirSpeaker
  BINARY="$(swift build -c "$CONFIG" --show-bin-path)/AirSpeaker"
fi

echo "==> Paketleniyor: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/AirSpeaker"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>AirSpeaker</string>
	<key>CFBundleIdentifier</key>
	<string>com.mylifer.airspeaker.app</string>
	<key>CFBundleName</key>
	<string>AirSpeaker</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<!-- Yalnızca menü çubuğunda çalışır; Dock simgesi yok. -->
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "==> Hazır: open \"$APP\""
