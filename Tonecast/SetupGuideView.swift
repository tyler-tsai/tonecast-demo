import SwiftUI

/// One-shot guide explaining how Tonecast works on iOS. Shown
/// automatically on first launch (gated by SharedDefaults.hasSeenSetupGuide)
/// and accessible later from the gear icon → "How it works".
struct SetupGuideView: View {
    @Environment(\.dismiss) private var dismiss
    let isFirstLaunch: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    hero
                    steps
                    explanation
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle("How Tonecast works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isFirstLaunch ? "Got it" : "Done") {
                        SharedDefaults.markSetupGuideSeen()
                        dismiss()
                    }
                }
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Voice keyboard with tone shift")
                .font(.title.bold())
            Text("Dictate in any app. Tonecast polishes your speech in the tone you pick.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Setup")
                .font(.title3.bold())

            SetupStep(
                number: "1",
                title: "Enable the keyboard",
                instructions: "Settings → General → Keyboard → Keyboards → Add New Keyboard → Tonecast"
            )
            SetupStep(
                number: "2",
                title: "Allow Full Access",
                instructions: "Settings → General → Keyboard → Keyboards → Tonecast → toggle Allow Full Access ON. This is required so the keyboard can hand recordings to this app."
            )
            SetupStep(
                number: "3",
                title: "Use it",
                instructions: "In any app, switch to the Tonecast keyboard. Tap 🎤 to record. The first tap briefly opens this app to activate a Flow Session; subsequent recordings stay in the keyboard for the next 15 minutes."
            )
            SetupStep(
                number: "4 (optional)",
                title: "Hide iOS's dictation mic",
                instructions: "iOS adds its own dictation mic at the bottom-right of every keyboard — including Tonecast. Custom keyboards can't hide it via API (Apple framework limit). To remove it: Settings → General → Keyboard → toggle Enable Dictation OFF. You'll lose iOS-system dictation everywhere, but Tonecast's own mic still works."
            )
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Why the first tap opens this app", systemImage: "info.circle.fill")
                .font(.headline)
                .foregroundStyle(.tint)

            Text("iOS forbids keyboard extensions from recording audio directly. Tonecast's main app does the recording in the background. The first tap from the keyboard briefly opens this app to activate that background recording session.\n\nWispr Flow and Typeless work the same way — Apple's keyboard sandbox makes this unavoidable. After activation, the keyboard can start/stop recordings on its own for the duration of the Flow Session.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SetupStep: View {
    let number: String
    let title: String
    let instructions: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.headline)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(instructions).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    SetupGuideView(isFirstLaunch: true)
}
