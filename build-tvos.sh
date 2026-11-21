#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
root="$PWD"
tools="$root/build/tvos-tools"
frameworks="$root/Frameworks/tvOS"
fork=github.com/netbirdio/gomobile-tvos-fork
version=v0.0.0-20260129172842-a56582c0e7c9

mkdir -p "$tools" "$frameworks"
GOBIN="$tools" go install "$fork/cmd/gomobile-netbird@$version" "$fork/cmd/gobind-netbird@$version"

scratch=$(mktemp -d "$root/build/tvos-core.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
# The fork's binding dependency belongs only to the tvOS build.
cp -R core "$scratch/core"
(
  cd "$scratch/core"
  go mod edit -require="$fork@$version"
  PATH="$tools:$PATH" GOFLAGS=-mod=mod gomobile-netbird bind \
    -target=tvos/arm64 -tvosversion=17.0 -trimpath \
    -ldflags='-s -w -buildid= -checklinkname=0' \
    -o "$scratch/Libxray.xcframework" ./libxray
)
rm -rf "$frameworks/Libxray.xcframework"
mv "$scratch/Libxray.xcframework" "$frameworks/"

xcodegen generate --spec project-tvos.yml
xcodebuild -project FurkVPN-TV.xcodeproj -scheme FurkVPN-TV -configuration Debug \
  -destination "${TVOS_DESTINATION:-generic/platform=tvOS}" -derivedDataPath build/dd-tvos "$@" build
