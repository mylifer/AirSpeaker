#!/usr/bin/env bash
# AirSpeaker'ın tüm bileşenlerini (sürücü, broker, uygulama) kaldırır.
# Kurulum paketiyle de scripts/install.sh ile de kurulmuş olsa çalışır.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/packaging/uninstall.sh" "$@"
