#!/usr/bin/env bash
#
# ship.sh — archive Tonecast in Release config, export an .ipa, and upload
# it to App Store Connect (which routes to TestFlight Internal Testing).
#
# Usage:
#   ./ship.sh                    # auto-bump build number, archive, export, upload
#   ./ship.sh --no-upload        # archive + export only (smoke-test the build)
#   ./ship.sh --keep-build-num   # don't bump; useful for re-uploads after a tweak
#
# Prereqs (one-time, see docs/TESTFLIGHT_SETUP.md):
#   1. App record exists in App Store Connect for com.example.tonecast
#   2. App Store Connect API key created at appstoreconnect.apple.com/access/api
#      → environment vars APP_STORE_KEY_ID, APP_STORE_KEY_ISSUER_ID,
#        APP_STORE_KEY_PATH (.p8 file) populated (e.g. via direnv / .envrc)
#   3. Distribution certificate + provisioning profile downloaded to Keychain
#      (Xcode will auto-resolve with `signingStyle = automatic`)
#
set -euo pipefail

# ---------- args ----------
UPLOAD=true
BUMP=true
for arg in "$@"; do
  case "$arg" in
    --no-upload) UPLOAD=false ;;
    --keep-build-num) BUMP=false ;;
    *) echo "unknown arg: $arg" && exit 1 ;;
  esac
done

cd "$(dirname "$0")"

PROJECT=Tonecast.xcodeproj
SCHEME=Tonecast
ARCHIVE_PATH=./.build/Tonecast.xcarchive
EXPORT_PATH=./.build/export
IPA_PATH="$EXPORT_PATH/$SCHEME.ipa"
EXPORT_OPTS=./ExportOptions.plist

# ---------- preflight (catches things Apple would reject) ----------
echo "▸ preflight checks"
./preflight.sh

# ---------- bump build number ----------
if $BUMP; then
  CURRENT=$(grep "CURRENT_PROJECT_VERSION" project.yml | head -1 | awk '{print $2}' | tr -d '"')
  NEXT=$((CURRENT + 1))
  sed -i '' "s/CURRENT_PROJECT_VERSION: \"$CURRENT\"/CURRENT_PROJECT_VERSION: \"$NEXT\"/" project.yml
  echo "▸ build number $CURRENT → $NEXT"
else
  echo "▸ keeping current build number"
fi

# ---------- regenerate Xcode project ----------
echo "▸ regenerate Xcode project"
xcodegen generate --quiet

# ---------- archive (Release config) ----------
rm -rf .build/Tonecast.xcarchive .build/export
echo "▸ archive (Release)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  | xcbeautify 2>/dev/null || \
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  | grep -E "^(error:|warning:|\*\* ARCHIVE)" || true

if [ ! -d "$ARCHIVE_PATH" ]; then
  echo "❌ archive failed — no .xcarchive at $ARCHIVE_PATH"
  exit 1
fi

# ---------- export IPA ----------
echo "▸ export IPA via $EXPORT_OPTS"
# When --no-upload, force a local export instead of uploading from xcodebuild
if $UPLOAD; then
  EXPORT_OPTS_FOR_RUN="$EXPORT_OPTS"
else
  EXPORT_OPTS_FOR_RUN=./.build/ExportOptions.no-upload.plist
  /usr/libexec/PlistBuddy -c "Copy :destination ./.build/destination" "$EXPORT_OPTS" 2>/dev/null || true
  cp "$EXPORT_OPTS" "$EXPORT_OPTS_FOR_RUN"
  /usr/libexec/PlistBuddy -c "Set :destination export" "$EXPORT_OPTS_FOR_RUN" || true
fi

# xcodebuild's -exportArchive needs ASC API credentials passed explicitly
# (env vars are NOT picked up). Without these the upload fails with
# "exportArchive Failed to Use Accounts".
AUTH_FLAGS=()
if [ -n "${APP_STORE_KEY_PATH:-}" ] && [ -n "${APP_STORE_KEY_ID:-}" ] && [ -n "${APP_STORE_KEY_ISSUER_ID:-}" ]; then
  AUTH_FLAGS=(
    -authenticationKeyPath "$APP_STORE_KEY_PATH"
    -authenticationKeyID "$APP_STORE_KEY_ID"
    -authenticationKeyIssuerID "$APP_STORE_KEY_ISSUER_ID"
  )
fi

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTS_FOR_RUN" \
  -exportPath "$EXPORT_PATH" \
  -allowProvisioningUpdates \
  "${AUTH_FLAGS[@]}" \
  | grep -E "^(error:|warning:|\*\* EXPORT)" || true

# When destination=upload, xcodebuild's -exportArchive handles the upload
# inline — there is no .ipa on disk afterward. We detect by inspecting the
# export dir.
if $UPLOAD; then
  if [ -d "$EXPORT_PATH" ] && [ -z "$(ls "$EXPORT_PATH" 2>/dev/null)" ]; then
    echo "✅ uploaded to App Store Connect — check TestFlight tab"
    echo "   processing usually takes 5-30 min, you'll get an email when ready"
  else
    echo "⚠️  unexpected: export dir is non-empty after upload destination"
    ls -la "$EXPORT_PATH"
  fi
else
  if [ -f "$IPA_PATH" ]; then
    SIZE=$(du -h "$IPA_PATH" | awk '{print $1}')
    echo "✅ exported $IPA_PATH ($SIZE) — upload skipped (--no-upload)"
  else
    echo "❌ export failed — no .ipa at $IPA_PATH"
    exit 1
  fi
fi
