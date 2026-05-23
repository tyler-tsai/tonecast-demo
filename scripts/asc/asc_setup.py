#!/usr/bin/env python3
"""
One-shot App Store Connect setup for Tonecast IAP.

Idempotent: re-running checks existing state and only creates what's
missing. Safe to run multiple times.

Creates:
  - App-level "Free" price tier (USA base) — without this, StoreKit
    `Product.products()` returns empty even when IAPs are otherwise OK.
  - App contentRightsDeclaration = DOES_NOT_USE_THIRD_PARTY_CONTENT.
  - Subscription Group  : "Tonecast Plus"
  - Monthly subscription: tonecast.plus.monthly @ USD 4.99
  - Annual subscription : tonecast.plus.annual  @ USD 39.99
  - English localizations for both products + the group
  - IAP review screenshot (1290x2796 PNG), uploaded + committed so the
    subscription leaves MISSING_METADATA / WAITING_FOR_SCREENSHOT.

Sub-commands:
  (default)        : run full setup (idempotent)
  --status         : print current ASC state for all IAP resources
  --screenshot-only: only re-upload the review screenshot

Does NOT do (must be done by hand):
  - Sandbox tester (Apple's API for this is iffy; faster in the UI;
    sandbox testers are per-team, so any existing one on your team works)
  - Sign sandbox account into iPhone Settings → App Store → Sandbox Account
  - Sign Paid Apps Agreement (one-time per team)

Requires the App Store Connect API key created via:
  ASC → Users and Access → Integrations → App Store Connect API
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.request
import urllib.error
from typing import Optional

import jwt

# -----------------------------------------------------------------------------
# Config

# Read App Store Connect API credentials from environment.
# Generate a key at: ASC → Users and Access → Integrations → App Store Connect API
#
#   export APP_STORE_KEY_ID="..."          # 10-char key ID
#   export APP_STORE_KEY_ISSUER_ID="..."   # UUID issuer ID
#   export APP_STORE_KEY_PATH="~/.config/asc-api/AuthKey_XXXXXXXXXX.p8"
KEY_ID = os.environ.get("APP_STORE_KEY_ID", "").strip()
ISSUER_ID = os.environ.get("APP_STORE_KEY_ISSUER_ID", "").strip()
KEY_PATH = os.path.expanduser(os.environ.get("APP_STORE_KEY_PATH", "").strip())

if not (KEY_ID and ISSUER_ID and KEY_PATH):
    sys.exit(
        "Missing ASC credentials. Set APP_STORE_KEY_ID, "
        "APP_STORE_KEY_ISSUER_ID, APP_STORE_KEY_PATH before running."
    )

APP_BUNDLE_ID = os.environ.get("APP_BUNDLE_ID", "com.example.tonecast")

GROUP_REFERENCE_NAME = "Tonecast Plus"

PRODUCTS = [
    {
        # Apple's productId rule: alphanumeric + underscore + period only.
        # The bundleId (com.example.tonecast) is hyphen-free, but we
        # still use the brand `tonecast.*` namespace to keep the
        # productId visually distinct from the bundle id in logs.
        "product_id": "tonecast.plus.monthly",
        "reference_name": "Tonecast Plus Monthly",
        "period": "ONE_MONTH",
        "target_price_usd": 4.99,
        "loc_name": "Tonecast Plus",
        "loc_desc": "1,000 keyboard requests/day for heavy dictation",
    },
    {
        "product_id": "tonecast.plus.annual",
        "reference_name": "Tonecast Plus Annual",
        "period": "ONE_YEAR",
        "target_price_usd": 39.99,
        "loc_name": "Tonecast Plus",
        "loc_desc": "1,000 keyboard requests/day — save 33% vs monthly",
    },
]

GROUP_LOCALIZATIONS = [
    # (locale, displayName)
    ("en-US", "Tonecast Plus"),
]

REVIEW_NOTE = (
    "Tonecast Plus is an auto-renewing subscription that lifts the daily "
    "keyboard request cap from 200 to 1,000 on the proxy backend. The Free "
    "tier remains fully functional; Plus only raises the rate limit."
)

API_BASE = "https://api.appstoreconnect.apple.com"

# -----------------------------------------------------------------------------
# JWT + HTTP


def make_jwt() -> str:
    with open(KEY_PATH, "rb") as f:
        private_key = f.read()
    now = int(time.time())
    return jwt.encode(
        payload={
            "iss": ISSUER_ID,
            "iat": now,
            "exp": now + 1200,
            "aud": "appstoreconnect-v1",
        },
        key=private_key,
        algorithm="ES256",
        headers={"kid": KEY_ID, "typ": "JWT"},
    )


def http(method: str, path: str, body: Optional[dict] = None, token: Optional[str] = None) -> dict:
    """Make an ASC API call. Returns parsed JSON. Raises on non-2xx with the
    Apple error body printed for debugging."""
    if token is None:
        token = make_jwt()
    url = path if path.startswith("http") else API_BASE + path
    data = None
    headers = {"Authorization": f"Bearer {token}"}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        body_text = e.read().decode()
        print(f"\n!! HTTP {e.code} {method} {path}")
        print(body_text[:2000])
        try:
            err = json.loads(body_text)
            for d in err.get("errors", []):
                print(f"   - {d.get('code')}: {d.get('title')} — {d.get('detail')}")
        except Exception:
            pass
        raise


# -----------------------------------------------------------------------------
# Resource lookup + create helpers


def find_app(bundle_id: str) -> dict:
    res = http("GET", "/v1/apps?limit=200")
    for app in res["data"]:
        if app["attributes"]["bundleId"] == bundle_id:
            return app
    raise SystemExit(f"App with bundleId {bundle_id} not found")


def find_subscription_group(app_id: str, ref_name: str) -> Optional[dict]:
    res = http("GET", f"/v1/apps/{app_id}/subscriptionGroups?limit=200")
    for g in res["data"]:
        if g["attributes"]["referenceName"] == ref_name:
            return g
    return None


def create_subscription_group(app_id: str, ref_name: str) -> dict:
    body = {
        "data": {
            "type": "subscriptionGroups",
            "attributes": {"referenceName": ref_name},
            "relationships": {
                "app": {"data": {"type": "apps", "id": app_id}},
            },
        }
    }
    res = http("POST", "/v1/subscriptionGroups", body)
    return res["data"]


def list_subscriptions_in_group(group_id: str) -> list:
    res = http("GET", f"/v1/subscriptionGroups/{group_id}/subscriptions?limit=200")
    return res["data"]


def create_subscription(group_id: str, product_id: str, reference_name: str, period: str, review_note: str) -> dict:
    body = {
        "data": {
            "type": "subscriptions",
            "attributes": {
                "name": reference_name,
                "productId": product_id,
                "familySharable": False,
                "subscriptionPeriod": period,
                "reviewNote": review_note,
                "groupLevel": 1,
            },
            "relationships": {
                "group": {"data": {"type": "subscriptionGroups", "id": group_id}},
            },
        }
    }
    res = http("POST", "/v1/subscriptions", body)
    return res["data"]


def list_subscription_localizations(subscription_id: str) -> list:
    res = http("GET", f"/v1/subscriptions/{subscription_id}/subscriptionLocalizations?limit=200")
    return res["data"]


def create_subscription_localization(subscription_id: str, locale: str, name: str, description: str) -> dict:
    body = {
        "data": {
            "type": "subscriptionLocalizations",
            "attributes": {
                "name": name,
                "description": description,
                "locale": locale,
            },
            "relationships": {
                "subscription": {"data": {"type": "subscriptions", "id": subscription_id}},
            },
        }
    }
    res = http("POST", "/v1/subscriptionLocalizations", body)
    return res["data"]


def list_subscription_group_localizations(group_id: str) -> list:
    res = http("GET", f"/v1/subscriptionGroups/{group_id}/subscriptionGroupLocalizations?limit=200")
    return res["data"]


def create_subscription_group_localization(group_id: str, locale: str, name: str) -> dict:
    body = {
        "data": {
            "type": "subscriptionGroupLocalizations",
            "attributes": {
                "name": name,
                "locale": locale,
            },
            "relationships": {
                "subscriptionGroup": {"data": {"type": "subscriptionGroups", "id": group_id}},
            },
        }
    }
    res = http("POST", "/v1/subscriptionGroupLocalizations", body)
    return res["data"]


def find_price_point_for_usd(subscription_id: str, target_usd: float) -> Optional[dict]:
    """Find a subscription price point in USA territory closest to target USD."""
    path = f"/v1/subscriptions/{subscription_id}/pricePoints?filter[territory]=USA&limit=200"
    best = None
    best_diff = 1e9
    while path:
        res = http("GET", path)
        for pp in res["data"]:
            try:
                price = float(pp["attributes"]["customerPrice"])
            except (KeyError, ValueError):
                continue
            diff = abs(price - target_usd)
            if diff < best_diff:
                best_diff = diff
                best = pp
                if diff < 0.005:
                    return pp
        nxt = res.get("links", {}).get("next")
        if nxt:
            path = nxt.replace(API_BASE, "")
        else:
            path = None
    return best


def list_subscription_prices(subscription_id: str) -> list:
    res = http(
        "GET",
        f"/v1/subscriptions/{subscription_id}/prices?include=subscriptionPricePoint,territory&limit=200",
    )
    return res["data"]


def get_subscription_availability(subscription_id: str) -> Optional[dict]:
    try:
        r = http("GET", f"/v1/subscriptions/{subscription_id}/subscriptionAvailability")
        return r.get("data")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def create_subscription_availability(subscription_id: str, territory: str = "USA") -> dict:
    """Subscription must have availability set before initial prices can be
    created. Discovered the hard way — Apple's docs don't mention this
    prerequisite. POST creates the record with availableInNewTerritories=true
    so auto-translation works when Apple adds new App Store regions."""
    body = {
        "data": {
            "type": "subscriptionAvailabilities",
            "attributes": {"availableInNewTerritories": True},
            "relationships": {
                "subscription": {"data": {"type": "subscriptions", "id": subscription_id}},
                "availableTerritories": {"data": [{"type": "territories", "id": territory}]},
            },
        }
    }
    res = http("POST", "/v1/subscriptionAvailabilities", body)
    return res["data"]


def get_app_attributes(app_id: str) -> dict:
    return http("GET", f"/v1/apps/{app_id}")["data"]["attributes"]


def patch_app_content_rights(app_id: str, value: str = "DOES_NOT_USE_THIRD_PARTY_CONTENT") -> None:
    """Required field. While Apple's UI hides this for apps that don't use
    third-party content, the API leaves it null until set, and a null
    contentRightsDeclaration can keep subscription state stuck."""
    http("PATCH", f"/v1/apps/{app_id}", {
        "data": {"type": "apps", "id": app_id, "attributes": {"contentRightsDeclaration": value}}
    })


def get_app_price_schedule(app_id: str) -> Optional[dict]:
    r = http("GET", f"/v1/appPriceSchedules/{app_id}")
    return r.get("data")


def list_app_price_schedule_manual_prices(app_id: str) -> list:
    # Brand-new apps that have never had a schedule set return 404 on
    # the subpath even when GET /v1/appPriceSchedules/{app_id} returns a
    # stub. Treat 404 as "no manual prices yet" rather than a hard fail.
    try:
        r = http("GET", f"/v1/appPriceSchedules/{app_id}/manualPrices")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return []
        raise
    return r.get("data", []) if "data" in r else []


def find_app_price_point_usd(app_id: str, target_usd: float) -> Optional[dict]:
    """Find an app-level price point in USA territory matching target USD.
    target_usd=0 → free tier."""
    path = f"/v1/apps/{app_id}/appPricePoints?filter[territory]=USA&limit=200"
    best = None
    best_diff = 1e9
    while path:
        res = http("GET", path)
        for pp in res["data"]:
            try:
                price = float(pp["attributes"]["customerPrice"])
            except (KeyError, ValueError, TypeError):
                continue
            diff = abs(price - target_usd)
            if diff < best_diff:
                best_diff = diff
                best = pp
                if diff < 0.005:
                    return pp
        nxt = res.get("links", {}).get("next")
        path = nxt.replace(API_BASE, "") if nxt else None
    return best


def create_app_price_schedule_free(app_id: str, free_price_point_id: str) -> dict:
    """Set app to Free tier on USA. Required for new apps before the
    subscriptions inside it become loadable via StoreKit. Apple's API
    uses include + placeholder ids; this mirrors that pattern."""
    body = {
        "data": {
            "type": "appPriceSchedules",
            "relationships": {
                "app": {"data": {"type": "apps", "id": app_id}},
                "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                "manualPrices": {"data": [{"type": "appPrices", "id": "${price1}"}]},
            },
            "attributes": {},
        },
        "included": [{
            "id": "${price1}",
            "type": "appPrices",
            "attributes": {"startDate": None},
            "relationships": {
                "appPricePoint": {"data": {"type": "appPricePoints", "id": free_price_point_id}},
                "territory": {"data": {"type": "territories", "id": "USA"}},
            },
        }],
    }
    return http("POST", "/v1/appPriceSchedules", body)["data"]


def get_review_screenshot(subscription_id: str) -> Optional[dict]:
    r = http("GET", f"/v1/subscriptions/{subscription_id}/appStoreReviewScreenshot")
    return r.get("data") if isinstance(r, dict) else None


def delete_review_screenshot(screenshot_id: str) -> None:
    http("DELETE", f"/v1/subscriptionAppStoreReviewScreenshots/{screenshot_id}")


def upload_review_screenshot(subscription_id: str, png_path: str) -> dict:
    """Three-step Apple upload protocol:
      1. POST reservation with fileName + fileSize → get uploadOperations
      2. PUT binary chunks at each operation's URL with its headers
      3. PATCH uploaded=true + sourceFileChecksum to commit
    Skipping step 3 leaves the resource in a stuck state where Apple's
    UI still says "Waiting for Screenshot" even though bytes are stored.
    """
    with open(png_path, "rb") as f:
        img_bytes = f.read()
    file_name = os.path.basename(png_path)
    file_size = len(img_bytes)
    checksum = hashlib.md5(img_bytes).hexdigest()

    res = http("POST", "/v1/subscriptionAppStoreReviewScreenshots", {
        "data": {
            "type": "subscriptionAppStoreReviewScreenshots",
            "attributes": {"fileName": file_name, "fileSize": file_size},
            "relationships": {
                "subscription": {"data": {"type": "subscriptions", "id": subscription_id}},
            },
        }
    })
    new_id = res["data"]["id"]
    ops = res["data"]["attributes"]["uploadOperations"]

    for op in ops:
        method = op["method"]
        url = op["url"]
        offset = op["offset"]
        length = op["length"]
        op_headers = {h["name"]: h["value"] for h in op["requestHeaders"]}
        chunk = img_bytes[offset:offset + length]
        req = urllib.request.Request(url, data=chunk, method=method, headers=op_headers)
        with urllib.request.urlopen(req) as up:
            if up.status >= 300:
                raise SystemExit(f"binary upload failed: HTTP {up.status}")

    return http("PATCH", f"/v1/subscriptionAppStoreReviewScreenshots/{new_id}", {
        "data": {"type": "subscriptionAppStoreReviewScreenshots", "id": new_id,
                 "attributes": {"uploaded": True, "sourceFileChecksum": checksum}}
    })["data"]


def generate_placeholder_screenshot(out_path: str) -> str:
    """1290x2796 PNG (iPhone 6.7" portrait — Apple's reference IAP review
    screenshot size). Uses PIL if available, else falls back to `sips` so
    the script can run on a fresh macOS without `pip install Pillow`."""
    icon = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "..", "Tonecast", "Assets.xcassets",
                        "AppIcon.appiconset", "icon-1024.png")
    icon = os.path.normpath(icon)
    try:
        from PIL import Image, ImageDraw, ImageFont  # type: ignore
        W, H = 1290, 2796
        canvas = Image.new("RGB", (W, H), (255, 255, 255))
        ic = Image.open(icon).convert("RGBA").resize((600, 600), Image.LANCZOS)
        canvas.paste(ic, ((W - 600) // 2, 700), ic)
        draw = ImageDraw.Draw(canvas)
        try:
            f1 = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 80)
            f2 = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 48)
        except Exception:
            f1 = ImageFont.load_default(); f2 = ImageFont.load_default()
        draw.text((W // 2, 1450), "Tonecast Plus", fill=(20, 20, 30), font=f1, anchor="mm")
        draw.text((W // 2, 1560), "Unlimited keyboard dictation", fill=(80, 80, 90), font=f2, anchor="mm")
        draw.text((W // 2, 1620), "1,000 requests / day", fill=(80, 80, 90), font=f2, anchor="mm")
        canvas.save(out_path, "PNG", optimize=True)
    except ImportError:
        subprocess.check_call(["sips", "-s", "format", "png",
                               "-z", "2796", "1290", icon,
                               "--out", out_path], stdout=subprocess.DEVNULL)
    return out_path


def create_subscription_price(subscription_id: str, price_point_id: str, territory: str = "USA") -> dict:
    """Set a base price. Apple quirks (learned the hard way):
      - The subscription MUST have availability set first via
        POST /v1/subscriptionAvailabilities. Without it, this endpoint
        returns a vague "An error occurred while processing the
        pricing information" pointing at subscriptionPricePoint.id.
      - For INITIAL prices: omit startDate entirely.
      - For SCHEDULED FUTURE prices: include startDate ≥ tomorrow in
        Cupertino tz. We don't use that here.
      - territory IS required even though the price point ID embeds
        it. Apple cross-checks."""
    body = {
        "data": {
            "type": "subscriptionPrices",
            "relationships": {
                "subscription": {"data": {"type": "subscriptions", "id": subscription_id}},
                "subscriptionPricePoint": {"data": {"type": "subscriptionPricePoints", "id": price_point_id}},
                "territory": {"data": {"type": "territories", "id": territory}},
            },
        }
    }
    res = http("POST", "/v1/subscriptionPrices", body)
    return res["data"]


# -----------------------------------------------------------------------------
# Main orchestration


def setup(dry_run: bool = False):
    def info(msg: str):
        print(msg)

    def action(msg: str):
        prefix = "[DRY-RUN] " if dry_run else "→ "
        print(f"{prefix}{msg}")

    info("=" * 60)
    info(f"ASC setup — bundle {APP_BUNDLE_ID}")
    info("=" * 60)

    app = find_app(APP_BUNDLE_ID)
    app_id = app["id"]
    info(f"✓ App found: {app['attributes']['name']} (id={app_id})")

    if app["attributes"].get("contentRightsDeclaration") in (None, ""):
        action("Set app contentRightsDeclaration = DOES_NOT_USE_THIRD_PARTY_CONTENT")
        if not dry_run:
            patch_app_content_rights(app_id)
            info("  ✓ Set")
    else:
        info(f"✓ contentRightsDeclaration: {app['attributes']['contentRightsDeclaration']}")

    schedule = get_app_price_schedule(app_id)
    manual_prices = list_app_price_schedule_manual_prices(app_id) if schedule else []
    if manual_prices:
        info(f"✓ App price schedule set ({len(manual_prices)} entry/entries)")
    else:
        action("Set app price tier = Free on USA")
        if not dry_run:
            free_pp = find_app_price_point_usd(app_id, 0.0)
            if free_pp is None:
                info("  ✗ Couldn't find Free price point — skipping")
            else:
                create_app_price_schedule_free(app_id, free_pp["id"])
                info(f"  ✓ App set to Free on USA (price point {free_pp['id']})")

    group = find_subscription_group(app_id, GROUP_REFERENCE_NAME)
    if group:
        info(f"✓ Group exists: {GROUP_REFERENCE_NAME} (id={group['id']})")
    else:
        action(f"Create subscription group '{GROUP_REFERENCE_NAME}'")
        if not dry_run:
            group = create_subscription_group(app_id, GROUP_REFERENCE_NAME)
            info(f"  ✓ Created group id={group['id']}")
        else:
            return
    group_id = group["id"]

    existing_group_locs = {l["attributes"]["locale"]: l for l in list_subscription_group_localizations(group_id)}
    for locale, name in GROUP_LOCALIZATIONS:
        if locale in existing_group_locs:
            info(f"✓ Group localization {locale} exists")
        else:
            action(f"Create group localization {locale} '{name}'")
            if not dry_run:
                create_subscription_group_localization(group_id, locale, name)
                info(f"  ✓ Created group localization {locale}")

    existing_subs = {s["attributes"]["productId"]: s for s in list_subscriptions_in_group(group_id)}

    for cfg in PRODUCTS:
        info("")
        info(f"--- {cfg['product_id']} ---")

        sub = existing_subs.get(cfg["product_id"])
        if sub:
            info(f"✓ Subscription exists (id={sub['id']})")
        else:
            action(f"Create subscription {cfg['reference_name']} ({cfg['period']})")
            if not dry_run:
                sub = create_subscription(
                    group_id=group_id,
                    product_id=cfg["product_id"],
                    reference_name=cfg["reference_name"],
                    period=cfg["period"],
                    review_note=REVIEW_NOTE,
                )
                info(f"  ✓ Created subscription id={sub['id']}")
            else:
                continue
        sub_id = sub["id"]

        existing_locs = {l["attributes"]["locale"]: l for l in list_subscription_localizations(sub_id)}
        if "en-US" in existing_locs:
            info("✓ en-US localization exists")
        else:
            action(f"Create en-US localization name='{cfg['loc_name']}'")
            if not dry_run:
                create_subscription_localization(sub_id, "en-US", cfg["loc_name"], cfg["loc_desc"])
                info("  ✓ Created en-US localization")

        avail = get_subscription_availability(sub_id)
        if avail:
            info("✓ Availability set")
        else:
            action("Set USA availability")
            if not dry_run:
                create_subscription_availability(sub_id)
                info("  ✓ Availability set")

        prices = list_subscription_prices(sub_id)
        if prices:
            info(f"✓ {len(prices)} price entr(ies) already set")
        else:
            action(f"Find USA price point closest to ${cfg['target_price_usd']}")
            if not dry_run:
                pp = find_price_point_for_usd(sub_id, cfg["target_price_usd"])
                if pp is None:
                    info("  ✗ No matching price point found — skipping")
                else:
                    actual = pp["attributes"].get("customerPrice")
                    info(f"  Matched price point id={pp['id']} customerPrice=${actual}")
                    action("Create USA subscriptionPrice")
                    create_subscription_price(sub_id, pp["id"])
                    info("  ✓ Price set")

        ss = get_review_screenshot(sub_id)
        ss_ok = False
        if ss:
            state = ss.get("attributes", {}).get("assetDeliveryState", {}).get("state")
            checksum = ss.get("attributes", {}).get("sourceFileChecksum")
            if state == "COMPLETE" and checksum:
                info(f"✓ Review screenshot exists (state={state})")
                ss_ok = True
            else:
                action(f"Delete stuck screenshot {ss['id']} (state={state})")
                if not dry_run:
                    delete_review_screenshot(ss["id"])
                    info("  ✓ Deleted")
        if not ss_ok:
            action("Upload fresh review screenshot")
            if not dry_run:
                tmp_png = "/tmp/tonecast_iap_review_screenshot.png"
                if not os.path.exists(tmp_png):
                    info("  Generating placeholder 1290x2796 PNG…")
                    generate_placeholder_screenshot(tmp_png)
                new_ss = upload_review_screenshot(sub_id, tmp_png)
                state = new_ss.get("attributes", {}).get("assetDeliveryState", {}).get("state")
                info(f"  ✓ Uploaded + committed (assetDeliveryState={state})")

    info("")
    info("=" * 60)
    info("AUTOMATED PORTION DONE.")
    info("")
    info("Now run `./asc_setup.py --status` to confirm state.")
    info("If subscriptions still show MISSING_METADATA after a few minutes,")
    info("Apple's state machine often only recomputes after you LOAD the")
    info("subscription in the ASC web UI once (no edit needed).")
    info("")
    info("MANUAL STEPS REMAINING (Apple's API doesn't support these):")
    info("")
    info("1. PAID APPS AGREEMENT — verify ASC → Agreements, Tax, and Banking")
    info("   shows 'Active' for the Paid Apps agreement. This is one-time")
    info("   per team — if any other app on the same team has shipped paid")
    info("   IAP, it's already done.")
    info("")
    info("2. SANDBOX TESTER")
    info("   Sandbox testers are per-team, not per-app — any existing one")
    info("   works. To create a new one: ASC → Users and Access →")
    info("   Sandbox (tab) → + → any email/password, Region = United States.")
    info("")
    info("3. SIGN INTO SANDBOX ON iPhone (30s)")
    info("   Settings → App Store → scroll to bottom → Sandbox Account →")
    info("   sign in. Physical-device-only.")
    info("")
    info("4. PRIVACY POLICY URL on App Information page")
    info("   ASC → My Apps → Tonecast → App Information →")
    info("   Privacy Policy URL =")
    info("   https://your-org.github.io/legal-pages/tonecast-privacy.html")
    info("")
    info("5. ALLOW PROPAGATION")
    info("   After first creation, sandbox product propagation can take")
    info("   5–30 minutes (sometimes longer). The paywall's diagnostic")
    info("   block lists this as a possible cause.")
    info("=" * 60)


def status():
    """Print a compact report of the current ASC IAP state."""
    print("=" * 60)
    print("ASC status snapshot")
    print("=" * 60)
    app = find_app(APP_BUNDLE_ID)
    app_id = app["id"]
    a = app["attributes"]
    print(f"App: {a['name']} (id={app_id})")
    print(f"  bundleId: {a['bundleId']}")
    print(f"  primaryLocale: {a['primaryLocale']}")
    print(f"  contentRightsDeclaration: {a.get('contentRightsDeclaration')}")
    schedule = get_app_price_schedule(app_id)
    manual_prices = list_app_price_schedule_manual_prices(app_id) if schedule else []
    print(f"  app price tiers set: {len(manual_prices)}")

    for g in http("GET", f"/v1/apps/{app_id}/subscriptionGroups?limit=200")["data"]:
        print(f"\nGroup: {g['attributes']['referenceName']} (id={g['id']})")
        subs = list_subscriptions_in_group(g["id"])
        for s in subs:
            sa = s["attributes"]
            print(f"\n  {sa['productId']} (id={s['id']})")
            print(f"    name:          {sa['name']}")
            print(f"    state:         {sa['state']}")
            print(f"    period:        {sa['subscriptionPeriod']}")
            locs = list_subscription_localizations(s["id"])
            print(f"    localizations: {len(locs)} ({', '.join(l['attributes']['locale'] for l in locs)})")
            avail = get_subscription_availability(s["id"])
            print(f"    availability:  {'set' if avail else 'MISSING'}")
            prices = list_subscription_prices(s["id"])
            print(f"    prices:        {len(prices)} territory entries")
            ss = get_review_screenshot(s["id"])
            if ss:
                ssa = ss["attributes"]
                print(f"    screenshot:    id={ss['id']}, "
                      f"delivery={ssa.get('assetDeliveryState', {}).get('state')}, "
                      f"checksum={(ssa.get('sourceFileChecksum') or 'NULL')[:8]}…")
            else:
                print(f"    screenshot:    MISSING")
        try:
            iaps = http("GET", f"/v1/apps/{app_id}/inAppPurchases?limit=50")["data"]
            sub_ids = {sa['attributes']['productId'] for sa in subs}
            legacy = [(i['attributes']['productId'], i['attributes']['state']) for i in iaps
                      if i['attributes']['productId'] in sub_ids]
            print("\n  Legacy v1 state aggregation:")
            for pid, st in legacy:
                print(f"    {pid}: {st}")
        except Exception:
            pass
    print("=" * 60)


def screenshot_only():
    app = find_app(APP_BUNDLE_ID)
    group = find_subscription_group(app["id"], GROUP_REFERENCE_NAME)
    if not group:
        raise SystemExit("group missing — run full setup first")
    subs = list_subscriptions_in_group(group["id"])
    tmp_png = "/tmp/tonecast_iap_review_screenshot.png"
    print(f"Generating screenshot at {tmp_png}…")
    generate_placeholder_screenshot(tmp_png)
    for s in subs:
        sid = s["id"]
        pid = s["attributes"]["productId"]
        print(f"\n--- {pid} ---")
        old = get_review_screenshot(sid)
        if old:
            print(f"  Deleting old screenshot {old['id']}…")
            try:
                delete_review_screenshot(old["id"])
            except urllib.error.HTTPError as e:
                print(f"  ⚠ delete failed ({e.code}); trying upload anyway")
        new_ss = upload_review_screenshot(sid, tmp_png)
        print(f"  ✓ Uploaded {new_ss['id']} (state={new_ss['attributes']['assetDeliveryState']['state']})")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="Show what would be done without making changes")
    parser.add_argument("--status", action="store_true", help="Print current ASC state and exit")
    parser.add_argument("--screenshot-only", action="store_true", help="Only re-upload the IAP review screenshot")
    args = parser.parse_args()
    if args.status:
        status()
    elif args.screenshot_only:
        screenshot_only()
    else:
        setup(dry_run=args.dry_run)
