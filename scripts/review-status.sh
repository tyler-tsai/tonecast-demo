#!/usr/bin/env bash
#
# review-status.sh — print the current Beta App Review status for the
# most-recently-uploaded Tonecast build. Doesn't wait — just snapshots.
#
# Useful while waiting for Apple's first-submission review (typically
# 12-48h). Run as often as you want; it just hits the read-only ASC API.
#
# States you'll see:
#   WAITING_FOR_REVIEW   — submitted, in Apple's queue, not yet looked at
#   IN_REVIEW            — actively being reviewed by an Apple reviewer
#   APPROVED             — done! testers in External groups can install
#   REJECTED             — rejected, check email for feedback
#
set -euo pipefail
cd "$(dirname "$0")/.."

TOKEN=$(python3 scripts/asc_jwt.py)
API="https://api.appstoreconnect.apple.com/v1"
APP_ID=6772066346

# Latest build id (most recent uploadedDate)
BUILD_JSON=$(curl -sS --http1.1 "$API/builds?filter%5Bapp%5D=$APP_ID&sort=-uploadedDate&limit=1" \
  -H "Authorization: Bearer $TOKEN")
BUILD_ID=$(printf '%s' "$BUILD_JSON" | python3 -c 'import sys, json; print(json.load(sys.stdin)["data"][0]["id"])')
BUILD_VER=$(printf '%s' "$BUILD_JSON" | python3 -c 'import sys, json; print(json.load(sys.stdin)["data"][0]["attributes"]["version"])')

echo "Latest build: $BUILD_VER  (id $BUILD_ID)"

REVIEW=$(curl -sS --http1.1 "$API/betaAppReviewSubmissions/$BUILD_ID" \
  -H "Authorization: Bearer $TOKEN")
ERROR=$(printf '%s' "$REVIEW" | python3 -c '
import sys, json
d = json.load(sys.stdin)
if "errors" in d:
    e = d["errors"][0]
    status = e.get("status")
    title = e.get("title")
    print("%s: %s" % (status, title))
' 2>/dev/null)

if [ -n "$ERROR" ]; then
  echo "Status: NOT SUBMITTED ($ERROR)"
  echo "   (This build has not been submitted for Beta Review yet.)"
  exit 0
fi

printf '%s' "$REVIEW" | python3 -c '
import sys, json
d = json.load(sys.stdin)
a = d["data"]["attributes"]
state = a.get("betaReviewState", "UNKNOWN")
submitted = a.get("submittedDate") or "(not yet)"
emoji = {
    "WAITING_FOR_REVIEW": "⏳",
    "IN_REVIEW":          "🔎",
    "APPROVED":           "✅",
    "REJECTED":           "❌",
}.get(state, "❓")
print(f"Status: {emoji} {state}")
print(f"  submitted: {submitted}")
'
