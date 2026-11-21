#!/usr/bin/env bash
# UI tests in the iOS Simulator on the demo build (DEMO flag): taps on the main screen's cards.
set -uo pipefail
cd "$(dirname "$0")"
xcrun simctl list -j devicetypes runtimes > build-simctl.json
read -r TYPE RUNTIME NAME < <(python3 - build-simctl.json <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
version = lambda r: [int(x) for x in r["version"].split(".")]
runtimes = sorted((r for r in d["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")), key=version, reverse=True)
for runtime in runtimes:
    found = [t for t in runtime.get("supportedDeviceTypes") or d["devicetypes"] if re.search(r"^iPhone \d+ Pro$", t["name"])]
    if found:
        number = lambda t: int((re.findall(r"\d+", t["name"]) or ["0"])[0])
        t = max(found, key=lambda t: (t.get("minRuntimeVersion", 0), number(t)))
        print(t["identifier"], runtime["identifier"], t["name"].replace(" ", "_") + "_iOS_" + runtime["version"])
        break
PY
)
echo "Device: $NAME"
UDID=$(xcrun simctl create uitest "$TYPE" "$RUNTIME")
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b > /dev/null
xcodebuild test -project FurkVPN.xcodeproj -scheme FurkUITests -configuration Debug \
  -sdk iphonesimulator -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build/uitest \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEMO' 2>&1 | grep -v "^\s*$" | tail -n 600
xcrun simctl shutdown "$UDID" || true
xcrun simctl delete "$UDID" || true
