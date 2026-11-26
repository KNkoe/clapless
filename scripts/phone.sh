#!/bin/sh
# Build Clapless for your iPhone, install it and open it. Run again whenever the free signature expires (7 days).
#   scripts/phone.sh            cable or Wi-Fi, whichever the Mac can reach
#   scripts/phone.sh --no-launch
set -eu
cd "$(dirname "$0")/.."
[ -f Config/Local.xcconfig ] || ./scripts/setup.sh

list=$(mktemp)
trap 'rm -f "$list"' EXIT
xcrun devicectl list devices --json-output "$list" >/dev/null
# A paired iPhone with Developer Mode on that is connected now; the cable wins over Wi-Fi.
device=$(python3 -I - "$list" <<'PY'
import json, sys
found = []
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    h, c = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if h.get("deviceType") != "iPhone" or c.get("pairingState") != "paired" or not c.get("transportType"):
        continue
    found.append((c["transportType"] != "wired", h["udid"], c["transportType"]))
if found:
    _, udid, how = sorted(found)[0]
    print(udid, how)
PY
)
[ -n "$device" ] || { echo "No iPhone reachable. Unlock it, and plug it in or join the same Wi-Fi." >&2; exit 1; }
udid=${device% *}
echo "iPhone reached over: ${device#* }"

mkdir -p build
if ! xcodebuild -project Clapless.xcodeproj -scheme ClaplessPhone -configuration Release \
    -destination "platform=iOS,id=$udid" -derivedDataPath build/ios \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > build/phone-build.log 2>&1; then
  grep -E '(error|warning: .*provision)' build/phone-build.log | sort -u | head -30 >&2
  echo "Build failed. Full log: build/phone-build.log" >&2
  exit 1
fi
app=build/ios/Build/Products/Release-iphoneos/Clapless.app
xcrun devicectl device install app --device "$udid" "$app" > build/phone-install.log 2>&1 || { tail -20 build/phone-install.log >&2; exit 1; }
echo "Installed."
profile="$app/embedded.mobileprovision"
[ -f "$profile" ] && echo "Signature expires: $(security cms -D -i "$profile" 2>/dev/null | plutil -extract ExpirationDate raw -o - -)"
[ "${1:-}" = "--no-launch" ] && exit 0
bundle=$(plutil -extract CFBundleIdentifier raw -o - "$app/Info.plist")
xcrun devicectl device process launch --device "$udid" "$bundle" > build/phone-launch.log 2>&1 \
  && echo "Opened on the iPhone." || { grep -iE 'error|reason|trust|locked|untrusted' build/phone-launch.log | head -8 >&2; exit 2; }
