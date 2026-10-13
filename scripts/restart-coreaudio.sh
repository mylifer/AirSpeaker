#!/usr/bin/env bash
# coreaudiod'u yeniden başlatarak HAL eklentilerinin yeniden yüklenmesini sağlar.
# Not: Bu işlem çalan tüm sesleri kısa bir süre keser.
set -euo pipefail

echo "==> coreaudiod yeniden başlatılıyor"
if ! sudo launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null; then
  # Bazı macOS sürümlerinde SIP, kickstart'a izin vermez; launchd süreci
  # sonlandırıldıktan sonra otomatik olarak yeniden başlatır.
  sudo killall coreaudiod
fi
sleep 2
