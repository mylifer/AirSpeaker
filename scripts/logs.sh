#!/usr/bin/env bash
# Sürücünün os_log çıktısını ve coreaudiod'un AirSpeaker ile ilgili mesajlarını
# canlı izler. Durdurmak için Ctrl+C.
set -euo pipefail

exec log stream --style compact --level debug --predicate \
  'subsystem == "com.mylifer.airspeaker" OR (process == "coreaudiod" AND eventMessage CONTAINS[c] "AirSpeaker")'
