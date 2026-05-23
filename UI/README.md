# Tonecast UI screenshots

iPhone 17 Pro simulator (1206 × 2622, iOS 26.5). Captured from
`Debug-iphonesimulator` build. Each screen below maps to a SwiftUI view in
[Tonecast/](../Tonecast/) — file path noted for cross-reference.

## Main app

| File | Screen | Source |
| --- | --- | --- |
| `01_main_home.png` | Home with Verify-keyboard card + idle Flow Session | [ContentView.swift](../Tonecast/ContentView.swift) + [PermissionStatusView.swift](../Tonecast/PermissionStatusView.swift) |
| `08_flow_session_active.png` | Home after Flow Session has been activated | [ContentView.swift](../Tonecast/ContentView.swift) |

## Settings (scrollable Form)

| File | Section | Source |
| --- | --- | --- |
| `02c_settings_tones.png` | Defaults (tone, translate) + Tone style guides list | [SettingsView.swift](../Tonecast/SettingsView.swift) |
| `02d_settings_bottom.png` | Subscription + Network + About | [SubscriptionSection.swift](../Tonecast/SubscriptionSection.swift) |

## Recording history

| File | State | Source |
| --- | --- | --- |
| `03_history_empty.png` | Empty state | [HistoryView.swift](../Tonecast/HistoryView.swift) |
| `04_history_seeded.png` | With three sample entries (different tones + zh→en translate) | [HistoryView.swift](../Tonecast/HistoryView.swift) |

## Setup guide

| File | Section | Source |
| --- | --- | --- |
| `05a_setup_guide_top.png` | Hero + steps 1-4 (Enable keyboard, Full Access, Use it, Hide dictation mic) | [SetupGuideView.swift](../Tonecast/SetupGuideView.swift) |
| `05b_setup_guide_bottom.png` | "Why the first tap opens this app" explanation | [SetupGuideView.swift](../Tonecast/SetupGuideView.swift) |

## Paywall (Tonecast Plus)

| File | Section | Source |
| --- | --- | --- |
| `06a_paywall_top.png` | Hero, benefit bullets, yearly/monthly product cells | [PaywallView.swift](../Tonecast/PaywallView.swift) |
| `06b_paywall_bottom.png` | Restore Purchases + auto-renew disclosure + legal links | [PaywallView.swift](../Tonecast/PaywallView.swift) |

## Tone prompt editor (`Casual` selected)

| File | Section | Source |
| --- | --- | --- |
| `07a_tone_prompt_top.png` | 中文 intent description + worked input→output samples | [TonePromptEditorView.swift](../Tonecast/TonePromptEditorView.swift) |
| `07b_tone_prompt_styleguide.png` | English style-guide editor + Creativity slider top | [TonePromptEditorView.swift](../Tonecast/TonePromptEditorView.swift) |
| `07c_tone_prompt_temperature.png` | Creativity (temperature) detail + Reset-to-default | [TonePromptEditorView.swift](../Tonecast/TonePromptEditorView.swift) |

## Keyboard extension

| File | State | Source |
| --- | --- | --- |
| `09_keyboard.png` | Tone segmented control + Translate + Mic + Delete + "Enable Full Access" warning + Send | [TonecastKeyboard/KeyboardViewController.swift](../TonecastKeyboard/KeyboardViewController.swift) |

The keyboard appears here because we embedded `KeyboardViewController` in
the main app for screenshot purposes — in real use it's a system-installed
keyboard extension that appears inside any host text field.

## How these were captured

Status bar shows 11:28 / Wi-Fi-only because the screenshots came out of a
freshly-booted simulator before any data calls. To regenerate after UI
changes, boot a simulator + use the `xcrun simctl io booted screenshot`
pattern; for views deeper than the home screen, a temporary launch-arg
router (`-screenshotRoute <name>`) was used and removed once captures
were complete.
