#!/bin/bash
# AirSpeaker'ı tamamen kaldırır: menü çubuğu uygulaması, ses sürücüsü ve
# broker daemon'u. Kurulum paketi bu betiği şuraya da kopyalar:
#   /Library/Application Support/AirSpeaker/uninstall.sh
# Kullanım: sudo "/Library/Application Support/AirSpeaker/uninstall.sh"
set -u

if [[ $EUID -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

BROKER_LABEL="com.mylifer.airspeaker.broker"

echo "==> AirSpeaker kaldırılıyor"
pkill -x AirSpeaker 2>/dev/null || true
launchctl bootout "system/$BROKER_LABEL" 2>/dev/null || true

rm -rf "/Applications/AirSpeaker.app" \
       "/Library/Audio/Plug-Ins/HAL/AirSpeaker.driver" \
       "/Library/PrivilegedHelperTools/$BROKER_LABEL" \
       "/Library/LaunchDaemons/$BROKER_LABEL.plist" \
       "/Library/Application Support/AirSpeaker"
pkgutil --forget com.mylifer.airspeaker >/dev/null 2>&1 || true

echo "==> coreaudiod yeniden başlatılıyor"
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod 2>/dev/null || true
echo "==> AirSpeaker kaldırıldı."
