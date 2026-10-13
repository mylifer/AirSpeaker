#!/usr/bin/env bash
# AirSpeaker sistem bileşenlerini (sürücü + broker) kaldırır ve coreaudiod'u
# yeniden başlatır.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BROKER_LABEL="com.mylifer.airspeaker.broker"

echo "==> airspeaker-broker kaldırılıyor"
sudo launchctl bootout "system/$BROKER_LABEL" 2>/dev/null || true
sudo rm -f "/Library/LaunchDaemons/$BROKER_LABEL.plist" "/Library/PrivilegedHelperTools/$BROKER_LABEL"

echo "==> AirSpeaker.driver kaldırılıyor"
sudo rm -rf "/Library/Audio/Plug-Ins/HAL/AirSpeaker.driver"

"$ROOT/scripts/restart-coreaudio.sh"
echo "==> Kaldırıldı."
