#!/usr/bin/env bash
# Builds the iOS app on macOS (Xcode, Go, gomobile and XcodeGen installed):
#   Xray-core → Frameworks/Libxray.xcframework (gomobile), FurkVPN.xcodeproj (XcodeGen), the app,
#   then build/FurkVPN-<version>-unsigned.ipa: ad-hoc signed with the entitlements, for re-signing
#   with a developer certificate (or TrollStore). Set REBUILD_CORE=1 to rebuild the framework.
set -euo pipefail
cd "$(dirname "$0")"
OUT=build
if [ ! -d Frameworks/Libxray.xcframework ] || [ "${REBUILD_CORE:-0}" = 1 ]; then
  rm -rf Frameworks/Libxray.xcframework
  (cd core && gomobile bind -target=ios/arm64 -iosversion=15.0 -trimpath \
    -ldflags="-s -w -buildid= -checklinkname=0" -o ../Frameworks/Libxray.xcframework ./libxray)
fi
xcodegen generate
xcodebuild -project FurkVPN.xcodeproj -scheme FurkVPN -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$OUT/dd" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
APP="$OUT/dd/Build/Products/Release-iphoneos/FurkVPN.app"
rm -rf "$OUT/Payload" && mkdir -p "$OUT/Payload" && cp -R "$APP" "$OUT/Payload/"
codesign -f -s - --entitlements FurkTunnel/FurkTunnel.entitlements "$OUT/Payload/FurkVPN.app/PlugIns/FurkTunnel.appex"
codesign -f -s - --entitlements FurkVPN/FurkVPN.entitlements "$OUT/Payload/FurkVPN.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$OUT/Payload/FurkVPN.app/Info.plist")
(cd "$OUT" && rm -f FurkVPN-*.ipa && zip -qry "FurkVPN-$VERSION-unsigned.ipa" Payload)
ls -la "$OUT"/FurkVPN-*.ipa
