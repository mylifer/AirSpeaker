#!/usr/bin/env bash
# AirSpeaker.driver'ı sistemden kaldırır ve coreaudiod'u yeniden başlatır.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="/Library/Audio/Plug-Ins/HAL/AirSpeaker.driver"

if [[ ! -e "$DEST" ]]; then
  echo "AirSpeaker.driver kurulu değil ($DEST)."
  exit 0
fi

echo "==> Kaldırılıyor: $DEST"
sudo rm -rf "$DEST"
"$ROOT/scripts/restart-coreaudio.sh"
echo "==> Kaldırıldı."
