#!/usr/bin/env bash
# Screenshots of the app in the iOS Simulator, to check the design without an iPhone: a demo build
# (DEMO flag, Demo.swift: sample servers and a pretend connection — the VPN itself can't run in the
# Simulator) on a small and a big iPhone, an iPad and a foldable iPhone if the Simulator has one.
# Needs the framework with its simulator slice (build.sh builds both). → build/shots/*.png
set -euo pipefail
cd "$(dirname "$0")"
OUT=build/shots
rm -rf "$OUT" && mkdir -p "$OUT"
xcodebuild -project FurkVPN.xcodeproj -scheme FurkVPN -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/sim \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEMO' build -quiet
APP=build/sim/Build/Products/Debug-iphonesimulator/FurkVPN.app

# "name|device type|runtime": the newest iOS runtime and the newest of each kind of device.
xcrun simctl list -j devicetypes runtimes > build/simctl.json
python3 - build/simctl.json > build/devices.txt <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
runtimes = [r for r in d["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
runtime = max(runtimes, key=lambda r: [int(x) for x in r["version"].split(".")])
supported = {t["identifier"] for t in runtime.get("supportedDeviceTypes", [])} or None
types = [t for t in d["devicetypes"] if supported is None or t["identifier"] in supported]
def newest(pattern):
    found = [t for t in types if re.search(pattern, t["name"])]
    return found[-1] if found else None
for label, pattern in [("se", r"^iPhone SE"), ("pro", r"^iPhone \d+ Pro$"), ("max", r"^iPhone \d+ Pro Max$"),
                       ("fold", r"Fold"), ("ipad", r"^iPad Pro.*13")]:
    t = newest(pattern)
    if t:
        print(f"{label}|{t['identifier']}|{runtime['identifier']}|{t['name']}")
PY
cat build/devices.txt

# Scenarios: file name and launch arguments.
shoot() {
  local udid=$1 name=$2; shift 2
  xcrun simctl launch --terminate-running-process "$udid" com.furkvpn.app "$@" > /dev/null
  sleep 5
  xcrun simctl io "$udid" screenshot "$OUT/$name.png" > /dev/null
}
while IFS='|' read -r label type runtime title; do
  udid=$(xcrun simctl create "shots-$label" "$type" "$runtime")
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b > /dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true
  xcrun simctl install "$udid" "$APP"
  for theme in dark light; do
    xcrun simctl ui "$udid" appearance "$theme"
    shoot "$udid" "$label-$theme-1-welcome" -demo -demoWelcome
    shoot "$udid" "$label-$theme-2-home" -demo
    shoot "$udid" "$label-$theme-3-connected" -demo -demoConnected
    shoot "$udid" "$label-$theme-4-servers" -demo -demoConnected -demoServers
    shoot "$udid" "$label-$theme-5-settings" -demo -demoSettings
  done
  xcrun simctl shutdown "$udid" || true
  xcrun simctl delete "$udid" || true
  echo "$title: done"
done < build/devices.txt
ls "$OUT"
