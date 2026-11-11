#!/usr/bin/env bash
# Builds the Mac app (Mac Catalyst: the iPad app with the Mac's window and menus, for Apple silicon and
# Intel) after build.sh, which makes the framework with its Mac slices and the Xcode project.
#   → build/FurkVPN-<version>-mac-unsigned.zip
# Ad-hoc signed WITHOUT the entitlements: a Mac refuses to start an app that claims the VPN and the App
# Group with no provisioning profile. So this one shows the interface only; the VPN needs the build
# signed by the developer account for the Mac App Store (the only way Apple allows a VPN app extension on
# a Mac, see TN3134), with FurkVPN-mac.entitlements / FurkTunnel-mac.entitlements.
set -euo pipefail
cd "$(dirname "$0")"
OUT=build
xcodebuild -project FurkVPN.xcodeproj -scheme FurkVPN -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' -derivedDataPath "$OUT/dd-mac" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
APP="$OUT/dd-mac/Build/Products/Release-maccatalyst/FurkVPN.app"
lipo -info "$APP/Contents/MacOS/FurkVPN"
codesign -f -s - "$APP/Contents/PlugIns/FurkTunnel.appex"
codesign -f -s - "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
rm -f "$OUT"/FurkVPN-*-mac-unsigned.zip
ditto -c -k --keepParent "$APP" "$OUT/FurkVPN-$VERSION-mac-unsigned.zip"
ls -la "$OUT"/FurkVPN-*-mac-unsigned.zip
