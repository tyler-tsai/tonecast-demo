#!/usr/bin/env bash
#
# bootstrap-app.sh — create the Tonecast App Store Connect record via
# the App Store Connect API. Idempotent: re-running won't error if the
# app already exists, it'll just print the existing record's details.
#
# Prereqs (set in ~/.zshrc — see docs/TESTFLIGHT_SETUP.md):
#   APP_STORE_KEY_ID, APP_STORE_KEY_ISSUER_ID, APP_STORE_KEY_PATH
#
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.example.tonecast"
NAME="Tonecast"
PRIMARY_LOCALE="en-US"
SKU="tonecast-001"

# ---- generate auth token --------------------------------------------
TOKEN=$(python3 scripts/asc_jwt.py) || {
  echo "❌ failed to generate JWT — check env vars" >&2
  exit 1
}

API="https://api.appstoreconnect.apple.com/v1"
HDR_AUTH="Authorization: Bearer $TOKEN"
HDR_JSON="Content-Type: application/json"

echo "▸ checking if app already exists with bundle id $BUNDLE_ID …"
EXISTS=$(curl -sS --http1.1 "$API/apps?filter%5BbundleId%5D=$BUNDLE_ID" -H "$HDR_AUTH")
APP_ID=$(printf '%s' "$EXISTS" | python3 -c '
import sys, json
data = json.load(sys.stdin)
items = data.get("data", [])
print(items[0]["id"] if items else "")
')

if [ -n "$APP_ID" ]; then
  EXISTING_NAME=$(printf '%s' "$EXISTS" | python3 -c '
import sys, json
print(json.load(sys.stdin)["data"][0]["attributes"]["name"])
')
  echo "✓ app already exists (id=$APP_ID name=\"$EXISTING_NAME\") — nothing to do"
  exit 0
fi

# ---- explain Apple's hard limit + bail with manual instructions -----
# App Store Connect API does NOT allow creating apps. The /v1/apps
# resource only supports GET_COLLECTION, GET_INSTANCE, and UPDATE.
# This is documented at:
#   https://developer.apple.com/documentation/appstoreconnectapi/app
# Apple keeps "first-time app record creation" web-UI-only on purpose.
#
# Everything ELSE (builds, testers, metadata, submission) is API-able.
# So this is a one-time 5-minute manual step, then automation resumes.
cat <<'INSTRUCTIONS'
⚠️  Apple's API doesn't allow creating app records — only UPDATE / READ.
   You must create the Tonecast record manually ONCE in the web UI:

   1. Open https://appstoreconnect.apple.com/apps
   2. Click the blue "＋" → "New App"
   3. Fill in:
        Platforms          ☑ iOS
        Name               Tonecast
        Primary Language   English (U.S.)
        Bundle ID          com.example.tonecast — XC com example tonecast
        SKU                tonecast-001
        User Access        Full Access
   4. Click "Create"

   Then re-run THIS script. It'll detect the app and confirm you're
   good to go.

   (After this one-time step, EVERY OTHER step in your shipping
   workflow — ./ship.sh, ./scripts/invite-tester.sh — is API-driven.)
INSTRUCTIONS
exit 1

# Dead code below — kept for reference. Don't uncomment; Apple will 403.
# App Store Connect API requires the Bundle ID's *internal* resource id
# (not the dotted string). Look it up from /v1/bundleIds first.
BID_ID=$(curl -sS --http1.1 "$API/bundleIds?filter%5Bidentifier%5D=$BUNDLE_ID" -H "$HDR_AUTH" \
  | python3 -c '
import sys, json
items = json.load(sys.stdin).get("data", [])
print(items[0]["id"] if items else "")
')

if [ -z "$BID_ID" ]; then
  echo "❌ Bundle ID $BUNDLE_ID not found in your developer account." >&2
  echo "   This should have been auto-created by ./run.sh. Verify in:" >&2
  echo "   https://developer.apple.com/account/resources/identifiers/list" >&2
  exit 1
fi
echo "  bundle-id resource id: $BID_ID"

PAYLOAD=$(BUNDLE_ID="$BUNDLE_ID" NAME="$NAME" PRIMARY_LOCALE="$PRIMARY_LOCALE" SKU="$SKU" BID_ID="$BID_ID" python3 -c '
import json, os
print(json.dumps({
  "data": {
    "type": "apps",
    "attributes": {
      "bundleId": os.environ["BUNDLE_ID"],
      "name": os.environ["NAME"],
      "primaryLocale": os.environ["PRIMARY_LOCALE"],
      "sku": os.environ["SKU"],
    },
    "relationships": {
      "bundleId": {
        "data": {"type": "bundleIds", "id": os.environ["BID_ID"]}
      }
    }
  }
}))
')

RESP=$(curl -sS --http1.1 -X POST "$API/apps" -H "$HDR_AUTH" -H "$HDR_JSON" -d "$PAYLOAD")

ERROR=$(printf '%s' "$RESP" | python3 -c '
import sys, json
data = json.load(sys.stdin)
errors = data.get("errors")
if errors:
    e = errors[0]
    print(f"{e.get(\"code\",\"?\")}: {e.get(\"title\",\"?\")}: {e.get(\"detail\",\"\")}")
' 2>/dev/null)

if [ -n "$ERROR" ]; then
  echo "❌ create app failed:" >&2
  echo "   $ERROR" >&2
  echo >&2
  echo "Full response:" >&2
  printf '%s\n' "$RESP" | python3 -m json.tool >&2 2>/dev/null || printf '%s\n' "$RESP" >&2
  exit 1
fi

NEW_ID=$(printf '%s' "$RESP" | python3 -c 'import sys, json; print(json.load(sys.stdin)["data"]["id"])')
echo "✅ created app record:"
echo "   id:        $NEW_ID"
echo "   bundle:    $BUNDLE_ID"
echo "   name:      $NAME"
echo
echo "Next step: ./ship.sh"
