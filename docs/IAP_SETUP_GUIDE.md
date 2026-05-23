# IAP Setup Guide — Tonecast Plus

This is the operator runbook for Tonecast Plus. The code side (proxy +
iOS + ASC products) is automated; what's left is App Store Connect web
UI bits Apple's API doesn't cover, plus the on-device sandbox smoke
test. Budget ~30-45 minutes the first time.

---

## Background

**Architecture**: tier is server-authoritative. The iOS client sends
Apple-signed StoreKit 2 JWS transactions to `/v1/iap/verify`, the proxy
validates Apple's signature, persists the resulting tier per device,
and the rate limiter looks it up there. Any client-supplied tier hint
header is ignored — an attacker who bypasses iOS and hits the proxy
directly claiming Plus will still be rate-limited as Free.

**What's already done in code**:

- Proxy: `your-proxy/src/lib/appConfig.ts` `tonecast.plusProductIds`
  added. Deployed.
- iOS:
  - `Tonecast/IAPService.swift` (StoreKit 2 actor + warmUp + sync)
  - `Tonecast/PaywallView.swift` (paywall sheet)
  - `Tonecast/SubscriptionSection.swift` (Settings section)
  - `Tonecast/UserTier.swift` (read-only cache; IAPService is sole writer)
  - `Tonecast/SettingsView.swift` (Subscription section wired in)
  - `Tonecast/TonecastApp.swift` (configure + warmUp + syncWithServer)
- ASC: `scripts/asc/asc_setup.py` created and run — both products in
  ASC with price, availability, screenshot, en-US localization.
- Legal pages: `tonecast-privacy.html` + `tonecast-terms.html` live at
  `https://your-org.github.io/legal-pages/`.

**What you need to do**: 4 ASC web UI clicks + sandbox smoke test on
device.

---

## Product IDs

Hard-coded on both sides. **Don't rename these unless you're prepared
to change both at once.**

- `tonecast.plus.monthly` — $4.99 / month
- `tonecast.plus.annual` — $39.99 / year (~33% off)

Apple disallows hyphens in productId so we can't reuse the bundle
prefix (`com.example.tonecast.*`). We use the brand `tonecast.*`
namespace instead.

Pricing: $4.99/mo and $39.99/yr. Per-use API cost structure (Whisper +
GPT) drives the floor; the annual gives ~33% off as a retention nudge.

---

## Step 1 — Enable In-App Purchase capability on the App ID

1. <https://developer.apple.com/account/resources/identifiers/list>
2. Find `com.example.tonecast` and click into it.
3. **Capabilities** list, check **In-App Purchase**.
4. **Save**.

