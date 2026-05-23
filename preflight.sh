#!/usr/bin/env bash
#
# preflight.sh — verify Tonecast is ready to archive for App Store / TestFlight.
# Catches things Apple's processing pipeline would reject AFTER you wait for
# the upload to finish. Run automatically from ship.sh.
#
# Each check prints a single line. Failures append to a tally and exit non-zero
# at the end so the operator can see ALL issues at once, not just the first.
#
set -uo pipefail
cd "$(dirname "$0")"

FAIL=0
PASS=0
WARN=0

fail() { printf "  ❌ %s\n" "$1"; FAIL=$((FAIL+1)); }
pass() { printf "  ✅ %s\n" "$1"; PASS=$((PASS+1)); }
warn() { printf "  ⚠️  %s\n" "$1"; WARN=$((WARN+1)); }

# Helper: read a key from a plist using PlistBuddy.
plist_val() {
  local file="$1" key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$file" 2>/dev/null
}

# ---------- 1. project.yml sanity ----------
echo "■ project.yml"
if [ ! -f project.yml ]; then fail "project.yml missing"; exit 1; fi
TEAM=$(grep "DEVELOPMENT_TEAM:" project.yml | head -1 | awk '{print $2}')
if [ -z "$TEAM" ]; then fail "DEVELOPMENT_TEAM not set"; else pass "team id $TEAM"; fi

BUNDLE_ID=$(grep "PRODUCT_BUNDLE_IDENTIFIER:" project.yml | head -1 | awk '{print $2}')
if [ "$BUNDLE_ID" != "com.example.tonecast" ]; then
  fail "main bundle id is '$BUNDLE_ID', expected com.example.tonecast"
else
  pass "bundle id $BUNDLE_ID"
fi

MARKETING=$(grep "MARKETING_VERSION:" project.yml | head -1 | awk '{print $2}' | tr -d '"')
BUILD_NUM=$(grep "CURRENT_PROJECT_VERSION:" project.yml | head -1 | awk '{print $2}' | tr -d '"')
pass "version $MARKETING ($BUILD_NUM)"

# ---------- 2. App Info.plist ----------
echo "■ Tonecast/Info.plist"
APP_PLIST=Tonecast/Info.plist
if [ ! -f "$APP_PLIST" ]; then fail "missing $APP_PLIST"; exit 1; fi

# Required usage descriptions
MIC_DESC=$(plist_val "$APP_PLIST" NSMicrophoneUsageDescription)
if [ -z "$MIC_DESC" ]; then
  fail "NSMicrophoneUsageDescription missing — Apple will reject for any mic API use"
else
  pass "NSMicrophoneUsageDescription set"
fi

# Export compliance — saves the export-compliance dance at every TF upload
ENC=$(plist_val "$APP_PLIST" ITSAppUsesNonExemptEncryption)
if [ -z "$ENC" ]; then
  warn "ITSAppUsesNonExemptEncryption not set — App Store Connect will prompt at every upload"
else
  pass "ITSAppUsesNonExemptEncryption = $ENC"
fi

# Background mode (for Flow Session)
if plist_val "$APP_PLIST" "UIBackgroundModes:0" | grep -q audio; then
  pass "UIBackgroundModes includes audio (Flow Session)"
else
  warn "UIBackgroundModes missing audio — Flow Session won't survive background"
fi

# Custom URL scheme for tonecast:// (keyboard → main app handoff)
if plist_val "$APP_PLIST" "CFBundleURLTypes:0:CFBundleURLSchemes:0" | grep -q tonecast; then
  pass "tonecast:// URL scheme registered"
else
  fail "tonecast:// URL scheme missing — keyboard can't launch main app"
fi

# Launch screen (Apple rejects builds without one)
if plist_val "$APP_PLIST" UILaunchScreen >/dev/null 2>&1; then
  pass "UILaunchScreen present"
else
  fail "UILaunchScreen missing — Apple rejects"
fi

