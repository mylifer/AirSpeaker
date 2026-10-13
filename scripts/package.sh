#!/usr/bin/env bash
# Kurulum paketi ve disk görüntüsü üretir:
#   build/AirSpeaker-<sürüm>.pkg  (sürücü + broker + uygulama, tek kurulum)
#   build/AirSpeaker-<sürüm>.dmg  (pkg + Beni Oku)
#
# Önce derleyin:
#   cmake --preset default && cmake --build --preset default
#   scripts/build-app.sh release --universal
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
VERSION="$(cat "$ROOT/VERSION")"
WORK="$BUILD/package"
PAYLOAD="$WORK/root"
BROKER_LABEL="com.mylifer.airspeaker.broker"

for path in "$BUILD/AirSpeaker.driver" "$BUILD/airspeaker-broker" "$BUILD/AirSpeaker.app"; do
  if [[ ! -e "$path" ]]; then
    echo "Hata: $path bulunamadı (betiğin başındaki derleme adımlarına bakın)." >&2
    exit 1
  fi
done

echo "==> Kurulum içeriği hazırlanıyor"
rm -rf "$WORK"
mkdir -p "$PAYLOAD/Applications" \
         "$PAYLOAD/Library/Audio/Plug-Ins/HAL" \
         "$PAYLOAD/Library/PrivilegedHelperTools" \
         "$PAYLOAD/Library/LaunchDaemons" \
         "$PAYLOAD/Library/Application Support/AirSpeaker"
ditto "$BUILD/AirSpeaker.app" "$PAYLOAD/Applications/AirSpeaker.app"
ditto "$BUILD/AirSpeaker.driver" "$PAYLOAD/Library/Audio/Plug-Ins/HAL/AirSpeaker.driver"
install -m 755 "$BUILD/airspeaker-broker" "$PAYLOAD/Library/PrivilegedHelperTools/$BROKER_LABEL"
install -m 644 "$ROOT/Broker/$BROKER_LABEL.plist" "$PAYLOAD/Library/LaunchDaemons/$BROKER_LABEL.plist"
install -m 755 "$ROOT/packaging/uninstall.sh" "$PAYLOAD/Library/Application Support/AirSpeaker/uninstall.sh"
chmod -R go-w "$PAYLOAD"

# pkgbuild varsayılan olarak paketleri "taşınabilir" işaretler: aynı bundle
# kimliğine sahip bir kopya başka bir yerde varsa (ör. build/AirSpeaker.app)
# kurulum oraya yapılır. Bunu kapat; her şey tam olarak belirtilen yere gitsin.
COMPONENTS="$WORK/components.plist"
pkgbuild --analyze --root "$PAYLOAD" "$COMPONENTS"
index=0
while /usr/libexec/PlistBuddy -c "Print :$index" "$COMPONENTS" >/dev/null 2>&1; do
  /usr/libexec/PlistBuddy -c "Set :$index:BundleIsRelocatable false" "$COMPONENTS"
  index=$((index + 1))
done

echo "==> pkg oluşturuluyor"
pkgbuild --root "$PAYLOAD" \
         --component-plist "$COMPONENTS" \
         --identifier com.mylifer.airspeaker \
         --version "$VERSION" \
         --scripts "$ROOT/packaging/scripts" \
         --install-location / \
         "$WORK/AirSpeaker-component.pkg"

sed "s/@VERSION@/$VERSION/g" "$ROOT/packaging/distribution.xml.in" > "$WORK/distribution.xml"
PKG="$BUILD/AirSpeaker-$VERSION.pkg"
productbuild --distribution "$WORK/distribution.xml" \
             --resources "$ROOT/packaging/resources" \
             --package-path "$WORK" \
             "$PKG"

echo "==> dmg oluşturuluyor"
DMG_DIR="$WORK/dmg"
mkdir -p "$DMG_DIR"
cp "$PKG" "$DMG_DIR/AirSpeaker Kurulum.pkg"
cp "$ROOT/packaging/BeniOku.txt" "$DMG_DIR/Beni Oku.txt"
DMG="$BUILD/AirSpeaker-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "AirSpeaker $VERSION" -srcfolder "$DMG_DIR" -ov -format UDZO "$DMG" >/dev/null

echo "==> Hazır:"
echo "    $PKG"
echo "    $DMG"