(`com.example.tonecast.keyboard` does NOT need this — keyboard
extensions can't trigger purchases.)

No entitlement file change needed. `Tonecast.entitlements` doesn't need
an `in-app-payments` key — that's the Apple Pay entitlement, not
StoreKit.

---

## Step 2 — Set Privacy Policy URL on App Information

Apple requires this for any app with a subscription.

1. <https://appstoreconnect.apple.com> → **My Apps** → **Tonecast** →
   **App Information**.
2. **Privacy Policy URL**:
   `https://your-org.github.io/legal-pages/tonecast-privacy.html`
3. (Optional but recommended) **Subscription Terms of Use URL**: leave
   blank — Apple uses the standard EULA; PaywallView links to the
   tonecast-specific terms directly.
4. **Save**.

---

## Step 3 — Confirm App Category

ASC → Tonecast → **App Information** → **Primary Category**:
**Productivity** (or Utilities). Subscription products stay in
`MISSING_METADATA` if the parent app doesn't have a category set.

---

## Step 4 — Sandbox Tester

Sandbox testers are per-team, not per-app — if you already have one
from a previous project, it works fine here too. To create a new one:

1. <https://appstoreconnect.apple.com> → **Users and Access** →
   **Sandbox** (tab).
2. **+** → any email (doesn't need to be real; Apple uses it as the
   account identifier). Password meeting Apple's complexity rules.
   Region: **United States**.
3. **Save**.

On your iPhone:
1. **Settings** → **App Store** → scroll to bottom → **Sandbox Account**.
2. Sign in with the sandbox tester credentials.

---

## Step 5 — Real-device smoke test

```bash
cd /path/to/tonecast
make device       # or: xcodebuild + devicectl install
```

**Do NOT `xcrun devicectl device uninstall`** — iOS uninstall purges
Documents/, UserDefaults, and any SwiftData state. Use `make device`
(install-without-uninstall).

Flow:

1. Open the app, tap **gear** (Settings).
2. **Subscription** section should show `Plan: Free`, **Upgrade to
   Plus** button visible.
3. Tap **Upgrade to Plus**.
4. The paywall should load with both monthly + annual products and
   their prices. **First tap should NOT flash-close** — that's the
   warmUp() fix at work (TonecastApp init + button tap both call
   `await IAPService.shared.warmUp()`).
5. If the paywall shows "No subscriptions available":
   - Sandbox Account signed in? (Settings → App Store → bottom)
   - Product IDs in ASC EXACTLY match `tonecast.plus.monthly` /
     `.annual`?
   - Products in `MISSING_METADATA` in ASC? — Apple's state machine
     often only recomputes after you LOAD each subscription in the
     ASC web UI once (no edit needed). The script's `--status` output
     will say `MISSING_METADATA` initially even though all metadata
     is present.
   - Propagation delay (5–30 minutes after creation)?
6. Tap **Tonecast Plus Annual** (or Monthly). StoreKit purchase sheet
   appears with the sandbox tester email at the top.
7. Confirm purchase.
8. Sheet dismisses. Settings → Subscription now shows
   `Plan: Tonecast Plus`, `Renews / expires: <date>`.

Behind the scenes:
- IAPService receives a verified `Transaction`.
- `transaction.finish()` called.
- JWS posted to
  `https://your-proxy.example.workers.dev/v1/iap/verify`.
- Proxy verifies Apple's signature, writes `tier:<keyId>` to KV.

---

## Step 6 — Proxy-side verification

```bash
cd /path/to/your-proxy
pnpm wrangler tail
```

Relaunch the app (or trigger a sync via Restore Purchases). Expect:

```
iap_ok { app: 'tonecast', keyId_prefix: '...', productId: 'tonecast.plus.annual', environment: 'Sandbox', expiresAt: '...' }
```

Then record something with the keyboard. Each request logs:

```
forward { app: 'tonecast', ..., tier: 'plus', ... }
```

And the HTTP response includes `X-Quota-Cap: 1000` (vs Free
`X-Quota-Cap: 200`).

---

## Step 7 — Cancellation flow (sandbox)

Sandbox subscriptions auto-renew at compressed intervals (Apple's
docs: a "1-month" sub renews every 5 min for 6 cycles, then stops).

1. Device: Settings → Apple ID → Subscriptions → Tonecast Plus →
   Cancel.
2. Wait ~30 s.
3. Apple delivers a `Transaction.updates` event (revocationDate set,
   or expirationDate moved to the past).
4. IAPService listener → syncWithServer → proxy sees no active
   entitlement → KV record resolves to `tier: 'free'`.
5. Next proxy request: `tier: 'free'`, `X-Quota-Cap: 200`.

---

## Troubleshooting

### Paywall flashes open then closes on first tap

This is the bug `warmUp()` was added to fix. If you still see it:

1. Check `TonecastApp.swift` has the `await IAPService.shared.warmUp()`
   call inside the `Task.detached` block.
2. Check `SubscriptionSection.swift`'s "Upgrade to Plus" button also
   calls `await IAPService.shared.warmUp()` before setting
   `showingPaywall = true`.
3. Confirm there's no `NotificationCenter.default.publisher(for:
   UserDefaults.didChangeNotification)` observer on the section — that
   re-renders during sheet presentation when ANY pref changes, which
   is the second cause of the flash.

### Paywall shows "No subscriptions available"

- Sandbox Account not signed in (Settings → App Store → bottom).
- Product IDs typo'd (must EXACTLY match
  `IAPService.ProductIdentifiers`).
- Products not yet "Ready to Submit". Run
  `python3 scripts/asc/asc_setup.py --status` to see state. If
  `MISSING_METADATA`, open each subscription in the ASC web UI once —
  Apple sometimes only recomputes state on view.
- App Store sandbox propagation delay (5–30 min after creation).

### `/v1/iap/verify` returns 401 `iap_jws_signature_invalid`

Sandbox JWS chains to a different intermediate than production, but
both chain to Apple Root CA - G3 (the bundled root). If this fails on
sandbox, it's a logic bug in `iapVerify.ts` — re-run the proxy test
suite (`pnpm test`).

### `/v1/iap/verify` returns 403 `iap_bundle_mismatch`

The bundle ID in App Store Connect doesn't match `AppConfig.bundleId`
on the proxy. Proxy expects `com.example.tonecast`. If you renamed
the app, update `your-proxy/src/lib/appConfig.ts` AND redeploy.

### Settings → Subscription stuck on "Free" after a successful purchase

- `IAPService.syncWithServer()` runs ~3 s after launch and on every
  `Transaction.updates`. If it failed (proxy unreachable, App Attest
  not set up yet), the local cache might still show Free.
- Force a re-sync: tap **Restore Purchases** on the paywall.
- Still wrong? Check device logs in Console.app for `tonecast/IAP`
  entries.

---

## Files

iOS:
- `Tonecast/IAPService.swift` (new)
- `Tonecast/UserTier.swift` (new)
- `Tonecast/PaywallView.swift` (new)
- `Tonecast/SubscriptionSection.swift` (new)
- `Tonecast/SettingsView.swift` (added Subscription section)
- `Tonecast/TonecastApp.swift` (added IAPService configure + warmUp + syncWithServer)

ASC automation:
- `scripts/asc/asc_setup.py` (new)

Proxy:
- The Worker config gets a `plusProductIds` array added to the
  tonecast app entry. JWS verifier, tier store, routes, rate
  limiter, and Apple Root CA G3 chain are the parts you'd build
  once in your own Worker.

Legal pages:
- `your-legal/tonecast-privacy.html` — keyboard-app-specific copy
  (Full Access disclosure, no-keystroke-logging promise, audio
  flow to OpenAI/OpenRouter).
- `your-legal/tonecast-terms.html` — auto-renew disclosure plus
  tonecast-specific acceptable-use clauses.

---

## Decision log

- **Subscription (auto-renew) over one-time purchase**: ongoing OpenAI
  / OpenRouter token cost needs ongoing revenue.
- **Pricing $4.99/mo + $39.99/yr**: per-use API cost (Whisper + GPT)
  sets the floor; annual is priced ~33% under monthly as a retention
  nudge.
- **Free 200/day, Plus 1,000/day**: a keyboard user dictating across
  the day will easily hit 200 (longer audio + rewrite roundtrips).
  Plus at 1,000 lifts the cap for heavy multilingual chat sessions
  without going to "unlimited" (which invites token-cost abuse).
- **`tonecast.*` namespace** (not `com.example.tonecast.*`): Apple
  rejects hyphens in productId. The bundleId is hyphen-free so we
  *could* use it, but `tonecast.plus.*` reads more cleanly in logs.
- **No free trial**: simpler launch; revisit if conversion data
  later shows trial is needed.
