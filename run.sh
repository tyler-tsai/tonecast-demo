#!/usr/bin/env bash
# Build, install, and launch Tonecast on the connected iPhone — equivalent
# to ⌘R in Xcode but runnable from CLI.
#
# Set TONECAST_UDID to your iPhone UDID:
#   xcrun devicectl list devices
#   export TONECAST_UDID="00008XXX-XXXXXXXXXXXXXXXX"
set -euo pipefail

UDID="${TONECAST_UDID:?Set TONECAST_UDID to your iPhone UDID (xcrun devicectl list devices)}"
BUNDLE_ID="com.example.tonecast"
DERIVED="./.build"

cd "$(dirname "$0")"

echo "▸ regenerate Xcode project (if project.yml changed)"
xcodegen generate --quiet

echo "▸ build Tonecast for device $UDID"
xcodebuild \
  -project Tonecast.xcodeproj \
  -scheme Tonecast \
  -configuration Debug \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  build \
  | grep -E '^(error:|warning:|\*\* BUILD)' || true

APP_PATH="$DERIVED/Build/Products/Debug-iphoneos/Tonecast.app"
if [ ! -d "$APP_PATH" ]; then
  echo "❌ Build did not produce $APP_PATH"
  exit 1
fi

echo "▸ install to device"
xcrun devicectl device install app --device "$UDID" "$APP_PATH" 2>&1 \
  | tail -5

echo "▸ launch $BUNDLE_ID"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" 2>&1 \
  | tail -3

echo "✅ done — keyboard extension is updated; switch to Tonecast on iPhone to use it"
