import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var flowDuration: Int = SharedDefaults.flowDurationMinutes()
    @State private var defaultTone: Int = SharedDefaults.defaultTone()
    @State private var defaultTranslate: Int = SharedDefaults.defaultTranslate()
    @State private var holdToTalk: Bool = SharedDefaults.holdToTalkMode()
    @State private var whisperLanguage: String = SharedDefaults.whisperLanguage()
    @State private var personalVocab: String = SharedDefaults.personalVocabulary()
    @State private var showAboutDetails: Bool = false

    // Paywall sheet state is hosted here (not inside SubscriptionSection)
    // — declaring it deeper in the view tree confuses SwiftUI's modal
    // management and causes the sheet to flash-close on first tap.
    @State private var showingPaywall: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                // 1. RECORDING — trigger + duration (most-used)
                Section {
                    Toggle(isOn: $holdToTalk) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hold to talk")
                            Text(holdToTalk
                                 ? "Press and hold the mic, release to stop"
                                 : "Tap the mic to start, tap again to stop")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Picker("Flow Session duration", selection: $flowDuration) {
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("60 minutes").tag(60)
                    }
                } header: {
                    Text("Recording")
                } footer: {
                    Text("How the mic behaves and how long the background recording session stays alive after activation. Longer = fewer app-jumps but the mic indicator stays on more.")
                }

                // 2. SPEECH — Whisper language + personal vocabulary
                Section {
                    Picker("Input language", selection: $whisperLanguage) {
                        Text("Auto detect").tag("")
                        Text("Chinese (handles mixed zh/en)").tag("zh")
                        Text("English only").tag("en")
                    }
                } header: {
                    Text("Speech recognition")
                } footer: {
                    Text("Whisper sometimes mis-detects Mandarin as Korean or Japanese. Pinning to Chinese fixes that — Chinese mode still handles mixed zh/en speech well.")
                }

                Section {
                    TextEditor(text: $personalVocab)
                        .frame(minHeight: 80)
                        .font(.callout)
                } header: {
                    Text("Personal vocabulary")
                } footer: {
                    Text("Names, jargon, or terms Whisper should expect. One per line or comma-separated. Added to Whisper's biasing prompt so these transcribe correctly even when spoken quickly. e.g. Tonecast, sync up, PR review.")
                }

                // 3. DEFAULTS — tone + translate
                Section {
                    Picker("Default tone", selection: $defaultTone) {
                        ForEach(Tone.allCases, id: \.rawValue) { t in
                            Text(t.displayName).tag(t.rawValue)
                        }
                    }
                    Picker("Default translate", selection: $defaultTranslate) {
                        ForEach(TranslateMode.allCases, id: \.rawValue) { m in
                            Text(m.displayName).tag(m.rawValue)
                        }
                    }
                } header: {
                    Text("Defaults")
                } footer: {
                    Text("Pre-selected when the keyboard appears. You can still change them per-recording.")
                }

                // 4. TONE STYLE GUIDES
                Section {
                    ForEach(Tone.allCases, id: \.rawValue) { t in
                        NavigationLink {
                            TonePromptEditorView(tone: t)
                        } label: {
                            HStack {
                                Text(t.displayName)
                                Spacer()
                                if SharedDefaults.customStyleGuide(for: t) != nil {
                                    Text("Custom")
                                        .font(.caption)
                                        .foregroundStyle(.tint)
                                } else {
                                    Text("Default")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Tone style guides")
                } footer: {
                    Text("Edit how each tone reshapes your dictation. The universal rules (never answer questions, only output the result, use 繁體中文 for Chinese) are locked and always applied.")
                }

                // 5. SUBSCRIPTION — Plus tier upgrade / status
                SubscriptionSection(showingPaywall: $showingPaywall)

                // 6. NETWORK — proxy-only (no toggle; informational)
                Section {
                    LabeledContent("Routing") {
                        Text("via proxy").foregroundStyle(.tint)
                    }
                    LabeledContent("Endpoint") {
                        Text(ProxyEndpointDefaults.baseURL.host ?? "—")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Network")
                } footer: {
                    Text("All OpenAI calls route through the proxy. No OpenAI key is bundled in the app any more — the key lives only in Cloudflare's secret store.")
                }

                // 6. ABOUT — collapsed by default
                Section {
                    DisclosureGroup(isExpanded: $showAboutDetails) {
                        LabeledContent("Bundle ID") {
                            Text("com.example.tonecast").font(.caption.monospaced())
                        }
                        LabeledContent("App Group") {
                            Text("group.com.example.tonecast").font(.caption.monospaced())
                        }
                        LabeledContent("Team ID") {
                            Text("XXXXXXXXXX").font(.caption.monospaced())
                        }
                    } label: {
                        Text("About")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        SharedDefaults.setFlowDurationMinutes(flowDuration)
                        SharedDefaults.setDefaultTone(defaultTone)
                        SharedDefaults.setDefaultTranslate(defaultTranslate)
                        SharedDefaults.setHoldToTalkMode(holdToTalk)
                        SharedDefaults.setWhisperLanguage(whisperLanguage)
                        SharedDefaults.setPersonalVocabulary(personalVocab)
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
