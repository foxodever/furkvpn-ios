#!/usr/bin/env bash
# Builds the App Store version after build.sh (framework and Xcode project ready), signed by Furry LLC
# (team 2N5KR68546), and uploads it to App Store Connect: after Apple's processing it is in TestFlight.
#   → build/appstore/FurkVPN.ipa (the uploaded one)
# Needs, from the CI secrets:
#   IOS_P12_BASE64, IOS_P12_PASSWORD  the Apple Distribution certificate with its key (.p12, base64)
#   ASC_KEY_P8                        the App Store Connect API key (.p8, base64), role App Manager
# The API key also fetches the App Store provisioning profiles, so they are never stored anywhere.
# The build number must be new for every upload: CURRENT_PROJECT_VERSION in project.yml.
set -euo pipefail
cd "$(dirname "$0")"
OUT=build/appstore
TEAM=2N5KR68546
ASC_KEY_ID=${ASC_KEY_ID:-THDL4U93NN}
ASC_ISSUER_ID=${ASC_ISSUER_ID:-dcd4f8a1-f78d-47ca-91bf-b32e0e912659}
# Profile names in the developer account, by bundle id.
APP_PROFILE="FurkVPN AppStore Distribution"
TUNNEL_PROFILE="FurkTunnel AppStore Distribution"
TMP=${RUNNER_TEMP:-$(mktemp -d)}
rm -rf "$OUT" && mkdir -p "$OUT"

# The API key, and the certificate in a keychain of its own.
KEY="$TMP/AuthKey_$ASC_KEY_ID.p8"
echo "$ASC_KEY_P8" | base64 --decode > "$KEY"
echo "$IOS_P12_BASE64" | base64 --decode > "$TMP/dist.p12"
KC="$TMP/signing.keychain-db"
KC_PASS=$(uuidgen)
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KC_PASS" "$KC"
security set-keychain-settings -lut 3600 "$KC"
security unlock-keychain -p "$KC_PASS" "$KC"
security import "$TMP/dist.p12" -k "$KC" -P "$IOS_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KC" >/dev/null
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
security find-identity -v -p codesigning "$KC"

# The profiles, straight from the App Store Connect API.
python3 -m venv "$TMP/venv"
"$TMP/venv/bin/pip" install -q pyjwt cryptography
"$TMP/venv/bin/python" - "$KEY" "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$APP_PROFILE" "$TUNNEL_PROFILE" <<'EOF'
import base64, json, os, sys, time, urllib.parse, urllib.request
import jwt
key_path, key_id, issuer, *names = sys.argv[1:]
now = int(time.time())
token = jwt.encode({"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
                   open(key_path).read(), algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})
dirs = [os.path.expanduser(d) for d in ("~/Library/MobileDevice/Provisioning Profiles",
                                        "~/Library/Developer/Xcode/UserData/Provisioning Profiles")]
for d in dirs:
    os.makedirs(d, exist_ok=True)
for name in names:
    query = urllib.parse.urlencode({"filter[name]": name, "filter[profileState]": "ACTIVE",
                                    "fields[profiles]": "name,uuid,profileContent,expirationDate"})
    req = urllib.request.Request("https://api.appstoreconnect.apple.com/v1/profiles?" + query,
                                 headers={"Authorization": "Bearer " + token})
    found = [p["attributes"] for p in json.load(urllib.request.urlopen(req))["data"] if p["attributes"]["name"] == name]
    if not found:
        sys.exit(f"No active profile named {name!r}")
    profile = found[0]
    for d in dirs:
        with open(os.path.join(d, profile["uuid"] + ".mobileprovision"), "wb") as f:
            f.write(base64.b64decode(profile["profileContent"]))
    print("profile", name, profile["uuid"], "until", profile["expirationDate"])
EOF

# Each target signs with its own profile: the setting is resolved per target from its name.
xcodebuild -project FurkVPN.xcodeproj -scheme FurkVPN -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/dd-appstore \
  -archivePath "$OUT/FurkVPN.xcarchive" \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=$TEAM CODE_SIGN_IDENTITY="Apple Distribution" \
  'PROVISIONING_PROFILE_SPECIFIER=$(FURK_PROFILE_$(TARGET_NAME))' \
  "FURK_PROFILE_FurkVPN=$APP_PROFILE" "FURK_PROFILE_FurkTunnel=$TUNNEL_PROFILE" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KC" archive

options() {
  cat > "$OUT/$1.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$1</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>Apple Distribution</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>com.furkvpn.app</key><string>$APP_PROFILE</string>
		<key>com.furkvpn.app.tunnel</key><string>$TUNNEL_PROFILE</string>
	</dict>
	<key>uploadSymbols</key><true/>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>testFlightInternalTestingOnly</key><false/>
</dict>
</plist>
EOF
}
AUTH=(-authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
# First the IPA itself (kept with the build results), then the same export straight to App Store Connect.
options export
xcodebuild -exportArchive -archivePath "$OUT/FurkVPN.xcarchive" -exportOptionsPlist "$OUT/export.plist" \
  -exportPath "$OUT" "${AUTH[@]}"
(cd "$OUT" && rm -rf check && mkdir check && cd check && unzip -q ../FurkVPN.ipa \
  && codesign -d --entitlements - Payload/FurkVPN.app && codesign -d --entitlements - Payload/FurkVPN.app/PlugIns/FurkTunnel.appex \
  && ls Payload/FurkVPN.app/PrivacyInfo.xcprivacy Payload/FurkVPN.app/PlugIns/FurkTunnel.appex/PrivacyInfo.xcprivacy) 2>&1 | tail -60
options upload
xcodebuild -exportArchive -archivePath "$OUT/FurkVPN.xcarchive" -exportOptionsPlist "$OUT/upload.plist" \
  -exportPath "$OUT/upload" "${AUTH[@]}"

security delete-keychain "$KC" || true
rm -f "$KEY" "$TMP/dist.p12"
ls -la "$OUT"
