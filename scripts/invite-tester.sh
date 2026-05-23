#!/usr/bin/env bash
#
# invite-tester.sh — add an email to Tonecast's Internal Testing group.
#
# Usage:
#   ./scripts/invite-tester.sh someone@example.com
#   ./scripts/invite-tester.sh someone@example.com FirstName LastName
#
# Idempotent: re-running with the same email won't create a duplicate.
#
# Creates an Internal Testing group named "Friends" on first run; reuses
# it on subsequent runs.
#
set -euo pipefail
cd "$(dirname "$0")/.."

EMAIL="${1:-}"
FIRST="${2:-}"
LAST="${3:-}"

if [ -z "$EMAIL" ]; then
  echo "usage: $0 <email> [first_name] [last_name]" >&2
  exit 1
fi

BUNDLE_ID="com.example.tonecast"
GROUP_NAME="Friends"

TOKEN=$(python3 scripts/asc_jwt.py)
API="https://api.appstoreconnect.apple.com/v1"
HDR_AUTH="Authorization: Bearer $TOKEN"
HDR_JSON="Content-Type: application/json"

# ---- locate app id -------------------------------------------------
APP_ID=$(curl -sS --http1.1 "$API/apps?filter%5BbundleId%5D=$BUNDLE_ID" -H "$HDR_AUTH" \
  | python3 -c 'import sys, json
items = json.load(sys.stdin).get("data", [])
print(items[0]["id"] if items else "")
')

if [ -z "$APP_ID" ]; then
  echo "❌ app not found — run ./scripts/bootstrap-app.sh first" >&2
  exit 1
fi

# ---- find or create the Internal Testing group ---------------------
GROUP_ID=$(curl -sS --http1.1 "$API/apps/$APP_ID/betaGroups" -H "$HDR_AUTH" \
  | GROUP_NAME="$GROUP_NAME" python3 -c '
import sys, json, os
data = json.load(sys.stdin).get("data", [])
target = os.environ["GROUP_NAME"]
# Match by name regardless of internal/external status. Apple does NOT
# allow creating internal groups via API (they only contain team members),
# so any group we create here is external by definition. For
# gmail/non-team testers that is correct — they must go through external
# testing anyway.
for g in data:
    if g["attributes"]["name"] == target:
        print(g["id"])
        break
')

if [ -z "$GROUP_ID" ]; then
  echo "▸ creating Internal Testing group \"$GROUP_NAME\""
  PAYLOAD=$(GROUP_NAME="$GROUP_NAME" APP_ID="$APP_ID" python3 -c '
import json, os
print(json.dumps({
  "data": {
    "type": "betaGroups",
    "attributes": {
      "name": os.environ["GROUP_NAME"],
      "publicLinkEnabled": False,
    },
    "relationships": {
      "app": {"data": {"type": "apps", "id": os.environ["APP_ID"]}}
    }
  }
}))
')

  CREATE_RESP=$(curl -sS --http1.1 -X POST "$API/betaGroups" -H "$HDR_AUTH" -H "$HDR_JSON" -d "$PAYLOAD")
  ERR=$(printf '%s' "$CREATE_RESP" | python3 -c '
import sys, json
data = json.load(sys.stdin)
errs = data.get("errors")
if errs:
    print(f"{errs[0].get(\"title\",\"\")}: {errs[0].get(\"detail\",\"\")}")
' 2>/dev/null)
  if [ -n "$ERR" ]; then
    echo "❌ create group failed: $ERR" >&2
    printf '%s\n' "$CREATE_RESP" >&2
    exit 1
  fi
  GROUP_ID=$(printf '%s' "$CREATE_RESP" | python3 -c 'import sys, json; print(json.load(sys.stdin)["data"]["id"])')
  echo "  group id: $GROUP_ID"
else
  echo "▸ using existing group \"$GROUP_NAME\" (id $GROUP_ID)"
fi

# ---- check if tester already exists --------------------------------
EXISTING=$(curl -sS --http1.1 "$API/betaTesters?filter%5Bemail%5D=$EMAIL" -H "$HDR_AUTH" \
  | python3 -c '
import sys, json
items = json.load(sys.stdin).get("data", [])
print(items[0]["id"] if items else "")
')

if [ -n "$EXISTING" ]; then
  echo "▸ tester $EMAIL already exists (id $EXISTING) — adding to group only"
  # Add existing tester to group
  curl -sS --http1.1 -X POST "$API/betaGroups/$GROUP_ID/relationships/betaTesters" \
    -H "$HDR_AUTH" -H "$HDR_JSON" \
    -d "{\"data\":[{\"type\":\"betaTesters\",\"id\":\"$EXISTING\"}]}" > /dev/null
  echo "✅ $EMAIL added to \"$GROUP_NAME\""
  exit 0
fi

# ---- create new tester + assign to group ---------------------------
echo "▸ creating new tester $EMAIL and adding to \"$GROUP_NAME\""
TESTER_PAYLOAD=$(EMAIL="$EMAIL" FIRST="$FIRST" LAST="$LAST" GROUP_ID="$GROUP_ID" python3 -c '
import json, os
attrs = {"email": os.environ["EMAIL"]}
if os.environ.get("FIRST"):
    attrs["firstName"] = os.environ["FIRST"]
if os.environ.get("LAST"):
    attrs["lastName"] = os.environ["LAST"]
print(json.dumps({
  "data": {
    "type": "betaTesters",
    "attributes": attrs,
    "relationships": {
      "betaGroups": {"data": [{"type": "betaGroups", "id": os.environ["GROUP_ID"]}]}
    }
  }
}))
')

CREATE_T=$(curl -sS --http1.1 -X POST "$API/betaTesters" -H "$HDR_AUTH" -H "$HDR_JSON" -d "$TESTER_PAYLOAD")
ERR=$(printf '%s' "$CREATE_T" | python3 -c '
import sys, json
data = json.load(sys.stdin)
errs = data.get("errors")
if errs:
    print(f"{errs[0].get(\"title\",\"\")}: {errs[0].get(\"detail\",\"\")}")
' 2>/dev/null)

if [ -n "$ERR" ]; then
  echo "❌ invite failed: $ERR" >&2
  printf '%s\n' "$CREATE_T" >&2
  exit 1
fi

NEW_ID=$(printf '%s' "$CREATE_T" | python3 -c 'import sys, json; print(json.load(sys.stdin)["data"]["id"])')
echo "✅ invited $EMAIL"
echo "   tester id: $NEW_ID"
echo
echo "Apple sends an email invite when a build is available in the group."
echo "Run ./ship.sh to upload one if you haven't yet."
