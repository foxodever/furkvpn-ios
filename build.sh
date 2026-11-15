#!/usr/bin/env bash
# Builds the iOS app on macOS (Xcode, Go, gomobile and XcodeGen installed):
#   Xray-core → Frameworks/Libxray.xcframework (gomobile), FurkVPN.xcodeproj (XcodeGen), the app,
#   then build/FurkVPN-<version>-unsigned.ipa: ad-hoc signed with the entitlements, for re-signing
#   with a developer certificate (or TrollStore). Set REBUILD_CORE=1 to rebuild the framework (it has
#   a simulator slice too, for screenshots.sh, and the Mac Catalyst ones for build-mac.sh).
set -euo pipefail
cd "$(dirname "$0")"
OUT=build
if [ ! -d Frameworks/Libxray.xcframework ] || [ "${REBUILD_CORE:-0}" = 1 ]; then
  rm -rf Frameworks/Libxray.xcframework
  (cd core && gomobile bind -target=ios/arm64,iossimulator/arm64,maccatalyst/arm64,maccatalyst/amd64 -iosversion=15.0 -trimpath \
    -ldflags="-s -w -buildid= -checklinkname=0" -o ../Frameworks/Libxray.xcframework ./libxray)
fi
xcodegen generate
xcodebuild -project FurkVPN.xcodeproj -scheme FurkVPN -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$OUT/dd" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
APP="$OUT/dd/Build/Products/Release-iphoneos/FurkVPN.app"
rm -rf "$OUT/Payload" && mkdir -p "$OUT/Payload" && cp -R "$APP" "$OUT/Payload/"
# Without the keychain groups of Furry LLC's team (the widgets' state): a build signed by someone else can't
# have them, and with them the device id could move to another keychain group. The widgets then only say to
# open the app.
adhoc() {
  cp "$1" "$OUT/adhoc.entitlements"
  /usr/libexec/PlistBuddy -c 'Delete :keychain-access-groups' "$OUT/adhoc.entitlements" 2>/dev/null || true
  echo "$OUT/adhoc.entitlements"
}
codesign -f -s - --entitlements "$(adhoc FurkTunnel/FurkTunnel.entitlements)" "$OUT/Payload/FurkVPN.app/PlugIns/FurkTunnel.appex"
# The widgets and the Control Center button.
codesign -f -s - "$OUT/Payload/FurkVPN.app/PlugIns/FurkWidget.appex"
codesign -f -s - --entitlements "$(adhoc FurkVPN/FurkVPN.entitlements)" "$OUT/Payload/FurkVPN.app"
rm -f "$OUT/adhoc.entitlements"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$OUT/Payload/FurkVPN.app/Info.plist")
(cd "$OUT" && rm -f FurkVPN-*.ipa && zip -qry "FurkVPN-$VERSION-unsigned.ipa" Payload)
ls -la "$OUT"/FurkVPN-*.ipa
