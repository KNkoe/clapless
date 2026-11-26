#!/bin/sh
# Writes Config/Local.xcconfig from the Apple Development certificate on this Mac. Run once.
set -eu
cd "$(dirname "$0")/.."
team=$(security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject | sed -E 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/')
case "$team" in
  ??????????) ;;
  *) echo "No Apple Development certificate found. Sign in to Xcode > Settings > Accounts first." >&2; exit 1 ;;
esac
suffix=$(printf '%s' "$team" | shasum -a 256 | cut -c1-8)
printf 'DEVELOPMENT_TEAM = %s\nCLAPLESS_BUNDLE_PREFIX = app.clapless.%s\n' "$team" "$suffix" > Config/Local.xcconfig
echo "Wrote Config/Local.xcconfig"
