#!/usr/bin/env bash
# Optional local Mac setup; the existing build scripts and CI do not use this.
# REBUILD_CORE=1 rebuilds the framework after changes in core/.
set -euo pipefail
cd "$(dirname "$0")"

if [ "$(uname -s)" != Darwin ]; then
  echo "error: This optional Xcode setup requires macOS." >&2
  exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: Install Xcode and select it with xcode-select before continuing." >&2
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: XcodeGen is required. Install it with 'brew install xcodegen'." >&2
  exit 1
fi

if [ ! -f Frameworks/Libxray.xcframework/Info.plist ] || [ "${REBUILD_CORE:-0}" = 1 ]; then
  if ! command -v go >/dev/null 2>&1; then
    echo "error: Go is required. Install it with 'brew install go'." >&2
    exit 1
  fi
  mkdir -p build/tools Frameworks
  # Install the x/mobile tools pinned by core/go.mod locally, without changing the caller's PATH.
  export GOBIN="$PWD/build/tools"
  export PATH="$GOBIN:$PATH"
  (cd core && go install golang.org/x/mobile/cmd/gomobile golang.org/x/mobile/cmd/gobind)
  gomobile init

  # Same targets and compiler flags as build.sh; preserve the old framework if the build fails.
  CORE_TMP=$(mktemp -d "$PWD/Frameworks/.libxray.XXXXXX")
  trap 'rm -rf "$CORE_TMP"' EXIT
  (cd core && gomobile bind -target=ios/arm64,iossimulator/arm64,maccatalyst/arm64,maccatalyst/amd64 \
    -iosversion=15.0 -trimpath -ldflags="-s -w -buildid= -checklinkname=0" \
    -o "$CORE_TMP/Libxray.xcframework" ./libxray)
  rm -rf Frameworks/Libxray.xcframework
  mv "$CORE_TMP/Libxray.xcframework" Frameworks/Libxray.xcframework
fi
xcodegen generate
echo "Ready: open FurkVPN.xcodeproj, select FurkVPN and a destination, and press Run."
