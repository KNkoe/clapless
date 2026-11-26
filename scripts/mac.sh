#!/bin/sh
# Build the Mac app, put it in ~/Applications and open it.
#   scripts/mac.sh              build, install, open
#   scripts/mac.sh --no-open
set -eu
cd "$(dirname "$0")/.."
[ -f Config/Local.xcconfig ] || ./scripts/setup.sh
mkdir -p build
if ! xcodebuild -project Clapless.xcodeproj -scheme ClaplessMac -configuration Release \
    -destination "platform=macOS,arch=arm64" -derivedDataPath build/mac \
    -allowProvisioningUpdates build > build/mac-build.log 2>&1; then
  grep -E 'error' build/mac-build.log | sort -u | head -30 >&2
  echo "Build failed. Full log: build/mac-build.log" >&2
  exit 1
fi
app="$HOME/Applications/Clapless.app"
# Ask a running copy to quit properly, so a take in progress is saved first.
if pgrep -f "$app/Contents/MacOS/Clapless" >/dev/null; then
  if "$(dirname "$0")/clapless" status 2>/dev/null | grep -qE '"phase": "(starting|recording|stopping)"'; then
    echo "A take is running. Stop it before reinstalling." >&2
    exit 1
  fi
  pkill -TERM -f "$app/Contents/MacOS/Clapless" || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$app/Contents/MacOS/Clapless" >/dev/null || break; sleep 0.3; done
fi
mkdir -p "$HOME/Applications"
rm -rf "$app"
ditto build/mac/Build/Products/Release/Clapless.app "$app"
echo "Installed $app"
[ "${1:-}" = "--no-open" ] || open "$app"
