import SwiftUI

/// Per-tone style guide editor. The "Universal rules" (NEVER answer
/// questions, etc.) are intentionally not exposed — they're locked in
/// ToneRewriter.swift to prevent users from breaking the prompt.
///
/// The prompt body stays in English (GPT follows English instructions
/// most reliably and English is more token-efficient). To help a
/// Chinese-reading user, we show:
///   • a short 中文 description of what the tone is meant to feel like
///   • 3 worked examples (input → output) in 中文 so the user can
///     calibrate expectations before editing the rules
struct TonePromptEditorView: View {
    let tone: Tone

    @State private var draft: String = ""
    @State private var hasCustomValue: Bool = false
    @State private var temperature: Double = Tone.defaultTemperature
    @State private var hasCustomTemp: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            // 1. Chinese intent + samples — appears FIRST so the user
            //    sees expected output before editing the rules.
            Section {
                Text(tone.chineseDescription)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(.vertical, 2)
            } header: {
                Text("這個 tone 的感覺")
            }

            Section {
                ForEach(Array(tone.chineseSamples.enumerated()), id: \.offset) { _, pair in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(pair.input, systemImage: "mic.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                        Label(pair.output, systemImage: "arrow.turn.down.right")
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .labelStyle(.titleAndIcon)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("中文輸出範例")
            } footer: {
                Text("這些是用目前 prompt 套出來的典型輸出，讓你校準期待。")
            }

            // 2. Editable English prompt body.
            Section {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minHeight: 220)
            } header: {
                Text("Style guide (English)")
            } footer: {
                Text("Prompt 故意維持英文 — GPT 對英文指令最穩、token 也比較省。修改規則時請繼續用英文書寫；輸出仍然會是中文（或你說的語言）。Universal rules（不准回答問題、只輸出結果、中文一律繁體）會自動套用、不可編輯。")
            }

            // Temperature slider — controls how much the model is allowed
            // to deviate per tone. Sits between style guide and reset
            // buttons because it's a per-tone setting like the style guide.
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Creativity")
                            .font(.callout)
                        Spacer()
                        Text(String(format: "%.2f", temperature))
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                        if hasCustomTemp {
                            Text("custom")
                                .font(.caption)
                                .foregroundStyle(.tint)
                        }
                    }
                    Slider(value: $temperature, in: 0.0...1.0, step: 0.05) { editing in
                        if !editing { hasCustomTemp = true }
                    }
                    HStack {
                        Text("Verbatim")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("More creative")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    // Visible label of the current mode the slider is in.
                    // Verbatim mode is the only one that materially changes
                    // model behavior (injects a "bypass tone rules" header);
                    // the others are tighter/looser API temperatures.
                    HStack(spacing: 6) {
                        Image(systemName: faithfulnessIcon(for: temperature))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(faithfulnessColor(for: temperature))
                        Text(faithfulnessLabel(for: temperature))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(faithfulnessColor(for: temperature))
                    }
                    .padding(.top, 2)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Creativity")
            } footer: {
                Text("Below ~0.15 enters Verbatim mode — the model only removes obvious filler (嗯/uh/um) and skips list-conversion, smart-formatting, and tone-style changes. Above that, full tone-shifting applies with progressively more variation. Default \(String(format: "%.2f", Tone.defaultTemperature)).")
            }

            Section {
                Button {
                    draft = tone.defaultStyleGuide
                } label: {
                    Label("Restore default style guide", systemImage: "arrow.uturn.backward")
                }

                if hasCustomValue {
                    Button(role: .destructive) {
                        SharedDefaults.setCustomStyleGuide(nil, for: tone)
                        draft = tone.defaultStyleGuide
                        hasCustomValue = false
                    } label: {
                        Label("Forget custom style guide", systemImage: "trash")
                    }
                }

                if hasCustomTemp {
                    Button(role: .destructive) {
                        SharedDefaults.setCustomTemperature(nil, for: tone)
                        temperature = Tone.defaultTemperature
                        hasCustomTemp = false
                    } label: {
                        Label("Reset creativity to default", systemImage: "arrow.uturn.backward.circle")
                    }
                }
            } footer: {
                if hasCustomValue || hasCustomTemp {
                    Text("目前使用你自訂的設定。")
                } else {
                    Text("目前使用出廠預設值。")
                }
            }

            Section {
                DisclosureGroup("Preview factory default") {
                    Text(tone.defaultStyleGuide)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(tone.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty || trimmed == tone.defaultStyleGuide {
                        // Same as default → clear the override so we
                        // always use the latest factory value.
                        SharedDefaults.setCustomStyleGuide(nil, for: tone)
                    } else {
                        SharedDefaults.setCustomStyleGuide(trimmed, for: tone)
                    }
                    // Persist temperature only if it actually differs from
                    // the factory default — keeps SharedDefaults tidy and
                    // lets future default changes propagate to users who
                    // never touched the slider.
                    if hasCustomTemp && abs(temperature - Tone.defaultTemperature) > 0.001 {
                        SharedDefaults.setCustomTemperature(temperature, for: tone)
                    } else {
                        SharedDefaults.setCustomTemperature(nil, for: tone)
                    }
                    dismiss()
                }
            }
        }
        .onAppear {
            if let custom = SharedDefaults.customStyleGuide(for: tone) {
                draft = custom
                hasCustomValue = true
            } else {
                draft = tone.defaultStyleGuide
                hasCustomValue = false
            }
            if let customTemp = SharedDefaults.customTemperature(for: tone) {
                temperature = customTemp
                hasCustomTemp = true
            } else {
                temperature = Tone.defaultTemperature
                hasCustomTemp = false
            }
        }
    }

    /// Maps temperature value → faithfulness tier label shown under the slider.
    private func faithfulnessLabel(for t: Double) -> String {
        switch faithfulness(for: t) {
        case .verbatim:     return "Verbatim — only filler removed"
        case .conservative: return "Conservative — light tone-shifting"
        case .balanced:     return "Balanced (default)"
        case .expressive:   return "Expressive — more variation"
        }
    }

    private func faithfulnessIcon(for t: Double) -> String {
        switch faithfulness(for: t) {
        case .verbatim:     return "lock.fill"
        case .conservative: return "leaf.fill"
        case .balanced:     return "scalemass"
        case .expressive:   return "sparkles"
        }
    }

    private func faithfulnessColor(for t: Double) -> Color {
        switch faithfulness(for: t) {
        case .verbatim:     return .red
        case .conservative: return .green
        case .balanced:     return .secondary
        case .expressive:   return .purple
        }
    }

    private func faithfulness(for t: Double) -> Tone.FaithfulnessLevel {
        if t <= 0.15 { return .verbatim }
        if t <= 0.40 { return .conservative }
        if t <= 0.70 { return .balanced }
        return .expressive
    }
}

#Preview {
    NavigationStack {
        TonePromptEditorView(tone: .warm)
    }
}
