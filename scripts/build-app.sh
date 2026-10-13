#!/usr/bin/env bash
# Swift menü çubuğu uygulamasını derler ve build/AirSpeaker.app olarak paketler.
# Kullanım: scripts/build-app.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/AirSpeaker.app"

cd "$ROOT"
swift build -c "$CONFIG" --product AirSpeaker
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Paketleniyor: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/AirSpeaker" "$APP/Contents/MacOS/AirSpeaker"
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
	<string>0.2.0</string>
	<key>CFBundleVersion</key>
	<string>0.2.0</string>
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
