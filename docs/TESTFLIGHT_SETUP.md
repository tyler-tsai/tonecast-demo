# TestFlight Setup — Apple-side checklist

What I (engineering side) already automated for you:

- ✅ `ship.sh` — one command to archive + export + upload to App Store Connect
- ✅ `preflight.sh` — verifies everything Apple would reject for, runs before each ship
- ✅ `ExportOptions.plist` — distribution signing config
- ✅ All required Info.plist keys (mic usage, export compliance, URL schemes,
       launch screen, App Group, keyboard extension config)
- ✅ Version `1.0.0`, build number 1 (ship.sh auto-bumps from here)
- ✅ OpenAI key removed from binary, proxy-only architecture verified

What you have to do on Apple's portals (one-time, ~30 min total):

---

## Part 1 — Apple Developer Portal (developer.apple.com)

### 1.1 Register Explicit App ID for the main app

Currently signing uses a wildcard / temporary ID. App Store needs an explicit ID
with the App Groups capability turned on.

1. Go to https://developer.apple.com/account/resources/identifiers/list
2. Click **＋** → **App IDs** → **App** → Continue
3. **Description**: `Tonecast`
4. **Bundle ID** → **Explicit** → `com.example.tonecast`
5. Scroll capabilities and **enable**:
   - ✅ **App Groups**
6. Click **Continue** → **Register**

### 1.2 Register Explicit App ID for the keyboard extension

Same flow, second App ID:

1. **＋** → **App IDs** → **App** → Continue
2. **Description**: `Tonecast Keyboard`
3. **Bundle ID** → **Explicit** → `com.example.tonecast.keyboard`
4. Capabilities — enable:
   - ✅ **App Groups**
5. Continue → Register

### 1.3 Configure App Group (likely already exists)

1. Identifiers → filter type **App Groups**
2. If `group.com.example.tonecast` doesn't exist:
   - **＋** → **App Groups** → Continue
   - Description: `Tonecast App Group`
   - Identifier: `group.com.example.tonecast`
   - Continue → Register
3. Open BOTH the Tonecast and Tonecast Keyboard App IDs (steps 1.1, 1.2)
   and verify the App Group is associated (Edit → check the group → Save).

### 1.4 Distribution provisioning profiles

`ship.sh` uses `signingStyle = automatic` so Xcode/xcodebuild handles this
behind the scenes when you authenticate. If you hit signing errors during
`./ship.sh`, do this manually:

1. https://developer.apple.com/account/resources/profiles/list
2. **＋** → **App Store** → Continue
3. App ID: `com.example.tonecast` → Continue
4. Certificates: select your **Apple Distribution** cert
5. Name: `Tonecast App Store`
6. Generate → Download → double-click to install in Keychain
7. Repeat for `com.example.tonecast.keyboard` → name it `Tonecast Keyboard App Store`

---

## Part 2 — App Store Connect (appstoreconnect.apple.com)

### 2.1 Create the app record

1. https://appstoreconnect.apple.com → **My Apps** → **＋** → **New App**
2. **Platforms**: ✅ iOS
3. **Name**: `Tonecast` (this is what shows up in App Store + TestFlight)
4. **Primary Language**: English (U.S.)
5. **Bundle ID**: pick `com.example.tonecast` from the dropdown
   (only appears if step 1.1 was done correctly)
6. **SKU**: any unique string — suggest `tonecast-001`
7. **User Access**: Full Access
8. → **Create**

