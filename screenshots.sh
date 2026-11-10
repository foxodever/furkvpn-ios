#!/usr/bin/env bash
# Screenshots of the app in the iOS Simulator, to check the design without an iPhone: a demo build
# (DEMO flag, Demo.swift: sample servers and a pretend connection — the VPN itself can't run in the
# Simulator) on a small and a big iPhone, the foldable iPhone Duo (unfolded and folded), and an iPad.
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

# "label|device type|runtime|name": the newest of each kind of device, on the newest iOS runtime that has
# it (the Duo comes with a runtime of its own next to the one for the other devices).
xcrun simctl list -j devicetypes runtimes > build/simctl.json
python3 - build/simctl.json > build/devices.txt <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
version = lambda r: [int(x) for x in r["version"].split(".")]
runtimes = sorted((r for r in d["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")), key=version, reverse=True)
def pick(pattern):
    for runtime in runtimes:
        found = [t for t in runtime.get("supportedDeviceTypes") or d["devicetypes"] if re.search(pattern, t["name"])]
        if found:
            return found[-1], runtime
    return None, None
for label, pattern in [("se", r"^iPhone SE"), ("pro", r"^iPhone \d+ Pro$"), ("max", r"^iPhone \d+ Pro Max$"),
                       ("duo", r"^iPhone Duo"), ("ipad", r"^iPad Pro.*13")]:
    t, runtime = pick(pattern)
    if t:
        print(f"{label}|{t['identifier']}|{runtime['identifier']}|{t['name']} (iOS {runtime['version']})")
PY
cat build/devices.txt

# The Duo's hinge: there is no simctl command for it, so a small program run inside the simulator asks
# SpringBoard's display test service to move it, the way devicehubctl does
# (https://github.com/ChrisThoma/devicehubctl, MIT). 180° = unfolded (inner display), 0° = folded (outer).
HINGE=build/hinge
build_hinge() {
  [ -x "$HINGE" ] && return 0
  cat > build/hinge.m <<'OBJC'
#import <Foundation/Foundation.h>
#import <dlfcn.h>
typedef struct { long long w[8]; } Swap;  // SBFDisplayToolSwapSettings
@interface SBSDisplayToolServiceConnection : NSObject
- (void)swapDisplayWithSettings:(Swap)s completionHandler:(void (^)(NSError *))c;
- (void)unlockForTestingWithCompletion:(void (^)(void))c;
@end
int main(int argc, char **argv) { @autoreleasepool {
  dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
  void *foundation = dlopen("/System/Library/PrivateFrameworks/SpringBoardFoundation.framework/SpringBoardFoundation", RTLD_NOW);
  BOOL (*parse)(NSArray *, Swap *, NSError **) = dlsym(foundation, "SBFDisplayToolSwapSettingsFromArguments");
  Class connection = NSClassFromString(@"SBSDisplayToolServiceConnection");
  if (!parse || !connection || argc < 2) { fprintf(stderr, "No hinge test service in this runtime\n"); return 3; }
  NSArray *args = @[[NSString stringWithFormat:@"-position=%.6f", atof(argv[1]) / 180], @"-duration=1", @"-wait"];
  Swap s = {0};
  NSError *e = nil;
  if (!parse(args, &s, &e)) { fprintf(stderr, "%s\n", e.localizedDescription.UTF8String); return 2; }
  SBSDisplayToolServiceConnection *c = [connection new];
  __block NSError *result = nil;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  [c swapDisplayWithSettings:s completionHandler:^(NSError *error) { result = error; dispatch_semaphore_signal(done); }];
  if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC))) { fprintf(stderr, "SpringBoard didn't answer\n"); return 1; }
  if (result) { fprintf(stderr, "%s\n", result.localizedDescription.UTF8String); return 1; }
  // The service holds a test lock for a while after a move; let it go.
  dispatch_semaphore_t unlocked = dispatch_semaphore_create(0);
  [c unlockForTestingWithCompletion:^{ dispatch_semaphore_signal(unlocked); }];
  dispatch_semaphore_wait(unlocked, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
  return 0;
} }
OBJC
  cat > build/hinge.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.springboard.sbdisplay.service</key><true/></dict></plist>
PLIST
  xcrun --sdk iphonesimulator clang -fobjc-arc -arch arm64 -mios-simulator-version-min=27.1 -framework Foundation \
    -Wl,-sectcreate,__TEXT,__entitlements,build/hinge.plist build/hinge.m -o "$HINGE.tmp" &&
    codesign -s - -f "$HINGE.tmp" && mv "$HINGE.tmp" "$HINGE"
}
hinge() { build_hinge && xcrun simctl spawn "$1" "$PWD/$HINGE" "$2" < /dev/null && sleep 3; }

# One screenshot: device, file name, display ("" = the only one; the Duo: 1 outer, 3 inner), launch arguments.
shoot() {
  local udid=$1 name=$2 display=$3; shift 3
  xcrun simctl launch --terminate-running-process "$udid" com.furkvpn.app "$@" > /dev/null
  sleep 5
  xcrun simctl io "$udid" screenshot ${display:+--display=$display} "$OUT/$name.png" > /dev/null
}
# Every screen in both themes: device, file name prefix, display.
scenarios() {
  local udid=$1 prefix=$2 display=$3
  for theme in dark light; do
    xcrun simctl ui "$udid" appearance "$theme"
    shoot "$udid" "$prefix-$theme-1-welcome" "$display" -demo -demoWelcome
    shoot "$udid" "$prefix-$theme-2-home" "$display" -demo
    shoot "$udid" "$prefix-$theme-3-connected" "$display" -demo -demoConnected
    shoot "$udid" "$prefix-$theme-4-servers" "$display" -demo -demoConnected -demoServers
    shoot "$udid" "$prefix-$theme-5-settings" "$display" -demo -demoSettings
  done
}
while IFS='|' read -r label type runtime title; do
  udid=$(xcrun simctl create "shots-$label" "$type" "$runtime")
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b > /dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true
  xcrun simctl install "$udid" "$APP"
  if [ "$label" = duo ]; then
    if hinge "$udid" 180; then
      scenarios "$udid" duo-open 3
      hinge "$udid" 0 && scenarios "$udid" duo-folded 1
    else
      # Without the hinge: both displays as the simulator started (the one that is off comes out black).
      echo "The hinge didn't move: both displays as they are"
      scenarios "$udid" duo-inner 3
      scenarios "$udid" duo-outer 1
    fi
  else
    scenarios "$udid" "$label" ""
  fi
  xcrun simctl shutdown "$udid" || true
  xcrun simctl delete "$udid" || true
  echo "$title: done"
done < build/devices.txt
ls "$OUT"
