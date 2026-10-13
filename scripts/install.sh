#!/usr/bin/env bash
# AirSpeaker.driver'ı /Library/Audio/Plug-Ins/HAL altına kurar ve coreaudiod'u
# yeniden başlatır. Kullanım: scripts/install.sh [derleme-klasörü]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${1:-$ROOT/build}"
DRIVER="AirSpeaker.driver"
SRC="$BUILD_DIR/$DRIVER"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
DEST="$HAL_DIR/$DRIVER"

if [[ ! -d "$SRC" ]]; then
  echo "Hata: $SRC bulunamadı. Önce derleyin:" >&2
  echo "  cmake --preset default && cmake --build --preset default" >&2
  exit 1
fi

echo "==> İmza doğrulanıyor"
codesign --verify --strict "$SRC"

echo "==> Kuruluyor: $DEST (yönetici parolası istenebilir)"
sudo mkdir -p "$HAL_DIR"
sudo rm -rf "$DEST"
sudo ditto "$SRC" "$DEST"
# coreaudiod yalnızca root'a ait ve başkalarınca yazılamayan eklentileri yükler.
sudo chown -R root:wheel "$DEST"
sudo chmod -R go-w "$DEST"

"$ROOT/scripts/restart-coreaudio.sh"

echo "==> Kurulum tamamlandı. Sistem Ayarları > Ses > Çıkış bölümünde 'iPad Ses Çıkışı' görünmelidir."
if [[ -x "$BUILD_DIR/airspeaker-check" ]]; then
  "$BUILD_DIR/airspeaker-check" --wait 10 || true
fi