You DON'T need to fill out App Information / Pricing / Screenshots /
description for TestFlight Internal Testing. Those are only required when
you submit for App Store Review (which you're not doing).

### 2.2 Create an App Store Connect API Key (for `ship.sh` to upload)

1. https://appstoreconnect.apple.com/access/api → **Keys** tab
2. **＋** → Name: `Tonecast ship script`
3. **Access**: **App Manager** (gives upload permission)
4. **Generate**
5. ✱ Critical: **download the `.p8` file IMMEDIATELY** — Apple shows it once.
   Save somewhere safe like `~/.appstore/AuthKey_<KEY_ID>.p8`.
6. Note the **Key ID** (10-char alphanumeric) and **Issuer ID** (UUID).

### 2.3 Wire the API key into your shell environment

Add to `~/.zshrc` (or use direnv if you prefer per-project):

```bash
export APP_STORE_KEY_ID="..."                          # 10-char from step 2.2
export APP_STORE_KEY_ISSUER_ID="..."                   # UUID from step 2.2
export APP_STORE_KEY_PATH="$HOME/.appstore/AuthKey_<KEY_ID>.p8"
```

Reload shell: `source ~/.zshrc`.

`xcrun altool` and `xcodebuild -exportArchive` will pick these up
automatically and skip the interactive login prompt.

---

## Part 3 — First ship + tester invite

### 3.1 Ship the first build

```bash
cd /path/to/tonecast
./ship.sh
```

This runs preflight, bumps the build number, archives in Release, exports
the .ipa, and uploads. Watch for:

```
✅ uploaded to App Store Connect — check TestFlight tab
   processing usually takes 5-30 min, you'll get an email when ready
```

Apple processes the build (5-30 min). You get an email when done.

### 3.2 Add tester(s)

Once processing finishes:

1. App Store Connect → My Apps → Tonecast → **TestFlight** tab
2. Sidebar: **Internal Testing** → **＋** → **Create New Group** (e.g. `Friends`)
3. Inside the group, **＋** next to Testers → add their Apple ID email
4. **Builds** section → click the just-processed build → **Add to Group**

Your tester:

1. Installs the **TestFlight** app from the App Store
2. Receives an email invite from Apple
3. Taps the invite link → **Accept** → **Install**
4. Tonecast appears on their home screen

### 3.3 Provide tester with first-launch instructions

The keyboard setup is non-obvious. Send them a quick blurb:

> Install Tonecast via TestFlight, then:
> 1. Open Tonecast once — read the in-app setup guide
> 2. Settings → General → Keyboards → Add New Keyboard → Tonecast
> 3. Tap Tonecast in the list → toggle **Allow Full Access** ON
> 4. In any app (Notes / iMessage), tap the globe key to switch to Tonecast
> 5. First tap on the mic briefly opens the Tonecast app (one-time, iOS
>    limitation) — afterwards it stays inside the keyboard.

---

## Re-shipping a new build later

Just run `./ship.sh` again. Build number auto-bumps. Same Apple ID +
provisioning. The tester sees the new build in TestFlight automatically.

To roll out a build to a specific group only, add the build to that
group in App Store Connect (Builds → click build → Add to Group).

---

## Cost summary

| Item | Cost |
|---|---|
| Apple Developer Program | $99/yr (you already have) |
| TestFlight | free (included) |
| App Store Connect API | free |
| Cloudflare Workers (proxy) | $5/mo (or free tier ~100K req/day) |
| OpenAI usage | per-request, capped via Worker config + OpenAI hard cap |

No new spend for sharing Tonecast with 1–100 testers via TestFlight.

---

## Build expiry

TestFlight builds expire after **90 days**. Apple emails you 30/14/7 days
before. To extend: `./ship.sh` again, new build replaces it.

---

## Troubleshooting

**"No provisioning profile found"** during `./ship.sh`
→ Did you complete Part 1.1 / 1.2 (explicit App IDs)?
→ Open Xcode once → Settings → Accounts → Download Manual Profiles.

**Upload succeeds but build never appears in TestFlight**
→ Processing can take up to an hour during peak. Check email — Apple sends
  a separate notification if the build is rejected for technical reasons
  (e.g. missing usage description, encryption compliance).

**"Asset validation failed: missing 1024x1024 icon"**
→ Run `./preflight.sh` — would have caught this. If `Tonecast/Assets.xcassets/
  AppIcon.appiconset/icon-1024.png` is missing, run
  `swift tools/render_icon.swift` to regenerate it.

**Tester says "TestFlight invitation expired"**
→ App Store Connect → TestFlight → Internal Testing → re-send invite.

**Build rejected with "App uses non-standard cryptography"**
→ This is the `ITSAppUsesNonExemptEncryption` prompt. Already set to
  `false` in Info.plist so you won't see this. If you do, double-check
  the plist hasn't been edited.