# ---------- 3. Keyboard extension Info.plist ----------
echo "■ TonecastKeyboard/Info.plist"
KBD_PLIST=TonecastKeyboard/Info.plist
NSEXT=$(plist_val "$KBD_PLIST" "NSExtension:NSExtensionPointIdentifier")
if [ "$NSEXT" != "com.apple.keyboard-service" ]; then
  fail "keyboard extension point id wrong: '$NSEXT'"
else
  pass "NSExtensionPointIdentifier correct"
fi

OPEN_ACCESS=$(plist_val "$KBD_PLIST" "NSExtension:NSExtensionAttributes:RequestsOpenAccess")
if [ "$OPEN_ACCESS" = "true" ]; then
  pass "RequestsOpenAccess = true (needed for network access)"
else
  warn "RequestsOpenAccess not true — keyboard can't reach network"
fi

# ---------- 4. Entitlements (App Group must match across targets) ----------
echo "■ entitlements"
APP_ENT=Tonecast/Tonecast.entitlements
KBD_ENT=TonecastKeyboard/TonecastKeyboard.entitlements
APP_GROUP=$(plist_val "$APP_ENT" "com.apple.security.application-groups:0")
KBD_GROUP=$(plist_val "$KBD_ENT" "com.apple.security.application-groups:0")
if [ "$APP_GROUP" != "$KBD_GROUP" ]; then
  fail "app group mismatch: app=$APP_GROUP keyboard=$KBD_GROUP"
elif [ -z "$APP_GROUP" ]; then
  fail "app group not set in either entitlements file"
else
  pass "app group $APP_GROUP matches across both targets"
fi

# ---------- 5. App icon present ----------
echo "■ App icon"
ICON=Tonecast/Assets.xcassets/AppIcon.appiconset/icon-1024.png
if [ -f "$ICON" ]; then
  SIZE=$(file "$ICON" | grep -oE "[0-9]+ x [0-9]+" | head -1)
  if [ "$SIZE" = "1024 x 1024" ]; then
    pass "1024x1024 marketing icon present"
  else
    fail "icon is $SIZE — Apple requires 1024x1024"
  fi
else
  fail "no $ICON — Apple rejects builds without a marketing icon"
fi

# ---------- 6. Secrets — must not bundle OpenAI key ----------
echo "■ secrets hygiene"
KEY_IN_SOURCE=$(grep "openAIKey" TonecastKeyboard/Secrets.swift | grep -v "^//" | grep -oE "sk-[a-zA-Z0-9_-]{20,}" || true)
if [ -n "$KEY_IN_SOURCE" ]; then
  fail "OpenAI key STILL in TonecastKeyboard/Secrets.swift — REVOKE + clear before TF"
else
  pass "no OpenAI key in source"
fi

# Quick binary scan (only if .build dir already exists from a prior build)
LAST_APP=$(find .build/Build/Products/Debug-iphoneos -name "Tonecast.app" -type d 2>/dev/null | head -1)
if [ -n "$LAST_APP" ]; then
  if strings "$LAST_APP/Tonecast" 2>/dev/null | grep -qE "^sk-[a-zA-Z0-9_-]{20,}$"; then
    fail "OpenAI key found in cached Tonecast binary — wipe .build/ and rebuild"
  else
    pass "no OpenAI key in last-built Tonecast binary"
  fi
fi

# ---------- 7. ExportOptions present ----------
echo "■ export config"
if [ ! -f ExportOptions.plist ]; then
  fail "ExportOptions.plist missing — required for ship.sh"
else
  METHOD=$(plist_val ExportOptions.plist method)
  if [ "$METHOD" = "app-store" ] || [ "$METHOD" = "app-store-connect" ]; then
    pass "ExportOptions method = $METHOD"
  else
    fail "ExportOptions method = '$METHOD', expected app-store or app-store-connect"
  fi
fi

# ---------- summary ----------
echo
echo "  ── preflight: $PASS passed · $WARN warnings · $FAIL failed ──"

if [ "$FAIL" -gt 0 ]; then
  echo
  echo "  ❌ Fix the $FAIL issue(s) above before shipping."
  exit 1
fi
echo "  ✅ Ready to ship."
exit 0
