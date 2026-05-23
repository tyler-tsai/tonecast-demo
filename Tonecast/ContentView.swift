import SwiftUI
import AVFoundation

struct ContentView: View {
    // Removed showRecording binding — RecordingView has been deleted.
    // (Keep the parameter so TonecastApp doesn't have to change shape.)
    @Binding var showRecording: Bool

    @State private var flowActive = false
    @State private var flowDurationMinutes = 15
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showSetupGuide = false
    @State private var pollTimer: Timer?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    PermissionStatusView()
                    flowSessionCard
                    Spacer(minLength: 8)
                    bottomLinks
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
            .navigationTitle("Tonecast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: refreshAll) {
                SettingsView()
            }
            .sheet(isPresented: $showHistory) {
                HistoryView()
            }
            .sheet(isPresented: $showSetupGuide, onDismiss: refreshAll) {
                SetupGuideView(isFirstLaunch: !SharedDefaults.hasSeenSetupGuide())
            }
        }
        .onAppear {
            refreshAll()
            startPolling()
            // Pre-request mic permission on first appearance. Before this,
            // the user would only hit the system prompt the moment they
            // tapped "Start Flow Session" — and if they missed/dismissed
            // it the button looked broken. PermissionStatusView also
            // exposes an "Allow" CTA for the same purpose, but kicking
            // the prompt off proactively makes the happy path one fewer
            // tap. Idempotent: iOS only shows the prompt while status
            // is .undetermined; otherwise this completes silently.
            if AVAudioApplication.shared.recordPermission == .undetermined {
                AVAudioApplication.requestRecordPermission { _ in }
            }
            if !SharedDefaults.hasSeenSetupGuide() {
                // First launch — auto-present the guide
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showSetupGuide = true
                }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tonecast")
                .font(.largeTitle.bold())
            Text("Personal voice keyboard with tone shift and zh⇄en translation.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var flowSessionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(flowActive ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(flowActive ? Color.green.opacity(0.4) : Color.clear, lineWidth: 4)
                            .scaleEffect(flowActive ? 1.8 : 1.0)
                            .opacity(flowActive ? 0.6 : 0)
                    )
                Text(flowActive ? "Flow Session active" : "Flow Session inactive")
                    .font(.headline)
                    .foregroundStyle(flowActive ? Color.green : Color.secondary)
                Spacer()
            }

            Text(flowActive
                 ? "Keyboard records without opening this app. Auto-expires after \(flowDurationMinutes) minutes idle."
                 : "Pre-activate the session so the keyboard records without an app switch. Otherwise the first tap from the keyboard will briefly open this app.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                activateFlowSessionManually()
            } label: {
                HStack {
                    Image(systemName: flowActive ? "checkmark.circle.fill" : "mic.fill")
                    Text(flowActive
                         ? "Flow Session running"
                         : "Start Flow Session (\(flowDurationMinutes) min)")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(flowActive ? Color.green : Color.accentColor)
                .foregroundStyle(.white)
                .cornerRadius(14)
            }
            .disabled(flowActive)

            if flowActive {
                Button {
                    endFlowSessionManually()
                } label: {
                    Text("End session now")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
        .animation(.easeInOut(duration: 0.4), value: flowActive)
    }

    /// Small secondary links at the bottom — replaces the verbose setup +
    /// "why this opens" blocks. Tap to open the full setup guide modally.
    private var bottomLinks: some View {
        VStack(spacing: 12) {
            Button {
                showSetupGuide = true
            } label: {
                Label("How Tonecast works", systemImage: "info.circle")
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 12)
    }

    // MARK: - Actions

    private func activateFlowSessionManually() {
        NSLog("[Tonecast/main] manual Start Flow Session tapped")
        let tone = Tone(rawValue: SharedDefaults.defaultTone()) ?? .casual
        let translate = TranslateMode(rawValue: SharedDefaults.defaultTranslate()) ?? .off
        RecordingService.shared.startFlowSession(tone: tone, translate: translate)
        // Cancel (discard, no Whisper/GPT roundtrip) the capture that
        // startFlowSession kicks off — we only want the session alive,
        // not actively recording until the keyboard taps mic.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            SharedDefaults.setCancelRequested(true)
        }
        refreshAll()
    }

    private func endFlowSessionManually() {
        NSLog("[Tonecast/main] manual End Flow Session tapped")
        RecordingService.shared.expireFlowSession()
        refreshAll()
    }

    private func refreshAll() {
        flowActive = SharedDefaults.flowSessionActive()
        flowDurationMinutes = SharedDefaults.flowDurationMinutes()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            refreshAll()
        }
    }
}

#Preview {
    ContentView(showRecording: .constant(false))
}
