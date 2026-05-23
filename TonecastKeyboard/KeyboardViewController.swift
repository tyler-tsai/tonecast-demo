import UIKit

/// Tonecast keyboard. iOS forbids audio recording from extensions, so the
/// keyboard is a thin remote control: it tells the main app (alive in the
/// background via UIBackgroundModes audio) to start/stop/cancel recording,
/// and inserts the GPT-rewritten text via textDocumentProxy.
final class KeyboardViewController: UIInputViewController {

    // MARK: - System keyboard background match

    /// Match the iOS-drawn UIKeyboardDockView (the system strip at the
    /// bottom of custom keyboards that contains the globe + dictation
    /// mic). Sampled from the user's iOS 18 dark mode screenshot:
    ///   - Light: RGB(209, 213, 219) = #D1D5DB  (user-confirmed)
    ///   - Dark:  RGB(28, 28, 30)    = #1C1C1E
    ///
    /// History of failed attempts at the dark value:
    ///   - #212124 (custom)        — wrong shade
    ///   - #2C2C2E (systemGray5)   — too light
    ///   - #3A3A3C (systemGray4)   — too light
    ///   - .systemChromeMaterial   — still too light (material's dark
    ///                                variant is lighter than iOS's
    ///                                own dock chrome on iOS 18)
    /// The dock measures around #1C1C1E (equivalent to systemGray6 or
    /// secondarySystemBackground in dark mode) — visibly darker than
    /// any of the chrome materials, because iOS uses a separate
    /// internal colour for UIKeyboardDockView that isn't surfaced by
    /// any public material style.
    static let systemKeyboardBackgroundColor: UIColor = UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 28.0 / 255.0,
                           green: 28.0 / 255.0,
                           blue: 30.0 / 255.0,
                           alpha: 1.0)
        } else {
            return UIColor(red: 209.0 / 255.0,
                           green: 213.0 / 255.0,
                           blue: 219.0 / 255.0,
                           alpha: 1.0)
        }
    }

    // MARK: - Subviews
    private var toneSegment: UISegmentedControl!
    private var translateButton: UIButton!
    private var statusLabel: UILabel!
    private var micButton: CircularMicButton!
    /// While recording, the deleteButton morphs into a red Cancel button
    /// (xmark.circle.fill). When state leaves .recording it restores to
    /// the gray delete.backward icon. Tracked to avoid re-applying the
    /// same configuration on every 0.5s refreshState tick, which would
    /// re-trigger UIButton's internal layout pass.
    private enum DeleteButtonMode { case delete, cancel }
    private var deleteButtonMode: DeleteButtonMode = .delete

    // backgroundFill removed — the root view is now a UIInputView
    // with .keyboard style (see loadView()), which renders the system
    // keyboard chrome directly. No additional fill needed.

    private var nextKeyboardButton: UIButton!
    private var deleteButton: UIButton!
    private var sendButton: UIButton!   // submits the host app's text field (Return)
    private var editPill: UIButton!     // appears when selectedText is non-empty
    private var refineChipsStack: UIStackView!
    private var shorterChip: UIButton!
    private var longerChip: UIButton!
    private var polishChip: UIButton!
    private var toneChip: UIButton!
    private var undoChip: UIButton!
    private var retryChip: UIButton!
    /// Standalone pill (NOT in the chip row) that swaps the inserted text
    /// back to the raw Whisper transcript. Shares the editPill's slot — the
    /// two are mutually exclusive (selection mode vs post-recording mode).
    private var originalPill: UIButton!

    // MARK: - Timers
    private var statePollTimer: Timer?
    private var waveformPollTimer: Timer?
    private var deleteInitialDelayTimer: Timer?
    private var deleteRepeatTimer: Timer?
    private var deleteHoldStartedAt: Date?
    /// One-shot guard: while finger is dragging on delete, fire clearAll
    /// only once per drag — reset on gesture end.
    private var deleteDragClearedThisGesture: Bool = false

    // MARK: - Selections
    private var selectedTone: Tone = .casual
    private var selectedTranslate: TranslateMode = .off

    // MARK: - Refine state
    /// The most-recently-inserted result text. While this is non-empty AND
    /// the host app's cursor is still right after it, the quick-action chips
    /// are tappable (Shorter / Longer / Polish / Switch tone).
    private var lastInsertedText: String?
    private var lastInsertedTone: Tone?
    private var lastInsertedTranslate: TranslateMode?
    /// Raw Whisper transcript from the same recording — used by the "Use
    /// Original" chip to jump back to the unrewritten version. Cleared
    /// when refineHistory clears (Send / new recording / cursor anchor lost).
    private var lastInsertedOriginal: String?
    /// True while a chip-triggered refine is in flight (main app processing).
    private var isRefining: Bool = false
    /// Suppress duplicate "inserted" status logging when refreshState runs
    /// repeatedly with the same .done state.
    private var didInsertCurrentResult: Bool = false
    /// Stack of prior versions of `lastInsertedText`, oldest at index 0.
    /// Each refine pushes the previous version here; Undo pops + restores.
    /// Capped to prevent unbounded growth — three undos is plenty for the
    /// "I went too far, take me back one step" workflow.
    private var refineHistory: [String] = []
    private static let refineHistoryLimit = 3
    /// Cache key for the Tone chip menu — the tone rawValue the current
    /// menu was built for. Used to avoid re-assigning `toneChip.menu` on
    /// every state poll, which causes the open menu to flicker.
    private var builtToneMenuFor: Int?
    /// When the user taps a tone in the Tone chip's menu, we remember the
    /// target so we can update `lastInsertedTone` once the refine result
    /// arrives — otherwise the chip would keep showing the old tone and
    /// subsequent Shorter/Longer would preserve the wrong tone's rules.
    private var pendingToneSwitch: Tone?
    /// When a chip-refine targets the HOST APP'S CURRENT SELECTION (rather
    /// than the most-recently-inserted text), we remember the original
    /// selection text here. The result handler uses it to populate
    /// `refineHistory` for Undo and to log selection-aware status.
    /// `nil` means the in-flight refine targets `lastInsertedText` instead.
    private var pendingSelectionOriginal: String?

    // MARK: - Sticky error display
    /// When the main app reports `.error`, we capture the message here and
    /// keep showing it for `stickyErrorDuration` seconds even after we
    /// transition the session state back to `.idle`. Without this, the
    /// error appeared in statusLabel for one poll cycle (~0.5s) before
    /// being overwritten by the idle "Tap to record" text — too fast to
    /// read. Cleared when the user taps mic (starts a new action),
    /// when expiry passes, or when a new error replaces it.
    private var stickyErrorMessage: String?
    private var stickyErrorUntil: Date?
    private var stickyErrorHasRetry: Bool = false
    private static let stickyErrorDuration: TimeInterval = 6.0

    private func clearStickyError() {
        stickyErrorMessage = nil
        stickyErrorUntil = nil
        stickyErrorHasRetry = false
    }

    // MARK: - Haptics
    private let micHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let confirmHaptic = UINotificationFeedbackGenerator()
    private let cancelHaptic = UIImpactFeedbackGenerator(style: .rigid)

    // MARK: - Lifecycle

    override func loadView() {
        // Use UIInputView with .keyboard style as the root view — this
        // is the Apple-provided base class for keyboard extensions and
        // it automatically picks up iOS's exact keyboard chrome
        // (background blur, dark/light variants, True Tone, etc.) so
        // we never have to guess hex values. Previous attempts with
        // solid UIColor (#212124, #2C2C2E, #3A3A3C, #1C1C1E) and even
        // UIBlurEffect(.systemChromeMaterial) all visibly differed
        // from iOS's own keyboard. UIInputView is what Apple's own
        // keyboard renders on; the only way to truly match.
        let inputView = UIInputView(frame: CGRect(origin: .zero,
                                                  size: CGSize(width: 320, height: 332)),
                                    inputViewStyle: .keyboard)
        inputView.allowsSelfSizing = true
        self.view = inputView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NSLog("[Tonecast] keyboard viewDidLoad — hasFullAccess=%@", hasFullAccess ? "YES" : "NO")
        // Heartbeat for the main app's permission card. Updates the
        // "Keyboard added" + "Full Access" rows whenever this extension
        // is loaded — usually because the user just opened it in some
        // text field. Cheap (two UserDefaults writes) so we do it
        // unconditionally on every load.
        SharedDefaults.recordKeyboardHeartbeat(hasFullAccess: hasFullAccess)
        // No explicit backgroundFill — the root view is now a
        // UIInputView with .keyboard style (see loadView() above),
        // and iOS handles the chrome rendering automatically. Setting
        // a backgroundColor on top would obscure iOS's keyboard
        // appearance, which is exactly what we don't want.

        selectedTone = Tone(rawValue: SharedDefaults.defaultTone()) ?? .casual
        selectedTranslate = TranslateMode(rawValue: SharedDefaults.defaultTranslate()) ?? .off

        buildUI()
        refreshState()
        startPolling()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Refresh heartbeat — viewWillAppear fires every time the
        // keyboard comes up (e.g. user switches text fields), not just
        // on first load. Keeps the main app's status card current.
        SharedDefaults.recordKeyboardHeartbeat(hasFullAccess: hasFullAccess)
        selectedTone = Tone(rawValue: SharedDefaults.defaultTone()) ?? .casual
        selectedTranslate = TranslateMode(rawValue: SharedDefaults.defaultTranslate()) ?? .off
        toneSegment.selectedSegmentIndex = selectedTone.rawValue
        applyToneSegmentTint()
        applyTranslateButtonTitle()
        refreshState()
        startPolling()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshState()
        startPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Keep polling — extension process is long-lived; we want to detect
        // main-app state changes that arrive while keyboard is offscreen.
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        // Selection may have changed in the host app — refresh the edit pill.
        refreshSelectionState()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        refreshSelectionState()
    }

    // MARK: - UI

    private func buildUI() {
        // Tone segment (full width, hidden while recording)
        toneSegment = UISegmentedControl(items: Tone.allCases.map { $0.displayName })
        toneSegment.selectedSegmentIndex = selectedTone.rawValue
        toneSegment.addTarget(self, action: #selector(toneChanged), for: .valueChanged)
        toneSegment.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toneSegment)
        applyToneSegmentTint()

        // Compact translate button (top-right corner, hidden while recording)
        translateButton = UIButton(type: .system)
        var transConfig = UIButton.Configuration.tinted()
        transConfig.cornerStyle = .capsule
        transConfig.contentInsets = .init(top: 4, leading: 10, bottom: 4, trailing: 10)
        transConfig.titleTextAttributesTransformer = .init { container in
            var c = container; c.font = .systemFont(ofSize: 12, weight: .semibold); return c
        }
        translateButton.configuration = transConfig
        translateButton.changesSelectionAsPrimaryAction = false
        translateButton.showsMenuAsPrimaryAction = true
        translateButton.menu = buildTranslateMenu()
        translateButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(translateButton)
        applyTranslateButtonTitle()

        // Mic button (the hero)
        micButton = CircularMicButton()
        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.addTarget(self, action: #selector(micTouchUpInside), for: .touchUpInside)
        micButton.addTarget(self, action: #selector(micTouchDown), for: .touchDown)
        micButton.addTarget(self, action: #selector(micTouchUpOutside),
                            for: [.touchUpOutside, .touchCancel])
        view.addSubview(micButton)

        // Status label — fixed height so its 1-line vs 2-line difference
        // doesn't jitter the layout when state changes.
        statusLabel = UILabel()
        statusLabel.textAlignment = .center
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        // Edit-selection pill — shown above the status label when there is
        // selected text in the host app. Tap arms Speak-to-Edit mode: the
        // next mic recording becomes a voice COMMAND that GPT applies to
        // the selection rather than fresh dictation.
        editPill = UIButton(type: .system)
        var pillConfig = UIButton.Configuration.tinted()
        pillConfig.image = UIImage(systemName: "wand.and.stars",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        pillConfig.imagePadding = 6
        pillConfig.cornerStyle = .capsule
        pillConfig.baseForegroundColor = .systemPurple
        pillConfig.baseBackgroundColor = .systemPurple.withAlphaComponent(0.15)
        pillConfig.contentInsets = .init(top: 6, leading: 12, bottom: 6, trailing: 12)
        pillConfig.titleTextAttributesTransformer = .init { container in
            var c = container; c.font = .systemFont(ofSize: 12, weight: .semibold); return c
        }
        editPill.configuration = pillConfig
        editPill.isHidden = true
        editPill.addTarget(self, action: #selector(editPillTapped), for: .touchUpInside)
        editPill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editPill)

        // Use-original pill — shares the same slot as the edit pill (below
        // mic, centered) since the two modes are mutually exclusive. Shown
        // when a recent recording's raw transcript exists AND differs from
        // what's currently inserted AND we're not in selection mode. Teal
        // tint distinguishes it from the purple Speak-to-Edit pill.
        // Use-original pill — compact label that sits to the LEFT of the
        // mic (sharing the slot with the globe button — they're mutually
        // exclusive). The original placement below the mic was too
        // close to statusLabel; the two messages read as a single
        // crowded paragraph. Moving it to the mic's left band makes it
        // its own visual zone.
        //
        // Title trimmed from "Use original transcript" → "Original" so
        // the pill fits in the left margin (~114pt available).
        originalPill = UIButton(type: .system)
        var originalPillConfig = UIButton.Configuration.tinted()
        originalPillConfig.image = UIImage(systemName: "quote.bubble",
                                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        originalPillConfig.imagePadding = 4
        originalPillConfig.title = "Original"
        originalPillConfig.cornerStyle = .capsule
        originalPillConfig.baseForegroundColor = .systemTeal
        originalPillConfig.baseBackgroundColor = .systemTeal.withAlphaComponent(0.15)
        originalPillConfig.contentInsets = .init(top: 6, leading: 10, bottom: 6, trailing: 10)
        originalPillConfig.titleTextAttributesTransformer = .init { container in
            var c = container; c.font = .systemFont(ofSize: 12, weight: .semibold); return c
        }
        originalPill.configuration = originalPillConfig
        originalPill.isHidden = true
        originalPill.addTarget(self, action: #selector(originalTapped), for: .touchUpInside)
        originalPill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(originalPill)

        // Cancel button was removed — its job is now done by the
        // deleteButton, which morphs into a red Cancel during the
        // .recording state (see applyDeleteButtonMode). This collapses
        // a redundant control and removes a chunk of dead space below
        // statusLabel.

        // Globe — sits to the LEFT of the mic, restyled as a ~40pt round
        // helper button (was a tiny bottom-corner icon). Hidden when iOS
        // says the next-keyboard key isn't needed.
        nextKeyboardButton = UIButton(type: .system)
        nextKeyboardButton.configuration = roundHelperButtonConfig(
            symbol: "globe",
            tint: .secondaryLabel
        )
        nextKeyboardButton.addTarget(self,
                                     action: #selector(advanceToNextInputMode),
                                     for: .touchUpInside)
        let longPress = UILongPressGestureRecognizer(target: self,
                                                     action: #selector(showInputModeListGesture(_:)))
        longPress.minimumPressDuration = 0.4
        nextKeyboardButton.addGestureRecognizer(longPress)
        nextKeyboardButton.isHidden = !needsInputModeSwitchKey
        nextKeyboardButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nextKeyboardButton)

        // Delete — sits to the RIGHT of the mic. Hold-to-repeat (with
        // acceleration into word-delete after 1.5s) is still wired up.
        deleteButton = UIButton(type: .system)
        deleteButton.configuration = roundHelperButtonConfig(
            symbol: "delete.backward",
            tint: .secondaryLabel
        )
        deleteButton.addTarget(self, action: #selector(deleteTouchDown), for: .touchDown)
        deleteButton.addTarget(self, action: #selector(deleteTouchUp),
                               for: [.touchUpInside, .touchUpOutside, .touchCancel])
        // Press-and-drag-down → Clear All. cancelsTouchesInView=false so the
        // existing hold-to-repeat touch handlers above still fire normally;
        // the pan only fires once finger actually moves.
        let deletePan = UIPanGestureRecognizer(target: self, action: #selector(deletePanned(_:)))
        deletePan.cancelsTouchesInView = false
        deletePan.maximumNumberOfTouches = 1
        deleteButton.addGestureRecognizer(deletePan)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(deleteButton)

        // Refine chips — appear under the status label after a successful
        // insertion. Tap to transform the last-inserted text without
        // re-recording (Shorter / Longer / Polish / Switch tone).
        shorterChip = makeRefineChip(title: "Shorter", symbol: "arrow.down.right.and.arrow.up.left",
                                      action: #selector(shorterTapped))
        longerChip  = makeRefineChip(title: "Longer",  symbol: "arrow.up.left.and.arrow.down.right",
                                      action: #selector(longerTapped))
        polishChip  = makeRefineChip(title: "Polish",  symbol: "sparkles",
                                      action: #selector(polishTapped))
        toneChip    = makeRefineChip(title: "Tone",    symbol: "slider.horizontal.3",
                                      action: nil)
        // Tone uses a UIMenu of the other tones — populated lazily so we
        // always exclude the currently-applied tone.
        toneChip.showsMenuAsPrimaryAction = true
        // Undo — icon-only (text is redundant; the icon is universally
        // understood). Orange tint differentiates from forward-actions.
        // Only visible when refineHistory is non-empty.
        undoChip    = makeRefineChip(title: nil,       symbol: "arrow.uturn.backward",
                                      action: #selector(undoTapped))
        undoChip.tintColor = .systemOrange

        // Retry — only visible in error state when the kept audio file is
        // still retry-able. Tinted orange (kept distinct from forward-action
        // chips so the failure-mode escape hatch is obvious).
        retryChip   = makeRefineChip(title: "Retry",   symbol: "arrow.clockwise",
                                      action: #selector(retryTapped))
        retryChip.tintColor = .systemOrange

        // Six chips at fillEqually. Use-original lives OUTSIDE this row as
        // a standalone pill (see `originalPill` above) because squeezing
        // seven chips made the row visually overlap and hard to tap.
        refineChipsStack = UIStackView(arrangedSubviews: [shorterChip, longerChip, polishChip, toneChip, undoChip, retryChip])
        refineChipsStack.axis = .horizontal
        refineChipsStack.distribution = .fillEqually
        refineChipsStack.spacing = 4   // tightened from 6 to keep 5 chips on one line at fillEqually
        refineChipsStack.isHidden = true   // shown only when lastInsertedText non-empty
        refineChipsStack.translatesAutoresizingMaskIntoConstraints = false
        // Hard clip: even if a chip's intrinsic width briefly exceeds its
        // fillEqually slot during the show/hide animation, the rendering
        // stays inside the stack's bounds — no chip "pokes out" past the
        // trailing edge of the screen.
        refineChipsStack.clipsToBounds = true
        // Lower compression resistance on the row so the stack can squeeze
        // chips without anyone pushing back hard enough to extend past the
        // trailing constraint.
        refineChipsStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.addSubview(refineChipsStack)

        // Send — wide pill at the bottom of the keyboard. Inserts "\n" which
        // most chat apps (iMessage, WhatsApp, Telegram, Slack) treat as Send.
        // In note-style apps (Notes, email body) it falls back to a line break,
        // which is the expected Return-key behavior in those contexts too.
        sendButton = UIButton(type: .system)
        var sendConfig = UIButton.Configuration.filled()
        sendConfig.image = UIImage(systemName: "paperplane.fill",
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        sendConfig.imagePadding = 6
        sendConfig.title = "Send"
        sendConfig.baseForegroundColor = .white
        // Deep indigo — matches the app icon + mic idle disc brand color.
        sendConfig.baseBackgroundColor = UIColor(red: 0.30, green: 0.26, blue: 0.58, alpha: 1.0)
        sendConfig.cornerStyle = .capsule
        sendConfig.contentInsets = .init(top: 10, leading: 22, bottom: 10, trailing: 22)
        sendConfig.titleTextAttributesTransformer = .init { container in
            var c = container; c.font = .systemFont(ofSize: 15, weight: .semibold); return c
        }
        sendButton.configuration = sendConfig
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sendButton)

        // Keyboard height budget — was 358pt, now 294pt. The mic stays
        // at 140pt so its recording animation (radial waveform bars
        // extend up to radius 79 at max amplitude — 9pt outside the
        // view bounds) renders without clipping. The vertical gaps
        // above and below the mic are tuned to leave a 1-2pt clearance
        // from the bars at peak amplitude to neighboring UI: any tighter
        // and the bars would visually touch toneSegment / statusLabel.
        // Other savings vs. original:
        //   - mic ↓ status:           32 → 11pt   (was "中間文案間隔有點大")
        //   - top padding:            10 → 6pt
        //   - tone↓mic gap:           14 → 10pt
        //   - send height:            44 → 42pt
        //   - removed cancelButton:   ~32pt reclaimed below statusLabel —
        //     the deleteButton now doubles as Cancel during .recording
        //     (red xmark.circle.fill), so no second control needs a slot
        //     below the status text.
        //   - moved originalPill:     left-of-mic, sharing the globe's
        //     slot — no longer competing with statusLabel for the
        //     mic-bottom band.
        // statusLabel is the single shared slot for every status string
        // ("Tap to record" / "Recording…" / "Transcribing…" / error /
        // session countdown / sticky error). It swaps text in place,
        // not size, so this tighter band doesn't pinch any state.
        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: 294),

            // Tone segment full-width near top
            toneSegment.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            toneSegment.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            toneSegment.trailingAnchor.constraint(equalTo: translateButton.leadingAnchor, constant: -8),

            // Translate compact in top-right
            translateButton.centerYAnchor.constraint(equalTo: toneSegment.centerYAnchor),
            translateButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            translateButton.heightAnchor.constraint(equalToConstant: 32),

            // Mic button (hero) — 140pt is mandatory: CircularMicButton's
            // waveform bars draw at radius up to 79 from center (50 disc
            // + 8 inset + 21 max bar length at peak amplitude) and the
            // .recording pulse scales the disc 1.05×. Anything smaller
            // and the bars/pulse get clipped at the view bounds. Gap
            // above is 10pt — 9pt covers the bar overshoot at peak amp
            // + 1pt of visual safety; tighter than this and the bar
            // tips visually merge with toneSegment.
            micButton.topAnchor.constraint(equalTo: toneSegment.bottomAnchor, constant: 10),
            micButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            micButton.widthAnchor.constraint(equalToConstant: 140),
            micButton.heightAnchor.constraint(equalToConstant: 140),

            // Globe flanks the mic on the LEFT (hidden if !needsInputModeSwitchKey)
            nextKeyboardButton.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
            nextKeyboardButton.trailingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: -16),
            nextKeyboardButton.widthAnchor.constraint(equalToConstant: 40),
            nextKeyboardButton.heightAnchor.constraint(equalToConstant: 40),

            // Delete flanks the mic on the RIGHT
            deleteButton.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
            deleteButton.leadingAnchor.constraint(equalTo: micButton.trailingAnchor, constant: 16),
            deleteButton.widthAnchor.constraint(equalToConstant: 40),
            deleteButton.heightAnchor.constraint(equalToConstant: 40),

            // Edit-selection pill — sits in the TOP row, replacing the
            // tone segment + translate button while a selection is
            // active. The previous mic-bottom placement overlapped the
            // refine chip row when a chip-able result also existed,
            // and the area below the mic is already crowded by the
            // status label + chips. Up top there's whitespace and a
            // clear visual zone, and tone/translate aren't relevant
            // while the user is staging a voice-edit-on-selection.
            editPill.centerYAnchor.constraint(equalTo: toneSegment.centerYAnchor),
            editPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            editPill.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            editPill.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),

            // Use-original pill — sits to the LEFT of the mic, vertically
            // aligned with the mic's center. Shares this slot with the
            // globe button (nextKeyboardButton) — refreshChipsVisibility
            // hides the globe whenever originalPill is showing so they
            // never visually collide. This frees the mic-bottom area for
            // statusLabel alone, eliminating the two-message crowding.
            originalPill.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
            originalPill.trailingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: -12),
            originalPill.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 8),

            // Status label below mic — single-slot, swaps text per state.
            // 10pt gap above gives 1pt of visual clearance from the
            // recording bars' max-amplitude extent (9pt below mic
            // bounds). The bar tip at peak amp lands at the very top
            // edge of statusLabel's frame — but within the 2pt of
            // intrinsic top padding before the rendered text, so the
            // bar tick visually appears as part of the mic and never
            // touches the status glyphs.
            statusLabel.topAnchor.constraint(equalTo: micButton.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            // 20pt fits the single-line case at 13pt font (16pt rendered
            // line height) with 2pt of padding above + below — just
            // enough for the text not to look crushed. Two-line errors
            // truncate-by-tail; sticky-error hold (6s) lets the user
            // read long failures regardless of wrapping.
            statusLabel.heightAnchor.constraint(equalToConstant: 20),

            // Send button — pinned flush against the safe-area top edge.
            // No bottom padding: now that the keyboard background
            // matches the home-indicator strip exactly, the previous
            // 6pt gap was just dead same-color space. Flush placement
            // is safe — the safe-area inset already separates the
            // button's tap target from the actual indicator pill.
            // 40pt height stays at Apple's minimum tap-target spec.
            sendButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: 0),
            sendButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            sendButton.heightAnchor.constraint(equalToConstant: 40),
            sendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),

            // Refine chips — full width between status and Send. Compact
            // pill row; only shown when there's a recent result to operate on.
            refineChipsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            refineChipsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            refineChipsStack.bottomAnchor.constraint(equalTo: sendButton.topAnchor, constant: -8),
            refineChipsStack.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    /// Compact pill button factory for the refine chip row. Pass `title: nil`
    /// for an icon-only chip (no text, no image padding). Font + insets are
    /// tightened so 5 chips fit on iPhone without wrapping, even when the
    /// Tone label is the longest option ("Tactful").
    ///
    /// Icon-only chips get a beefier 16pt symbol so they read clearly as
    /// tappable controls without a text label — and so the visible tap
    /// target matches the chip's full hit area better.
    private func makeRefineChip(title: String?, symbol: String, action: Selector?) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.tinted()
        config.image = UIImage(systemName: symbol,
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: title == nil ? 16 : 10,
                                                                                 weight: .semibold))
        config.imagePadding = (title == nil) ? 0 : 3
        config.title = title
        config.baseForegroundColor = .label
        config.baseBackgroundColor = UIColor.systemFill
        config.cornerStyle = .capsule
        config.contentInsets = .init(top: 5, leading: 6, bottom: 5, trailing: 6)
        config.titleTextAttributesTransformer = .init { container in
            var c = container; c.font = .systemFont(ofSize: 11, weight: .medium); return c
        }
        button.configuration = config
        // Hard guarantee no line-wrap regardless of width pressure — clip
        // before wrapping. Combined with the tightened insets above this
        // keeps every chip on a single line at fillEqually distribution.
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        // Allow the chip to be compressed without pushing back against its
        // fillEqually allocation. Without this, a chip with a longer label
        // ("Tactful") might briefly extend past its slot during the show/hide
        // animation of a sibling chip (e.g. Undo appearing after a refine).
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.clipsToBounds = true
        if let action = action {
            button.addTarget(self, action: action, for: .touchUpInside)
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    // MARK: - Translate menu

    private func buildTranslateMenu() -> UIMenu {
        let actions = TranslateMode.allCases.map { mode in
            UIAction(
                title: mode.displayName,
                state: mode == self.selectedTranslate ? .on : .off
            ) { [weak self] _ in
                guard let self = self else { return }
                self.selectedTranslate = mode
                self.applyTranslateButtonTitle()
                self.translateButton.menu = self.buildTranslateMenu()
            }
        }
        return UIMenu(title: "Translate", children: actions)
    }

    private func applyTranslateButtonTitle() {
        var config = translateButton.configuration
        config?.image = nil
        switch selectedTranslate {
        case .off:
            config?.title = "Translate"
            config?.baseForegroundColor = .secondaryLabel
            config?.baseBackgroundColor = .quaternarySystemFill
            config?.titleTextAttributesTransformer = .init { container in
                var c = container; c.font = .systemFont(ofSize: 12, weight: .medium); return c
            }
        case .toEN, .toZH:
            // Active state — leading green dot + bold label, distinct tinted bg
            config?.title = (selectedTranslate == .toEN ? "EN" : "中")
            config?.image = UIImage(systemName: "circle.fill",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 6))?
                .withTintColor(.systemGreen, renderingMode: .alwaysOriginal)
            config?.imagePadding = 6
            config?.baseForegroundColor = .systemGreen
            config?.baseBackgroundColor = .systemGreen.withAlphaComponent(0.18)
            config?.titleTextAttributesTransformer = .init { container in
                var c = container; c.font = .systemFont(ofSize: 12, weight: .semibold); return c
            }
        }
        translateButton.configuration = config
    }

    // MARK: - Polling

    private func startPolling() {
        statePollTimer?.invalidate()
        statePollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshState()
            self?.consumeRefineResultIfReady()
        }
        waveformPollTimer?.invalidate()
        waveformPollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.refreshWaveform()
        }
    }

    /// Poll for a chip-triggered refine result. When the main app finishes
    /// the GPT transform, this picks it up, replaces the previously-inserted
    /// text in-place (or appends if the cursor anchor was lost), and brings
    /// the chips back up so the user can chain refinements.
    private func consumeRefineResultIfReady() {
        guard isRefining else { return }
        guard let newText = SharedDefaults.consumeRefineResult() else { return }
        NSLog("[Tonecast] refine result received (%d chars)", newText.count)
        applyRefineResult(newText)
    }

    private func refreshWaveform() {
        guard micButton.mode == .recording else { return }
        if let amp = SharedDefaults.currentAmplitude() {
            micButton.pushAmplitude(amp)
        } else {
            micButton.pushAmplitude(0)
        }
    }

    // MARK: - State refresh

    private var lastLoggedState: FlowSessionState?

    private func refreshState() {
        guard hasFullAccess else {
            statusLabel.attributedText = makeStatus(symbol: "exclamationmark.triangle.fill",
                                                     text: "Enable Full Access in Settings",
                                                     color: .systemOrange)
            micButton.isEnabled = false
            return
        }
        micButton.isEnabled = true
        refreshSelectionState()

        let state = SharedDefaults.sessionState()
        if state != lastLoggedState {
            NSLog("[Tonecast] refreshState — state transitioned to %@", state.rawValue)
            lastLoggedState = state
        }

        let isRecording = (state == .recording)
        let isBusy = isRecording || (state == .processing)

        // Selectors hide while recording — focus on the mic + waveform
        UIView.animate(withDuration: 0.2) {
            self.toneSegment.alpha = isRecording ? 0 : 1
            self.translateButton.alpha = isRecording ? 0 : 1
            // Send fades while busy so the mic stays the primary action.
            self.sendButton.alpha = isBusy ? 0.35 : 1.0
        }
        toneSegment.isUserInteractionEnabled = !isRecording
        translateButton.isUserInteractionEnabled = !isRecording
        sendButton.isUserInteractionEnabled = !isBusy

        // Morph the right-of-mic helper between Delete and Cancel.
        // During recording, the user's primary "I want out" action is
        // cancel — there is no text to delete with one hand on the
        // dictation. Reusing the slot avoids a second control sitting
        // below statusLabel taking up vertical space.
        applyDeleteButtonMode(isRecording ? .cancel : .delete)

        switch state {
        case .idle:
            micButton.mode = .idle
            // Sticky error takes priority over the regular idle status.
            // The .error branch below transitions session state to .idle
            // immediately after rendering the error, but stickyErrorUntil
            // keeps the message visible for several seconds. Once expired,
            // we fall through to the normal idle status.
            let stickyActive: Bool = {
                if let until = stickyErrorUntil, Date() < until { return true }
                if stickyErrorUntil != nil {
                    stickyErrorMessage = nil
                    stickyErrorUntil = nil
                    stickyErrorHasRetry = false
                }
                return false
            }()
            if stickyActive, let msg = stickyErrorMessage {
                statusLabel.attributedText = makeStatus(symbol: "exclamationmark.triangle.fill",
                                                         text: stickyErrorHasRetry ? "\(msg) · tap Retry" : msg,
                                                         color: .systemOrange)
            } else if SharedDefaults.editModeActive() {
                statusLabel.attributedText = makeStatus(symbol: "wand.and.stars",
                                                         text: "Edit armed — record your command",
                                                         color: .systemPurple)
            } else if (lastInsertedText?.isEmpty == false) ||
                       !(textDocumentProxy.selectedText ?? "").isEmpty {
                // Refine chips will be visible (we have a recent
                // insertion or a host-app selection). The chip row
                // already communicates "you have actions" — adding
                // "Tap to record" on top crowds the small slot. Leave
                // the status blank in that case; a fresh tap on the
                // mic re-engages recording and triggers a new label
                // state via the .recording branch above.
                statusLabel.attributedText = nil
            } else {
                let action = SharedDefaults.holdToTalkMode() ? "Hold to record" : "Tap to record"
                if SharedDefaults.flowSessionActive() {
                    // Session-ending-soon warning: when < 60s left, swap the
                    // soothing green dot for a yellow clock + remaining
                    // seconds. Gives the user a heads-up so they're not
                    // surprised when the next tap triggers a URL launch.
                    if let remaining = SharedDefaults.flowSessionTimeRemaining(),
                       remaining < 60 {
                        statusLabel.attributedText = makeStatus(symbol: "clock.fill",
                                                                 text: "\(action) · Session ends in \(Int(remaining))s",
                                                                 color: .systemYellow)
                    } else {
                        statusLabel.attributedText = makeStatus(symbol: "circle.fill",
                                                                 text: action,
                                                                 color: .systemGreen)
                    }
                } else {
                    statusLabel.attributedText = makeStatus(symbol: nil,
                                                             text: "\(action) — Tonecast app opens briefly the first time",
                                                             color: .secondaryLabel)
                }
            }

        case .recording:
            micButton.mode = .recording
            // New recording invalidates the previous result's cursor anchor.
            if didInsertCurrentResult || lastInsertedText != nil {
                didInsertCurrentResult = false
                clearRefineState()
            }
            // Starting a new recording = user has acknowledged any prior
            // error (or didn't care to). Drop the sticky so the status
            // line reflects the new in-progress action.
            clearStickyError()
            let hint = SharedDefaults.holdToTalkMode()
                ? "Hold · slide off mic to cancel"
                : "Recording · tap mic to send"
            statusLabel.attributedText = makeStatus(symbol: "waveform",
                                                     text: hint,
                                                     color: .systemRed)

        case .processing:
            micButton.mode = .processing
            // STUCK-STATE WATCHDOG. The recording service can legitimately
            // sit in .processing for up to ~30s (long recording + slow
            // network). After that, the most likely cause is the main app
            // got killed mid-process (flow session heartbeat dies first)
            // OR a connection hung past URLSession's timeouts and the
            // error path never fired. Surface as an error + retry context
            // so the user can either Retry or Cancel instead of staring
            // at "Transcribing…" indefinitely.
            let processingAge = SharedDefaults.sessionStateAge()
            let sessionDead = !SharedDefaults.flowSessionActive()
            if processingAge > 60 || (processingAge > 5 && sessionDead) {
                NSLog("[Tonecast] stuck-state watchdog: processing for %.1fs, sessionDead=%@",
                      processingAge, sessionDead ? "YES" : "NO")
                SharedDefaults.setError(sessionDead
                    ? "Background processing stopped unexpectedly — tap Retry to re-run"
                    : "Processing took too long — tap Retry to re-run")
                // Force the main app to clear the stuck state on its next poll.
                SharedDefaults.setSessionState(.error)
            } else {
                // No icon prefix — the mic button itself is the loading
                // indicator during processing (gray disc with a pulsing
                // 0.85↔0.55 opacity animation and the inner waveform
                // glyph). Adding an "ellipsis" SF Symbol next to the
                // text was stylistically inconsistent with the rest of
                // the keyboard's icon language (circle / clock / wave /
                // checkmark — none of them dot-style). Bare text plus
                // the live mic pulse reads as more refined.
                statusLabel.attributedText = makeStatus(symbol: nil,
                                                         text: "Transcribing & rewriting",
                                                         color: .systemOrange)
            }

        case .done:
            micButton.mode = .idle
            if didInsertCurrentResult {
                // Already inserted on a previous tick — guard against double-
                // inserts when the state poll re-fires before clearAll lands.
                break
            }
            if let result = SharedDefaults.peekResult() {
                NSLog("[Tonecast] inserting result (%d chars) into host app", result.text.count)
                textDocumentProxy.insertText(result.text)
                statusLabel.attributedText = makeStatus(symbol: "checkmark.circle.fill",
                                                         text: "Inserted \(result.text.count) chars · \(result.tone)",
                                                         color: .systemGreen)
                confirmHaptic.notificationOccurred(.success)
                // Remember what we just inserted so the chips can refine it.
                lastInsertedText = result.text
                lastInsertedTone = selectedTone
                lastInsertedTranslate = selectedTranslate
                // Capture the raw Whisper transcript too — the Use Original
                // chip uses it to swap back if the rewrite drifted.
                lastInsertedOriginal = result.original
                didInsertCurrentResult = true
            } else {
                statusLabel.attributedText = makeStatus(symbol: "checkmark",
                                                         text: "Done",
                                                         color: .systemGreen)
            }
            SharedDefaults.clearAll()

        case .error:
            micButton.mode = .idle
            let msg = SharedDefaults.peekError() ?? "Unknown error"
            NSLog("[Tonecast] error state: %@", msg)
            let hasRetry = SharedDefaults.peekRetryContext() != nil
            statusLabel.attributedText = makeStatus(symbol: "exclamationmark.triangle.fill",
                                                     text: hasRetry ? "\(msg) · tap Retry" : msg,
                                                     color: .systemOrange)
            // Stick the error to the screen for the next several seconds —
            // the .idle branch below will keep rendering this exact message
            // instead of "Tap to record" until stickyErrorUntil passes.
            // Without this, the next refreshState() poll (~0.5s later)
            // would silently overwrite the error and the user only sees
            // it flash by.
            stickyErrorMessage = msg
            stickyErrorHasRetry = hasRetry
            stickyErrorUntil = Date().addingTimeInterval(Self.stickyErrorDuration)
            // Wipe transient flags but PRESERVE retry context — clearAll()
            // would nuke kRetryAvailable too. Wipe each transient key
            // individually instead so the Retry chip stays valid.
            SharedDefaults.setSessionState(.idle)
            SharedDefaults.setStopRequested(false)
            SharedDefaults.setCancelRequested(false)
            SharedDefaults.clearError()
            // Refining failed → drop the chip-loading state but keep
            // lastInsertedText so the user can try a different chip.
            if isRefining {
                isRefining = false
                pendingToneSwitch = nil
                pendingSelectionOriginal = nil
            }
        }

        refreshChipsVisibility()
    }

    /// Build an attributed string of "[SF Symbol icon]  Text" with a unified
    /// tint colour. Used for all status messages so they share a consistent
    /// typographic identity (no emoji prefixes, proper SF Symbol weight).
    private func makeStatus(symbol: String?,
                            text: String,
                            color: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString()

        if let symbolName = symbol {
            let attachment = NSTextAttachment()
            let config = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            attachment.image = UIImage(systemName: symbolName, withConfiguration: config)?
                .withTintColor(color, renderingMode: .alwaysOriginal)
            // Nudge the icon down slightly so it visually aligns with text
            attachment.bounds = CGRect(x: 0, y: -2, width: 14, height: 14)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "  "))
        }

        result.append(NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: color,
        ]))
        return result
    }

    // MARK: - Actions

    @objc private func toneChanged() {
        selectedTone = Tone(rawValue: toneSegment.selectedSegmentIndex) ?? .casual
        applyToneSegmentTint()
    }

    /// Tint the currently-selected segment in a subtle colour matching
    /// the tone's personality, so the active selection is recognizable
    /// at a glance (pink warm / slate-blue formal / sage casual / teal tactful).
    private func applyToneSegmentTint() {
        toneSegment.selectedSegmentTintColor = tintForTone(selectedTone)
        // Make selected text white so it reads well against the tint
        toneSegment.setTitleTextAttributes(
            [.foregroundColor: UIColor.white,
             .font: UIFont.systemFont(ofSize: 13, weight: .semibold)],
            for: .selected
        )
        toneSegment.setTitleTextAttributes(
            [.foregroundColor: UIColor.label,
             .font: UIFont.systemFont(ofSize: 13, weight: .regular)],
            for: .normal
        )
    }

    /// Shared style for the small round helper buttons (globe + delete)
    /// that flank the mic. ~40pt circle, tinted SF Symbol.
    private func roundHelperButtonConfig(symbol: String, tint: UIColor) -> UIButton.Configuration {
        var config = UIButton.Configuration.tinted()
        config.image = UIImage(systemName: symbol,
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium))
        config.baseForegroundColor = tint
        config.baseBackgroundColor = UIColor.systemFill
        config.cornerStyle = .capsule
        config.contentInsets = .init(top: 10, leading: 10, bottom: 10, trailing: 10)
        return config
    }

    private func tintForTone(_ tone: Tone) -> UIColor {
        switch tone {
        case .warm:     return UIColor(red: 0.93, green: 0.40, blue: 0.55, alpha: 1.0)  // soft pink-red
        case .formal:   return UIColor(red: 0.33, green: 0.50, blue: 0.84, alpha: 1.0)  // slate blue
        case .casual:   return UIColor(red: 0.39, green: 0.72, blue: 0.50, alpha: 1.0)  // sage green
        case .tactful:  return UIColor(red: 0.36, green: 0.65, blue: 0.66, alpha: 1.0)  // soft teal
        case .plain:    return UIColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1.0)  // neutral gray — no styling
        }
    }

    /// Mic touchDown — only matters in hold-to-talk mode.
    @objc private func micTouchDown() {
        guard SharedDefaults.holdToTalkMode() else { return }
        let state = SharedDefaults.sessionState()
        guard state == .idle || state == .done || state == .error else { return }
        startRecordingHoldMode()
    }

    /// Mic released INSIDE the button.
    /// - Tap mode: toggle session (start or stop+process)
    /// - Hold mode: stop+process
    @objc private func micTouchUpInside() {
        if SharedDefaults.holdToTalkMode() {
            stopRecordingHoldMode()
        } else {
            toggleSession()
        }
    }

    /// Mic released OUTSIDE the button (or gesture cancelled).
    /// - Tap mode: ignore (no-op; cancel via cancel button)
    /// - Hold mode: CANCEL (Telegram-style "slide off to cancel")
    @objc private func micTouchUpOutside() {
        guard SharedDefaults.holdToTalkMode() else { return }
        let state = SharedDefaults.sessionState()
        guard state == .recording else { return }
        NSLog("[Tonecast] hold-to-talk SLIDE-OFF — cancelling")
        cancelHaptic.impactOccurred()
        SharedDefaults.setCancelRequested(true)
        statusLabel.text = "✕ Cancelled"
    }

    @objc private func editPillTapped() {
        guard let selection = textDocumentProxy.selectedText, !selection.isEmpty else {
            statusLabel.attributedText = makeStatus(symbol: "exclamationmark.triangle.fill",
                                                     text: "No text selected",
                                                     color: .systemOrange)
            return
        }
        if SharedDefaults.editModeActive() {
            // Already armed — tap again disarms
            SharedDefaults.clearEditMode()
            refreshSelectionState()
        } else {
            SharedDefaults.armEditMode(selectedText: selection)
            micHaptic.prepare()
            micHaptic.impactOccurred()
            refreshSelectionState()
        }
    }

    /// Update the edit pill's visibility/label based on whether the host
    /// app currently has a text selection, and whether edit mode is armed.
    private func refreshSelectionState() {
        let selection = textDocumentProxy.selectedText ?? ""
        let hasSelection = !selection.isEmpty
        let armed = SharedDefaults.editModeActive()

        editPill.isHidden = !hasSelection
        // editPill occupies the same top-row slot as the tone segment
        // and translate button. Hide those while the pill is up so the
        // top row stays readable as a single mode banner; restore when
        // the user deselects. Tone/translate aren't actionable on an
        // edit-the-selection turn anyway — the next recording is a
        // voice command, not a fresh dictation.
        toneSegment.isHidden = hasSelection
        translateButton.isHidden = hasSelection

        var config = editPill.configuration
        if armed {
            config?.title = "Speak the edit"
            config?.baseForegroundColor = .white
            config?.baseBackgroundColor = .systemPurple
        } else {
            let count = selection.count
            config?.title = count > 0 ? "Edit selection (\(count) chars)" : "Edit selection"
            config?.baseForegroundColor = .systemPurple
            config?.baseBackgroundColor = .systemPurple.withAlphaComponent(0.15)
        }
        editPill.configuration = config

        // Selection drives chip visibility too — refresh immediately so
        // chips appear the moment the user selects text, not on the next
        // 0.5s state poll tick.
        refreshChipsVisibility()
    }

    // cancelTapped removed — its job is now done by the deleteButton-
    // as-Cancel routing (see cancelRecordingFromDeleteSlot at the
    // bottom of the file). Keeping the implementation in one place
    // means there's no risk of the two paths drifting out of sync.

    /// Send — simulates pressing Return in the host app. In chat apps
    /// (iMessage, WhatsApp, Telegram, Slack) this submits the message;
    /// in note/email contexts it inserts a newline (the expected Return
    /// behavior). Disabled visually during recording/processing.
    @objc private func sendTapped() {
        let state = SharedDefaults.sessionState()
        guard state == .idle || state == .done || state == .error else {
            NSLog("[Tonecast] sendTapped ignored — state=%@", state.rawValue)
            return
        }
        NSLog("[Tonecast] sendTapped — inserting newline")
        micHaptic.prepare()
        micHaptic.impactOccurred()
        textDocumentProxy.insertText("\n")
        // The cursor is no longer immediately after lastInsertedText — chip
        // operations would mis-target. Clear the refine state.
        clearRefineState()
    }

    // MARK: - Refine chips

    @objc private func shorterTapped() { fireRefine(action: .shorter, label: "shorter") }
    @objc private func longerTapped()  { fireRefine(action: .longer,  label: "longer")  }
    @objc private func polishTapped()  { fireRefine(action: .polish,  label: "polish")  }

    /// Common path for the three text-only chips. The Tone chip uses its
    /// own UIMenu (built lazily in refreshChipsVisibility).
    ///
    /// Targeting precedence:
    ///   1. Host-app SELECTION (if non-empty) — refine the selected text,
    ///      result replaces the selection in-place via insertText.
    ///   2. Otherwise lastInsertedText — refine the most-recently-inserted
    ///      output (existing flow).
    private func fireRefine(action: RefineAction, label: String) {
        guard let target = resolveRefineTarget() else { return }
        guard SharedDefaults.flowSessionActive() else {
            statusLabel.attributedText = makeStatus(symbol: "exclamationmark.circle",
                                                     text: "Flow Session expired — record once to wake the app",
                                                     color: .systemOrange)
            return
        }
        NSLog("[Tonecast] refine %@ — selection=%@ chars=%d", label,
              target.isSelection ? "YES" : "NO", target.text.count)
        micHaptic.prepare()
        micHaptic.impactOccurred()
        isRefining = true
        pendingSelectionOriginal = target.isSelection ? target.text : nil
        refreshChipsVisibility()
        let scope = target.isSelection ? "selection" : label
        statusLabel.attributedText = makeStatus(symbol: "wand.and.stars",
                                                 text: target.isSelection
                                                    ? "Refining \(scope) (\(label))…"
                                                    : "Refining (\(label))…",
                                                 color: .systemPurple)
        SharedDefaults.setRefineRequest(action: action.rawValue,
                                          param: nil,
                                          inputText: target.text,
                                          sourceTone: target.tone.rawValue,
                                          sourceTranslate: target.translate.rawValue)
    }

    /// Resolve which piece of text the next refine should target, plus the
    /// tone + translate context to apply. Selection wins over lastInsertedText.
    private func resolveRefineTarget() -> (text: String, tone: Tone, translate: TranslateMode, isSelection: Bool)? {
        let selection = textDocumentProxy.selectedText ?? ""
        if !selection.isEmpty {
            // Selection mode — use the segmented control's currently-picked
            // tone, since selected text has no associated source tone.
            return (selection, selectedTone, selectedTranslate, true)
        }
        if let last = lastInsertedText, !last.isEmpty {
            return (last,
                    lastInsertedTone ?? selectedTone,
                    lastInsertedTranslate ?? selectedTranslate,
                    false)
        }
        return nil
    }

    /// Build the UIMenu for the Tone chip — lists every tone except the
    /// currently-applied one. Tapping an option fires a refine.
    private func buildToneRefineMenu() -> UIMenu {
        let current = lastInsertedTone ?? selectedTone
        let actions: [UIAction] = Tone.allCases
            .filter { $0 != current }
            .map { target in
                UIAction(title: target.displayName,
                         image: UIImage(systemName: "wand.and.stars")) { [weak self] _ in
                    self?.fireToneRefine(to: target)
                }
            }
        return UIMenu(title: "Switch tone to…", children: actions)
    }

    private func fireToneRefine(to target: Tone) {
        guard let resolved = resolveRefineTarget() else { return }
        guard SharedDefaults.flowSessionActive() else {
            statusLabel.attributedText = makeStatus(symbol: "exclamationmark.circle",
                                                     text: "Flow Session expired — record once to wake the app",
                                                     color: .systemOrange)
            return
        }
        NSLog("[Tonecast] refine tone → %@ (selection=%@)", target.displayName,
              resolved.isSelection ? "YES" : "NO")
        micHaptic.impactOccurred()
        isRefining = true
        pendingToneSwitch = target
        pendingSelectionOriginal = resolved.isSelection ? resolved.text : nil
        refreshChipsVisibility()
        statusLabel.attributedText = makeStatus(symbol: "wand.and.stars",
                                                 text: resolved.isSelection
                                                    ? "Refining selection (→ \(target.displayName))…"
                                                    : "Refining (→ \(target.displayName))…",
                                                 color: .systemPurple)
        SharedDefaults.setRefineRequest(action: RefineAction.tone.rawValue,
                                          param: String(target.rawValue),
                                          inputText: resolved.text,
                                          sourceTone: resolved.tone.rawValue,
                                          sourceTranslate: resolved.translate.rawValue)
    }

    /// Called from the poll loop when a refine result arrives. Replaces the
    /// previously-inserted text (default flow) OR the host app's current
    /// selection (when the refine was kicked off in selection mode).
    private func applyRefineResult(_ newText: String) {
        let isSelectionRefine = (pendingSelectionOriginal != nil)

        if let originalSelection = pendingSelectionOriginal {
            // SELECTION MODE — UIKit's insertText automatically replaces
            // any active selection in the host text field, so we don't
            // need deleteBackward. (If the user deselected during the
            // refine wait, the result is inserted at the cursor — minor
            // edge case, acceptable for personal-use v1.)
            NSLog("[Tonecast] refine result (selection mode): %d → %d chars",
                  originalSelection.count, newText.count)
            // A fresh selection refine starts a new undo chain — earlier
            // history (from prior dictation refines) is no longer
            // anchored to the cursor.
            refineHistory.removeAll()
            refineHistory.append(originalSelection)
            textDocumentProxy.insertText(newText)
        } else if let oldText = lastInsertedText, !oldText.isEmpty {
            // POST-INSERTION MODE — push prior version to undo stack and
            // safely replace the previously-inserted text in-place.
            pushUndoHistory(oldText)
            let before = textDocumentProxy.documentContextBeforeInput ?? ""
            if before.hasSuffix(oldText) {
                NSLog("[Tonecast] refine: replacing %d chars in-place", oldText.count)
                for _ in 0..<oldText.count {
                    textDocumentProxy.deleteBackward()
                }
                textDocumentProxy.insertText(newText)
            } else {
                NSLog("[Tonecast] refine: lost cursor anchor — appending instead")
                textDocumentProxy.insertText(newText)
            }
        } else {
            // No anchor at all — just insert.
            NSLog("[Tonecast] refine: no anchor, inserting fresh")
            textDocumentProxy.insertText(newText)
        }

        // Compute delta vs whichever source we operated on.
        let sourceLength = pendingSelectionOriginal?.count
            ?? (lastInsertedText?.count ?? newText.count)
        let delta = newText.count - sourceLength
        let deltaStr = delta == 0 ? "±0" : (delta > 0 ? "+\(delta)" : "\(delta)")

        lastInsertedText = newText
        pendingSelectionOriginal = nil

        // If this refine was a tone switch, commit the new tone — so the
        // Tone chip label updates AND subsequent Shorter/Longer/Polish
        // calls preserve the right tone's style guide.
        if let switched = pendingToneSwitch {
            NSLog("[Tonecast] tone switched to %@ — committing", switched.displayName)
            lastInsertedTone = switched
            pendingToneSwitch = nil
        } else if isSelectionRefine && lastInsertedTone == nil {
            // First time we've operated on this text — adopt the tone the
            // segmented control was on when the chip was tapped.
            lastInsertedTone = selectedTone
        }

        isRefining = false
        confirmHaptic.notificationOccurred(.success)
        let toneLabel = (lastInsertedTone ?? selectedTone).displayName
        let scopeLabel = isSelectionRefine ? "Selection refined" : "Refined"
        statusLabel.attributedText = makeStatus(symbol: "checkmark.circle.fill",
                                                 text: "\(scopeLabel) · \(sourceLength) → \(newText.count) chars (\(deltaStr)) · \(toneLabel)",
                                                 color: .systemGreen)
        refreshChipsVisibility()
    }

    /// Push `oldText` onto the refine undo stack, capped at `refineHistoryLimit`.
    /// Oldest entry is dropped when the cap is exceeded.
    private func pushUndoHistory(_ oldText: String) {
        refineHistory.append(oldText)
        if refineHistory.count > Self.refineHistoryLimit {
            refineHistory.removeFirst(refineHistory.count - Self.refineHistoryLimit)
        }
    }

    /// Use Original — replace whatever's currently inserted with the raw
    /// Whisper transcript from this recording. For when the tone rewrite
    /// drifted further from intent than wanted. Pushes the current version
    /// onto refineHistory so Undo can step back if the original isn't what
    /// the user wanted either.
    @objc private func originalTapped() {
        guard let original = lastInsertedOriginal, !original.isEmpty,
              let current = lastInsertedText, !current.isEmpty,
              original != current else { return }
        NSLog("[Tonecast] use-original tapped — restoring raw transcript (%d chars)",
              original.count)
        micHaptic.impactOccurred()

        pushUndoHistory(current)

        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        if before.hasSuffix(current) {
            for _ in 0..<current.count {
                textDocumentProxy.deleteBackward()
            }
            textDocumentProxy.insertText(original)
        } else {
            NSLog("[Tonecast] use-original: lost cursor anchor — appending")
            textDocumentProxy.insertText(original)
        }

        let delta = original.count - current.count
        let deltaStr = delta == 0 ? "±0" : (delta > 0 ? "+\(delta)" : "\(delta)")
        lastInsertedText = original
        confirmHaptic.notificationOccurred(.success)
        statusLabel.attributedText = makeStatus(symbol: "quote.bubble.fill",
                                                 text: "Reverted to original · \(current.count) → \(original.count) chars (\(deltaStr))",
                                                 color: .systemTeal)
        refreshChipsVisibility()
    }

    /// Retry — kick the main app to re-run Whisper + GPT against the audio
    /// file from the failed recording. The file lives in the shared app
    /// container until either a retry succeeds, a new recording starts, or
    /// the user sends.
    @objc private func retryTapped() {
        guard SharedDefaults.peekRetryContext() != nil else { return }
        NSLog("[Tonecast] retry tapped — flagging main app")
        micHaptic.impactOccurred()
        SharedDefaults.setRetryRequested(true)
        statusLabel.attributedText = makeStatus(symbol: "arrow.clockwise",
                                                 text: "Retrying…",
                                                 color: .systemPurple)
    }

    /// Undo — restore the most-recent pre-refine version of the text.
    /// Operates locally (no GPT call); just deletes the current version
    /// and reinserts the popped one.
    @objc private func undoTapped() {
        guard let previous = refineHistory.popLast() else { return }
        guard let current = lastInsertedText, !current.isEmpty else {
            // Lost the current anchor — just insert the previous text.
            textDocumentProxy.insertText(previous)
            lastInsertedText = previous
            refreshChipsVisibility()
            return
        }
        NSLog("[Tonecast] undo refine — restoring %d-char version", previous.count)
        micHaptic.impactOccurred()

        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        if before.hasSuffix(current) {
            for _ in 0..<current.count {
                textDocumentProxy.deleteBackward()
            }
            textDocumentProxy.insertText(previous)
        } else {
            NSLog("[Tonecast] undo: lost cursor anchor — appending instead")
            textDocumentProxy.insertText(previous)
        }

        lastInsertedText = previous
        statusLabel.attributedText = makeStatus(symbol: "arrow.uturn.backward",
                                                 text: "Undone · back to \(previous.count) chars",
                                                 color: .systemOrange)
        refreshChipsVisibility()
    }

    /// Re-evaluate whether the chip row should be visible + enabled. Called
    /// from refreshState() and after any refine state change.
    private func refreshChipsVisibility() {
        // CURSOR ANCHOR CHECK — if lastInsertedText exists but the cursor is
        // no longer right after it (user sent the message via the host app's
        // own button, typed more, deleted it, moved the cursor), the chips
        // would mis-target. Drop the context so they hide.
        //
        // Tail comparison (last 50 chars) keeps very long results valid even
        // when Apple truncates documentContextBeforeInput.
        if let last = lastInsertedText, !last.isEmpty {
            let before = textDocumentProxy.documentContextBeforeInput ?? ""
            let checkLen = min(last.count, 50)
            let lastTail = String(last.suffix(checkLen))
            if !before.hasSuffix(lastTail) {
                NSLog("[Tonecast] chips: cursor anchor lost (host app sent / user typed) — clearing")
                lastInsertedText = nil
                lastInsertedTone = nil
                lastInsertedTranslate = nil
                lastInsertedOriginal = nil
                pendingToneSwitch = nil
                pendingSelectionOriginal = nil
                refineHistory.removeAll()
            }
        }

        let state = SharedDefaults.sessionState()
        let isBusy = (state == .recording) || (state == .processing)
        let hasResult = (lastInsertedText?.isEmpty == false)
        let hasSelection = !(textDocumentProxy.selectedText ?? "").isEmpty
        let hasRetry = (state == .error) && (SharedDefaults.peekRetryContext() != nil)
        // Chips operate on EITHER the last-inserted text, the current host-app
        // selection, OR retry context. Show whenever at least one is available.
        let shouldShow = (hasResult || hasSelection || hasRetry) && !isBusy

        // Use-original pill visibility (standalone — NOT in the chip row).
        // Shows when a raw transcript exists, differs from what's currently
        // inserted, no selection (selection mode owns the same UI slot via
        // editPill), and we're not in retry/recording/processing.
        let canUseOriginal: Bool = {
            guard let raw = lastInsertedOriginal, !raw.isEmpty else { return false }
            guard let current = lastInsertedText, !current.isEmpty else { return false }
            return raw != current && !hasSelection && !isBusy && !hasRetry
        }()
        originalPill.isHidden = !canUseOriginal
        // Globe + originalPill share the slot to the left of the mic.
        // When the Original pill is up, the globe button hides to avoid
        // overlap. The user can still switch keyboards via long-press
        // on the globe in the system bar; once they tap Original (or
        // start a new recording) the pill goes away and the globe
        // returns automatically on the next refreshChipsVisibility.
        let globeWanted = needsInputModeSwitchKey && !canUseOriginal
        if nextKeyboardButton.isHidden == globeWanted {
            nextKeyboardButton.isHidden = !globeWanted
        }

        UIView.animate(withDuration: 0.15) {
            self.refineChipsStack.alpha = self.isRefining ? 0.4 : 1.0
            self.refineChipsStack.isHidden = !shouldShow
            self.shorterChip.isHidden = hasRetry && !hasResult && !hasSelection
            self.longerChip.isHidden  = hasRetry && !hasResult && !hasSelection
            self.polishChip.isHidden  = hasRetry && !hasResult && !hasSelection
            self.toneChip.isHidden    = hasRetry && !hasResult && !hasSelection
            self.undoChip.isHidden    = self.refineHistory.isEmpty
            self.retryChip.isHidden   = !hasRetry
            // Force a layout pass INSIDE the animation block. Without this,
            // UIStackView's fillEqually recomputation can land between the
            // animation start/end with chips briefly sized for the wrong
            // visible count — causing the newly-appearing chip (e.g. Undo
            // after a refine) to render outside the trailing edge.
            self.refineChipsStack.layoutIfNeeded()
        }
        refineChipsStack.isUserInteractionEnabled = shouldShow && !isRefining

        // Refresh the Tone chip's title + menu ONLY when the current tone
        // changes (or on the first show). The state poll runs every 0.5s —
        // re-assigning these on every tick would flicker the open menu and
        // jitter the chip's label layout. Cached by current tone's rawValue.
        if shouldShow {
            let currentTone = lastInsertedTone ?? selectedTone
            let currentKey = currentTone.rawValue
            if builtToneMenuFor != currentKey {
                toneChip.menu = buildToneRefineMenu()
                // Title doubles as a "currently in X tone" indicator.
                var config = toneChip.configuration
                config?.title = currentTone.displayName
                toneChip.configuration = config
                builtToneMenuFor = currentKey
            }
        } else {
            // When chips hide, forget the cache so the next show rebuilds.
            builtToneMenuFor = nil
        }
    }

    /// Forget the last insertion — called when the user does something that
    /// breaks the cursor anchor (sends, starts a new recording).
    private func clearRefineState() {
        lastInsertedText = nil
        lastInsertedTone = nil
        lastInsertedTranslate = nil
        lastInsertedOriginal = nil
        isRefining = false
        pendingToneSwitch = nil
        pendingSelectionOriginal = nil
        refineHistory.removeAll()
        refreshChipsVisibility()
    }

    private func startRecordingHoldMode() {
        guard hasFullAccess else {
            statusLabel.text = "⚠️ Enable Full Access in Settings"
            confirmHaptic.notificationOccurred(.warning)
            return
        }
        micHaptic.prepare()
        micHaptic.impactOccurred()

        SharedDefaults.clearAll()
        if SharedDefaults.flowSessionActive() {
            NSLog("[Tonecast] hold-to-talk start (flow active)")
            SharedDefaults.setStartRequested(tone: selectedTone.rawValue,
                                             translate: selectedTranslate.rawValue)
        } else {
            NSLog("[Tonecast] hold-to-talk start (cold) — opening URL")
            let urlStr = "tonecast://record-start?tone=\(selectedTone.rawValue)&translate=\(selectedTranslate.rawValue)"
            openURL(urlStr)
        }
    }

    private func stopRecordingHoldMode() {
        let state = SharedDefaults.sessionState()
        guard state == .recording else { return }
        NSLog("[Tonecast] hold-to-talk release inside — stop+process")
        SharedDefaults.setStopRequested(true)
    }

    @objc private func toggleSession() {
        let state = SharedDefaults.sessionState()
        let flowActive = SharedDefaults.flowSessionActive()
        NSLog("[Tonecast] toggleSession — state=%@ flowActive=%@",
              state.rawValue, flowActive ? "YES" : "NO")

        guard hasFullAccess else {
            statusLabel.text = "⚠️ Enable Full Access in Settings"
            confirmHaptic.notificationOccurred(.warning)
            return
        }

        micHaptic.prepare()
        micHaptic.impactOccurred()

        switch state {
        case .idle, .done, .error:
            SharedDefaults.clearAll()
            if flowActive {
                NSLog("[Tonecast] start within active Flow Session — no app jump")
                SharedDefaults.setStartRequested(tone: selectedTone.rawValue,
                                                 translate: selectedTranslate.rawValue)
            } else {
                NSLog("[Tonecast] no Flow Session — opening URL to launch")
                let urlStr = "tonecast://record-start?tone=\(selectedTone.rawValue)&translate=\(selectedTranslate.rawValue)"
                openURL(urlStr)
            }

        case .recording:
            NSLog("[Tonecast] tap-to-stop — flipping stop_requested flag")
            SharedDefaults.setStopRequested(true)
            statusLabel.text = "⌛ Stopping…"

        case .processing:
            return
        }
    }

    // MARK: - URL opening (keyboard → main app)

    private func openURL(_ urlString: String) {
        NSLog("[Tonecast] openURL %@", urlString)
        guard let url = URL(string: urlString) else { return }

        if let ctx = self.extensionContext {
            ctx.open(url, completionHandler: { success in
                NSLog("[Tonecast] extensionContext.open success=%@", success ? "YES" : "NO")
                if !success {
                    DispatchQueue.main.async { self.openURLViaResponderChain(url) }
                }
            })
            return
        }
        openURLViaResponderChain(url)
    }

    private func openURLViaResponderChain(_ url: URL) {
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                NSLog("[Tonecast] openURL via UIApplication.open (fallback)")
                app.open(url, options: [:]) { success in
                    NSLog("[Tonecast] open completion success=%@", success ? "YES" : "NO")
                }
                return
            }
            responder = r.next
        }
    }

    @objc private func showInputModeListGesture(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        handleInputModeList(from: nextKeyboardButton, with: UIEvent())
    }

    // MARK: - Delete (hold-to-repeat with acceleration)

    @objc private func deleteTouchDown() {
        // During recording the button is acting as Cancel — fire that
        // path instead of starting a delete cascade. Touch-up will see
        // sessionState != .recording (we just transitioned out) so it's
        // a no-op.
        if SharedDefaults.sessionState() == .recording {
            cancelRecordingFromDeleteSlot()
            return
        }
        // Immediate single delete on press
        textDocumentProxy.deleteBackward()
        deleteHoldStartedAt = Date()

        // After 400ms of holding, start fast char-delete; after 1.5s, accelerate
        // again and start removing whole words instead of single chars.
        deleteInitialDelayTimer?.invalidate()
        deleteInitialDelayTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.beginRepeatingDelete()
        }
    }

    @objc private func deleteTouchUp() {
        cancelDeleteTimers()
    }

    /// Cancel-from-delete-slot — same effect as the old standalone
    /// cancelButton, kept as a separate selector so logs and intent
    /// stay clear (the delete handler routes to here when recording).
    private func cancelRecordingFromDeleteSlot() {
        NSLog("[Tonecast] cancel tapped (from delete slot)")
        cancelHaptic.prepare()
        cancelHaptic.impactOccurred()
        SharedDefaults.setCancelRequested(true)
        statusLabel.text = "✕ Cancelled"
    }

    /// Swap the deleteButton's appearance between its two roles.
    /// Idempotent — bails when the mode is already current, so the
    /// 0.5s refreshState tick doesn't keep recreating the UIButton's
    /// configuration (which would otherwise restart its internal
    /// background-color animation on every tick).
    private func applyDeleteButtonMode(_ mode: DeleteButtonMode) {
        guard deleteButtonMode != mode else { return }
        deleteButtonMode = mode
        switch mode {
        case .delete:
            deleteButton.configuration = roundHelperButtonConfig(
                symbol: "delete.backward",
                tint: .secondaryLabel
            )
        case .cancel:
            // xmark.circle.fill in systemRed + a faint red tint behind
            // the icon. Distinct enough from the gray delete-backward
            // that a glance at the keyboard while recording tells the
            // user "this is the abort, not a backspace".
            var config = roundHelperButtonConfig(
                symbol: "xmark.circle.fill",
                tint: .systemRed
            )
            config.background.backgroundColor = UIColor.systemRed.withAlphaComponent(0.12)
            deleteButton.configuration = config
            // Cancel any in-flight repeat-delete cascade — if the user
            // started holding delete and then the host triggered a
            // recording start mid-hold, we don't want the cascade
            // continuing in the background.
            cancelDeleteTimers()
        }
    }

    private func beginRepeatingDelete() {
        // Phase 1: rapid single-char delete at 8Hz
        deleteRepeatTimer?.invalidate()
        deleteRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Phase 2 kicks in once the user has been holding for ~1.5s total
            let held = Date().timeIntervalSince(self.deleteHoldStartedAt ?? .init())
            if held > 1.5 {
                self.deleteWordBackward()
            } else {
                self.textDocumentProxy.deleteBackward()
            }
        }
        if let timer = deleteRepeatTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    private func cancelDeleteTimers() {
        deleteInitialDelayTimer?.invalidate()
        deleteInitialDelayTimer = nil
        deleteRepeatTimer?.invalidate()
        deleteRepeatTimer = nil
        deleteHoldStartedAt = nil
    }

    /// Press-and-drag-down on the delete button → clear ALL text in the
    /// host field. Threshold 30pt of downward translation. Visual feedback
    /// scales the icon + tints it red as the drag progresses past 10pt.
    @objc private func deletePanned(_ gesture: UIPanGestureRecognizer) {
        // Drag-down-to-clear-all is suppressed while the button is
        // acting as Cancel during recording — a drag while a recording
        // is live shouldn't nuke the host field's content.
        if deleteButtonMode == .cancel { return }
        let translation = gesture.translation(in: deleteButton)
        switch gesture.state {
        case .began:
            deleteDragClearedThisGesture = false

        case .changed:
            let dy = max(0, translation.y)
            if dy < 10 {
                applyDeleteDragTransform(progress: 0)
            } else if dy < 30 && !deleteDragClearedThisGesture {
                let progress = min(1, (dy - 10) / 20)
                applyDeleteDragTransform(progress: progress)
            } else if !deleteDragClearedThisGesture {
                deleteDragClearedThisGesture = true
                applyDeleteDragTransform(progress: 1)
                triggerClearAll()
            }

        case .ended, .cancelled, .failed:
            UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
                self.applyDeleteDragTransform(progress: 0)
            }
            deleteDragClearedThisGesture = false

        default:
            break
        }
    }

    /// Visual feedback during the drag-to-clear-all gesture. `progress` is
    /// 0…1 — 0 = neutral, 1 = threshold reached.
    private func applyDeleteDragTransform(progress: CGFloat) {
        let scale = 1.0 + (0.25 * progress)
        deleteButton.transform = CGAffineTransform(scaleX: scale, y: scale)
        if var config = deleteButton.configuration {
            let interp: UIColor = progress < 0.05
                ? .secondaryLabel
                : UIColor.systemRed.withAlphaComponent(0.6 + 0.4 * progress)
            config.baseForegroundColor = interp
            deleteButton.configuration = config
        }
    }

    /// Clear ALL text in the host app's field — both before and after the
    /// cursor. Iterative deleteBackward because Apple caps documentContext*
    /// at ~1000 chars; loop with a safety limit so we don't spin forever
    /// on weird host apps that don't actually delete.
    private func triggerClearAll() {
        NSLog("[Tonecast] clear-all gesture triggered")
        cancelDeleteTimers()
        let heavy = UIImpactFeedbackGenerator(style: .heavy)
        heavy.prepare()
        heavy.impactOccurred()

        var pass = 0
        while let before = textDocumentProxy.documentContextBeforeInput,
              !before.isEmpty,
              pass < 50 {
            for _ in 0..<before.count {
                textDocumentProxy.deleteBackward()
            }
            pass += 1
        }
        pass = 0
        while let after = textDocumentProxy.documentContextAfterInput,
              !after.isEmpty,
              pass < 50 {
            let n = after.count
            textDocumentProxy.adjustTextPosition(byCharacterOffset: n)
            for _ in 0..<n {
                textDocumentProxy.deleteBackward()
            }
            pass += 1
        }

        statusLabel.attributedText = makeStatus(symbol: "trash.fill",
                                                 text: "Cleared",
                                                 color: .systemRed)
        clearRefineState()
    }

    /// Delete the previous word — back to (and including) the most recent
    /// whitespace separator. If no whitespace exists, delete back to the
    /// start of the context.
    private func deleteWordBackward() {
        guard let ctx = textDocumentProxy.documentContextBeforeInput, !ctx.isEmpty else { return }

        // Walk back from the end:
        // 1. Skip trailing whitespace
        // 2. Then delete characters until we hit whitespace again
        let chars = Array(ctx)
        var i = chars.count - 1
        while i >= 0, chars[i].isWhitespace { i -= 1 }
        while i >= 0, !chars[i].isWhitespace { i -= 1 }

        let charsToDelete = chars.count - (i + 1)
        for _ in 0..<max(charsToDelete, 1) {
            textDocumentProxy.deleteBackward()
        }
    }
}
