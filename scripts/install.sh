#!/usr/bin/env bash
# Sistem bileşenlerini kurar:
#   - airspeaker-broker  -> /Library/PrivilegedHelperTools + /Library/LaunchDaemons
#   - AirSpeaker.driver  -> /Library/Audio/Plug-Ins/HAL
# ve coreaudiod'u yeniden başlatır. Kullanım: scripts/install.sh [derleme-klasörü]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${1:-$ROOT/build}"

DRIVER_SRC="$BUILD_DIR/AirSpeaker.driver"
DRIVER_DEST="/Library/Audio/Plug-Ins/HAL/AirSpeaker.driver"

BROKER_LABEL="com.mylifer.airspeaker.broker"
BROKER_SRC="$BUILD_DIR/airspeaker-broker"
BROKER_DEST="/Library/PrivilegedHelperTools/$BROKER_LABEL"
BROKER_PLIST_SRC="$ROOT/Broker/$BROKER_LABEL.plist"
BROKER_PLIST_DEST="/Library/LaunchDaemons/$BROKER_LABEL.plist"

for path in "$DRIVER_SRC" "$BROKER_SRC"; do
  if [[ ! -e "$path" ]]; then
    echo "Hata: $path bulunamadı. Önce derleyin:" >&2
    echo "  cmake --preset default && cmake --build --preset default" >&2
    exit 1
  fi
done

echo "==> İmzalar doğrulanıyor"
codesign --verify --strict "$DRIVER_SRC"
codesign --verify --strict "$BROKER_SRC"

echo "==> airspeaker-broker kuruluyor (yönetici parolası istenebilir)"
sudo launchctl bootout "system/$BROKER_LABEL" 2>/dev/null || true
sudo mkdir -p "$(dirname "$BROKER_DEST")"
sudo install -m 755 -o root -g wheel "$BROKER_SRC" "$BROKER_DEST"
sudo install -m 644 -o root -g wheel "$BROKER_PLIST_SRC" "$BROKER_PLIST_DEST"
sudo launchctl bootstrap system "$BROKER_PLIST_DEST"

echo "==> AirSpeaker.driver kuruluyor: $DRIVER_DEST"
sudo mkdir -p "$(dirname "$DRIVER_DEST")"
sudo rm -rf "$DRIVER_DEST"
sudo ditto "$DRIVER_SRC" "$DRIVER_DEST"
# coreaudiod yalnızca root'a ait ve başkalarınca yazılamayan eklentileri yükler.
sudo chown -R root:wheel "$DRIVER_DEST"
sudo chmod -R go-w "$DRIVER_DEST"

"$ROOT/scripts/restart-coreaudio.sh"

echo "==> Kurulum tamamlandı. Sistem Ayarları > Ses > Çıkış bölümünde 'iPad Ses Çıkışı' görünmelidir."
if [[ -x "$BUILD_DIR/airspeaker-check" ]]; then
  "$BUILD_DIR/airspeaker-check" --wait 10 || true
fi
