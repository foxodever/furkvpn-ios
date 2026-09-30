#!/usr/bin/env bash
# Builds libxray.aar (Xray-core + wrapper) for the Android app via gomobile.
set -euo pipefail
cd "$(dirname "$0")"
[ -f /etc/profile.d/android-dev.sh ] && . /etc/profile.d/android-dev.sh
OUT=${1:-../android/app/libs/libxray.aar}
mkdir -p "$(dirname "$OUT")"
gomobile bind -target=android/arm64,android/arm,android/amd64 -androidapi 24 -javapkg com.furkvpn \
  -trimpath -ldflags="-s -w -buildid= -checklinkname=0" -o "$OUT" ./libxray
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
