import UIKit
import os

final class KeyboardViewController: UIInputViewController, UIInputViewAudioFeedback {
    /// Lifecycle telemetry so the running extension can be observed on the
    /// Simulator via: `xcrun simctl spawn booted log stream --predicate
    /// 'subsystem == "org.unmukto.obadh.keyboard"'`.
    private let lifecycleLog = Logger(subsystem: "org.unmukto.obadh.keyboard", category: "lifecycle")
    private let engine = ObadhBridgeClient.shared
    private lazy var composer = KeyboardComposer(
        engine: ObadhBridgeClient.shared,
        emojiSuggester: BanglaEmojiSuggestionStore(bundle: Bundle(for: KeyboardViewController.self)),
        compositionSuggestionLimit: suggestionSlotCount
    )
    /// How many text candidates the strip can show. Three on iPhone, up to six on
    /// iPad — see `PadAxisMetrics.suggestionSlotCount`. Read from the same metrics
    /// the bar lays itself out from, so the two cannot disagree.
    private var suggestionSlotCount: Int {
        currentMetrics.suggestionSlotCount
    }
    private let compositionController = TextCompositionController()
    private let personalAutosuggestStore = PersonalAutosuggestStore()
    /// Words the user has committed, protected from auto-insert corrections.
    private let learnedWordStore = LearnedWordStore()
    /// Serial queue for heavy engine work (snapshot export/write) so it stays
    /// off the main thread while remaining serialized against the Rust session.
    private let engineQueue = DispatchQueue(label: "org.unmukto.obadh.engine", qos: .userInitiated)
    private let feedbackController = KeyboardFeedbackController()
    private let backspaceRepeater = BackspaceRepeatController()
    private let suggestionBar = SuggestionBarView()
    /// Emoji for the word that was just committed, kept on screen after a space
    /// while the text slots move on to next-word suggestions. Cleared by the next
    /// letter. Committing used to blank the emoji slot outright, which put the
    /// suggestion one keystroke out of reach at exactly the moment a user reaches
    /// for it.
    private var carriedEmojis: [EmojiSuggestion] = []
    private let emojiPanelView = EmojiPanelView()
    private let emojiRecentStore = EmojiRecentStore()
    // Per-emoji skin-tone memory, shared with the emoji panel (same App Group
    // store), so a tone picked anywhere is remembered everywhere.
    private let emojiVariantPreferenceStore = EmojiVariantPreferenceStore()
    private lazy var emojiDataStore = EmojiDataStore(bundle: Bundle(for: KeyboardViewController.self))
    private let keyboardStack = UIStackView()
    // The system's own keyboard backdrop material (blur + tint). On iOS 26 this
    // adopts the Liquid Glass keyboard look automatically, and it is
    // non-transparent so touches over the inter-key gaps still reach the clear
    // KeyboardTouchSurfaceView. Preferred over a hand-rolled UIVisualEffect,
    // which reads as a distinct rectangle vs. the surrounding keyboard.
    private let keyboardBackgroundView = UIInputView(frame: .zero, inputViewStyle: .keyboard)
    private let keyboardTouchSurface = KeyboardTouchSurfaceView()
    private let keyPreviewCallout = KeyboardKeyPreviewCallout()
    /// iOS 26+ Liquid Glass group hosting `keyboardStack`, so all per-key glass
    /// views render in a single merged pass instead of ~33 separate ones. nil
    /// below iOS 26, where keys use the solid fill and the stack lives directly
    /// on `view`.
    private var keyboardGlassContainer: UIVisualEffectView?
    #if DEBUG
    // Agentic control channel — DEBUG builds only (see KeyboardDebugChannel).
    private lazy var debugChannel = KeyboardDebugChannel(handler: self)
    #endif
    private var keyButtons: [KeyboardKeyButton] = []
    private var highlightedKeyButton: KeyboardKeyButton?
    private var activeTouchKey: KeyboardKey?
    private var keyPreviewDismissal: DispatchWorkItem?
    private var shifted = false
    /// iPad caps lock. Distinct from `shifted`: it survives a keypress, and the
    /// key draws a filled glyph. Only ever laid out on iPad (see PadFamily).
    private var capsLocked = false

    private var isPadIdiom: Bool {
        traitCollection.userInterfaceIdiom == .pad
    }

    /// The width the layout is being built for. `view.bounds` is zero before the
    /// first layout pass, so fall back to the screen's shorter side.
    private var layoutWidth: CGFloat {
        let bounds = view.bounds.width
        guard bounds > 1 else { return min(screenSize.width, screenSize.height) }
        return bounds
    }

    private var screenSize: CGSize {
        view.window?.windowScene?.screen.bounds.size ?? UIScreen.main.bounds.size
    }

    /// The layout family, which is a property of the DEVICE and so must not move
    /// when the iPad rotates. See PadFamily.forPortraitWidth.
    private var padFamily: KeyboardLayoutProvider.PadFamily {
        KeyboardLayoutProvider.PadFamily.forScreen(screenSize)
    }

    /// Our own bounds are always wider than tall, so orientation comes from the
    /// layout width against the device's portrait width — never from our aspect.
    private var padIsLandscape: Bool {
        isPadIdiom && layoutWidth > min(screenSize.width, screenSize.height) + 1
    }
    private var keyboardMode: KeyboardMode = .letters
    private var previousKeyWasSpace = false
    /// Native's double-space shortcut is a QUICK double-tap, not "any two spaces":
    /// only a second space inside this window converts to dari; a slower one types a
    /// plain space. Monotonic clock so host clock changes can't confuse it.
    private static let dariDoubleSpaceWindow: TimeInterval = 0.35
    private var lastSpaceKeyTime: CFTimeInterval = 0
    private var suggestionGeneration = 0
    /// The in-flight suggestion query. Each keystroke supersedes the last, so the
    /// previous one is cancelled rather than left to run: dispatch skips a work item
    /// cancelled before it starts, which stops the serial queue from accumulating
    /// stale FST traversals. Without this, typing N characters enqueued N searches
    /// with N-1 already irrelevant — the results were discarded by
    /// `suggestionGeneration`, but the work still ran and still cost battery.
    private var pendingSuggestionWork: DispatchWorkItem?
    private var isUpdatingTextProxy = false
    /// Set while the suggestion bar is showing corrections for an already-committed word
    /// the cursor sits in, so a tap replaces that word rather than inserting a next word.
    private var activeCursorWord: CursorWord?
    /// Whether the deterministic literal currently shown is NOT a dictionary word. When
    /// true the first suggestion slot is quoted ("keep my spelling"), native-style,
    /// independent of the auto-insert setting. Computed off-main each settle; reset
    /// before every composition refresh so a stale quote never shows.
    private var deterministicIsOOV = false
    private var showsSpaceLanguageIntro = false
    private var showsEmojiPanel = false
    private var isEmojiSearchActive = false
    private var emojiSearchQuery = ""
    private var emojiSearchLanguage: EmojiSearchLanguage = .english
    private let keyboardPreferences = KeyboardPreferences()
    private var spaceLanguageIntroDismissal: DispatchWorkItem?
    private var keyboardStackLeadingConstraint: NSLayoutConstraint?
    private var keyboardStackTrailingConstraint: NSLayoutConstraint?
    private var keyboardStackTopConstraint: NSLayoutConstraint?
    private var keyboardStackBottomConstraint: NSLayoutConstraint?
    private var keyboardStackHeightConstraint: NSLayoutConstraint?
    private var rowHeightConstraints: [NSLayoutConstraint] = []
    private var emojiPanelBottomToSafeAreaConstraint: NSLayoutConstraint?
    private var emojiPanelBottomToKeyboardConstraint: NSLayoutConstraint?
    private var keyboardHeightConstraint: NSLayoutConstraint?
    private var viewWillAppearWasCalled = false
    private var lastAppliedMetricSize: CGSize = .zero
    // Legacy-presentation detection state (see recordPresentationTransient).
    private var presentationTransients: [CGFloat] = []
    private var presentationClassified = false
    // Presentation-path discrimination (iOS 27 adds its container band only on
    // some paths): counters surfaced by the probe overlay to find the signal.
    private var presentationCount = 0
    private let processStart = CACurrentMediaTime()

    #if DEBUG
    /// On-keyboard overlay dumping the presentation context iOS hands us in the current
    /// host app. Toggle from the app's debug panel; capture in Messenger vs Safari vs a
    /// legacy app to learn how the system frames the extension, then adapt to match.
    private let presentationProbeLabel = UILabel()
    /// Fiducial hairlines at the view's top edge and the strip's bottom, so any
    /// screenshot self-certifies our geometry (band = container edge → top hairline;
    /// strip = distance between the two lines) with no detector heuristics.
    private let probeTopHairline = UIView()
    private let probeStripHairline = UIView()
    private var lastProbeString = ""
    /// Forces the height we ask for, independent of the metrics we render, so the
    /// band's law can be measured by sweeping the ask and reading the resulting
    /// band off the fiducials (`ask:<pt>`; `ask:0` restores). DEBUG only.
    private var debugAskOverride: CGFloat?
    /// Complete layout-pass trace for the sizing investigation: every distinct
    /// height the system lays us out at, with the ask in force at that moment.
    /// The classifier's `presentationTransients` is a filtered view of this; the
    /// filtering is what hid the race, so the raw sequence is logged separately.
    private var lastTracedHeight: CGFloat = -1
    private var frameMonitor: CADisplayLink?
    private var frameWindowStart: CFTimeInterval = 0
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var frameCount = 0
    private var droppedFrames = 0
    private var worstFrameMs: Double = 0
    /// Distinct laid-out heights since the last recorded presentation, `*`-marked
    /// when the pass arrived before `viewWillAppear` (those are invisible to the
    /// shipping classifier) and `|`-separated at each `viewWillAppear`. The probe
    /// shows the tail; KeyboardSizingLog stores the whole thing.
    private var layoutTrace: [String] = []
    private var sizingRecordWrite: DispatchWorkItem?
    private var sizingRecordIdentifier = 0
    private var presentationUptime: Double = 0
    #endif

    var enableInputClicksWhenVisible: Bool {
        true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        lifecycleLog.notice("OBADH-LIFECYCLE viewDidLoad — extension loaded, backdrop=\(String(describing: type(of: self.keyboardBackgroundView)), privacy: .public)")
        recordFullAccessIfGranted()
        configureInputViewShell()
        let configuration = engine.configureModels(in: Bundle(for: KeyboardViewController.self))
        if configuration.autosuggestAvailable {
            restorePersonalAutosuggest()
        }
        feedbackController.prepare(hasFullAccess: hasFullAccess)
        configureRootView()
        configureSuggestionBar()
        configureEmojiPanel()
        reloadKeyboardRows()
        refreshKeyboard()
        #if DEBUG
        startKeyTintObserver()
        configurePresentationProbe()
        startBandObservationProbe()
        #endif
    }

    deinit {
        #if DEBUG
        stopKeyTintObserver()
        #endif
    }

    #if DEBUG
    /// Live native-parity tuning: the containing app posts a Darwin notification when
    /// a key-tint slider changes; re-style the keys so the change shows without a
    /// rebuild. DEBUG only.
    private func startKeyTintObserver() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let controller = Unmanaged<KeyboardViewController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    // A debug tunable changed. Drop the memoized metrics (its cache key
                    // ignores debug values) and force a relayout so shadow, key tint,
                    // and suggestion height all re-read at once.
                    controller.metricsCache = nil
                    controller.applyLayoutMetricsIfNeeded(force: true)
                    controller.refreshKeyboard()
                }
            },
            KeyboardPreferences.debugKeyTintDarwinName as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func stopKeyTintObserver() {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(KeyboardPreferences.debugKeyTintDarwinName as CFString),
            nil
        )
    }

    /// A yellow top-left overlay reporting the geometry iOS hands the extension: view
    /// bounds, safe-area insets, window vs screen width (side-inset tell), the height
    /// constraint, and the nearest rounded-corner ancestor (the system's container
    /// silhouette). Read it in different host apps to see legacy vs Liquid Glass framing.
    private func configurePresentationProbe() {
        presentationProbeLabel.numberOfLines = 0
        presentationProbeLabel.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        presentationProbeLabel.textColor = .systemYellow
        presentationProbeLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        presentationProbeLabel.isUserInteractionEnabled = false
        presentationProbeLabel.isHidden = true
        presentationProbeLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(presentationProbeLabel)
        NSLayoutConstraint.activate([
            presentationProbeLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            presentationProbeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4)
        ])
        for line in [probeTopHairline, probeStripHairline] {
            line.backgroundColor = .systemYellow
            line.isUserInteractionEnabled = false
            line.isHidden = true
            view.addSubview(line)
        }
    }

    private func updatePresentationProbe() {
        let enabled = keyboardPreferences.debugPresentationProbeEnabled
        presentationProbeLabel.isHidden = !enabled
        probeTopHairline.isHidden = !enabled
        probeStripHairline.isHidden = !enabled
        guard enabled else { return }
        let text = presentationProbeString()
        presentationProbeLabel.text = text
        let hairline = 1 / (view.window?.screen.scale ?? 3)
        probeTopHairline.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: hairline)
        probeStripHairline.frame = CGRect(
            x: 0,
            y: suggestionBar.convert(suggestionBar.bounds, to: view).maxY,
            width: view.bounds.width,
            height: hairline
        )
        view.bringSubviewToFront(probeTopHairline)
        view.bringSubviewToFront(probeStripHairline)
        view.bringSubviewToFront(presentationProbeLabel)
        if text != lastProbeString {
            lastProbeString = text
            lifecycleLog.notice("OBADH-PROBE \(text.replacingOccurrences(of: "\n", with: " · "), privacy: .public)")
        }
    }

    private func presentationProbeString() -> String {
        let b = view.bounds
        let sa = view.safeAreaInsets
        // frame-in-window is the smoking gun for height fights: origin.y > 0 means the
        // container is taller than our view and the system bottom-anchored us in it
        // (the "extra band above the suggestions" presentation); win is the container
        // the system actually granted, hCon what we asked for.
        let win = view.window
        let frame = win.map { view.convert(view.bounds, to: $0) } ?? .zero
        let winSize = win?.bounds.size ?? .zero
        let scrW = win?.screen.bounds.width ?? UIScreen.main.bounds.width
        let ivH = inputView?.bounds.height ?? 0
        let hActive = keyboardHeightConstraint?.isActive ?? false
        let selfSizing = inputView?.allowsSelfSizing ?? false
        // wf = the extension window's frame in SCREEN coordinates: with the screen
        // height it answers exactly where the system placed us — dock height below
        // (scrH - wfY - winH) and any system band above our view inside the container.
        let winFrame = win?.frame ?? .zero
        let scrH = win?.screen.bounds.height ?? UIScreen.main.bounds.height
        let designCompat = Bundle.main.object(forInfoDictionaryKey: "UIDesignRequiresCompatibility") as? Bool ?? false
        let m = currentMetrics
        return String(
            format: "b %.0f×%.0f  f(%.0f,%.0f)  win %.0f×%.0f  wf(%.0f,%.0f)  scr %.0f×%.0f\nsa L%.0f R%.0f T%.0f B%.0f  ivH %.0f  hCon %.0f/%@  ss %@  lg %@\nm s%.0f k%.0f r%.1f t%.0f b%.0f  rnd %@  glass %@  compat %@",
            b.width, b.height, frame.origin.x, frame.origin.y, winSize.width, winSize.height,
            winFrame.origin.x, winFrame.origin.y, scrW, scrH,
            sa.left, sa.right, sa.top, sa.bottom, ivH,
            keyboardHeightConstraint?.constant ?? 0, hActive ? "on" : "off", selfSizing ? "Y" : "N",
            KeyboardTheme.legacyPresentation ? "Y" : "N",
            m.suggestionHeight, m.minimumKeyHeight, m.rowSpacing,
            m.keyboardInsets.top, m.keyboardInsets.bottom,
            nearestRoundedAncestorDescription(), KeyboardGlassStyle.current.rawValue,
            designCompat ? "Y" : "N"
        ) + String(
            format: "\n#%d tr %@  a%.0f p%d n%d up%.1f",
            sizingRecordIdentifier,
            layoutTrace.suffix(6).joined(separator: "›"),
            preferredActiveKeyboardHeight,
            keyboardPreferences.debugPinnedPresentation,
            presentationCount,
            CACurrentMediaTime() - processStart
        )
    }

    /// Walks up from the extension's view to the window looking for the first ancestor
    /// whose layer is corner-rounded — the system's floating/curved keyboard container,
    /// if any. Reports its class, radius, and whether it clips.
    private func nearestRoundedAncestorDescription() -> String {
        var candidate: UIView? = view.superview
        var depth = 0
        while let current = candidate, depth < 10 {
            let radius = current.layer.cornerRadius
            if radius > 0.5 {
                return "\(type(of: current))·r\(Int(radius.rounded()))·clip\(current.clipsToBounds ? 1 : 0)"
            }
            candidate = current.superview
            depth += 1
        }
        return "none"
    }
    #endif

    /// Without Full Access this container is unreachable, so the write silently does
    /// nothing — which is precisely the signal. The containing app reads the stamp to
    /// learn that Full Access was granted; it has no API of its own to ask.
    private func recordFullAccessIfGranted() {
        guard hasFullAccess else { return }
        keyboardPreferences.fullAccessConfirmedAt = Date()
    }

    private func configureInputViewShell() {
        guard let inputView else { return }
        // Self-sizing + one height constraint requests our intended content size.
        // UIKit can still supply transient bounds or add host-owned margins; this
        // does not guarantee the outer container height on every presentation.
        // Letting the system size us instead (allowsSelfSizing false, no constraint)
        // was measured to be untrustworthy: the granted height
        // ratchets across presentations (253→290→314 on the same sim) and renders a
        // container visibly taller than native. See the native-parity notes.
        inputView.allowsSelfSizing = true
        inputView.clipsToBounds = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewWillAppearWasCalled = true
        // Every presentation re-detects the host's container style (the host app
        // can differ each time we appear).
        presentationCount += 1
        presentationTransients.removeAll()
        presentationClassified = false
        // Diagnosis mode: hold the presentation class fixed so our asked height is
        // identical on every presentation, isolating the system's band from our own
        // changes. See KeyboardPreferences.debugPinnedPresentation.
        #if DEBUG
        // Diagnosis mode: pin the layout instead of detecting anything, so a capture
        // run can A/B the two strip heights on device.
        let pinned = keyboardPreferences.debugPinnedPresentation
        if pinned != 0 {
            presentationClassified = true
        }
        if KeyboardTheme.debugFullZoneStrip != (pinned == 2) {
            KeyboardTheme.debugFullZoneStrip = pinned == 2
            metricsCache = nil
        }
        #endif
        if KeyboardTheme.legacyPresentation {
            KeyboardTheme.legacyPresentation = false
            metricsCache = nil
        }
        #if DEBUG
        beginSizingRecord()
        #endif
        view.setNeedsUpdateConstraints()
        feedbackController.prepare(hasFullAccess: hasFullAccess)
        // Obadh may be returning to a field another keyboard has edited since we last
        // saw it. Any composition we remember is stale; start from whatever the
        // document is now.
        resetCompositionBookkeeping()
    }

    override func updateViewConstraints() {
        super.updateViewConstraints()
        updateKeyboardHeightConstraintIfReady()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        lifecycleLog.notice("OBADH-LIFECYCLE viewDidAppear — keyboard visible, build=\(AppBuildInfo.summary, privacy: .public) style=\(self.traitCollection.userInterfaceStyle == .dark ? "dark" : "light", privacy: .public) size=\(NSCoder.string(for: self.view.bounds.size), privacy: .public)")
        #if DEBUG
        logBandObservationCandidates()
        startFrameMonitor()
        #endif
        showSpaceLanguageIntro()
        // Reflect the current cursor context (e.g. next-word suggestions) now that we
        // are back, rather than showing whatever was in the bar when we left.
        refreshSuggestions()
        #if DEBUG
        debugChannel.start()
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Switching to another keyboard (or dismissing): the word in progress is already
        // ordinary text, so we only stop tracking it. Nothing is lost or stranded.
        resetCompositionBookkeeping()
        keyboardTouchSurface.cancelTracking()
        hideKeyPreview(animated: false)
        backspaceRepeater.end() // The emoji panel can own a repeat without an active key.
        spaceLanguageIntroDismissal?.cancel()
        spaceLanguageIntroDismissal = nil
        viewWillAppearWasCalled = false
        #if DEBUG
        stopFrameMonitor()
        // Capture short presentations too, before the deferred write would fire.
        writeSizingRecord()
        debugChannel.stop()
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        #if DEBUG
        traceLayoutPass()
        #endif
        recordPresentationTransient()
        applyLayoutMetricsIfNeeded()
        updateKeyboardTouchRegions()
        #if DEBUG
        updatePresentationProbe()
        #endif
    }

    #if DEBUG
    /// Frame-drop monitor. The per-keystroke profile showed only ~1.1 ms of
    /// main-thread work on an iPhone 16e, which cannot by itself feel laggy — so the
    /// cost has to be after our code returns, in layout and GPU compositing. This
    /// measures that directly: whether frames are actually being missed.
    ///
    /// Streams over USB alongside the keystroke lines:
    ///   idevicesyslog -u <udid> -m OBADH-
    private func startFrameMonitor() {
        frameMonitor?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(frameTick(_:)))
        link.add(to: .main, forMode: .common)
        frameMonitor = link
        frameWindowStart = CACurrentMediaTime()
        frameCount = 0
        droppedFrames = 0
        worstFrameMs = 0
        lastFrameTimestamp = 0
    }

    private func stopFrameMonitor() {
        frameMonitor?.invalidate()
        frameMonitor = nil
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        guard viewIfLoaded?.window != nil else {
            // CADisplayLink retains its target. Host termination can detach us
            // without viewWillDisappear; release the monitor and polling then.
            stopFrameMonitor()
            debugChannel.stop()
            return
        }
        let now = link.timestamp
        // `targetTimestamp - timestamp` is the display's current frame budget, which
        // varies with ProMotion, so the threshold is derived rather than hardcoded.
        let expected = link.targetTimestamp - now
        if lastFrameTimestamp > 0 {
            let delta = now - lastFrameTimestamp
            worstFrameMs = max(worstFrameMs, delta * 1000)
            if delta > expected * 1.5 {
                // Count how many frame slots were missed, not just that one was.
                droppedFrames += Int((delta / max(expected, 0.0001)).rounded()) - 1
            }
        }
        lastFrameTimestamp = now
        frameCount += 1

        let elapsed = now - frameWindowStart
        guard elapsed >= 1.0 else { return }
        if droppedFrames > 0 || worstFrameMs > 25 {
            lifecycleLog.notice(
                "OBADH-FRAMES \(self.frameCount, privacy: .public) frames in \(Int(elapsed * 1000), privacy: .public)ms  dropped \(self.droppedFrames, privacy: .public)  worst \(Int(self.worstFrameMs), privacy: .public)ms  budget \(Int(expected * 1000), privacy: .public)ms"
            )
        }
        frameWindowStart = now
        frameCount = 0
        droppedFrames = 0
        worstFrameMs = 0
    }

    /// Last-resort search for a runtime observable of the system's container band.
    /// Two candidates the geometry argument does not already rule out:
    ///   1. keyboard-frame notifications — if the extension receives them at all, the
    ///      frame would be the CONTAINER's, and band = container − ourHeight − dock.
    ///   2. conversion into the screen's fixed coordinate space, which may route
    ///      through the remote-view transform even though `window.frame` reads (0,0).
    /// Both are logged so a device capture can confirm or close the question.
    private func startBandObservationProbe() {
        let names: [Notification.Name] = [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardDidChangeFrameNotification
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                self?.lifecycleLog.notice(
                    "OBADH-BANDPROBE notification \(name.rawValue, privacy: .public) frame=\(frame.map(NSCoder.string(for:)) ?? "nil", privacy: .public)"
                )
            }
        }
    }

    private func logBandObservationCandidates() {
        guard let window = view.window else { return }
        let screenSpace = window.screen.fixedCoordinateSpace
        let inScreen = view.convert(view.bounds, to: screenSpace)
        let windowInScreen = window.convert(window.bounds, to: screenSpace)
        lifecycleLog.notice(
            """
            OBADH-BANDPROBE geometry viewInScreen=\(NSCoder.string(for: inScreen), privacy: .public) \
            windowInScreen=\(NSCoder.string(for: windowInScreen), privacy: .public) \
            screen=\(NSCoder.string(for: window.screen.bounds), privacy: .public) \
            viewH=\(Int(self.view.bounds.height)) \
            safeArea=\(NSCoder.string(for: self.view.safeAreaInsets), privacy: .public) \
            windowSafeArea=\(NSCoder.string(for: window.safeAreaInsets), privacy: .public) \
            windowLevel=\(window.windowLevel.rawValue)
            """
        )
    }

    /// Opens a sizing record for this presentation. The record is written ~1.5s after
    /// the keyboard appears — late enough to include our own classification-driven
    /// resize and any system resize that follows it, which is exactly the window the
    /// shipping classifier stops watching.
    private func beginSizingRecord() {
        sizingRecordWrite?.cancel()
        sizingRecordIdentifier = KeyboardSizingLog.shared.nextIdentifier()
        presentationUptime = CACurrentMediaTime() - processStart
        layoutTrace.append("|")
        lastTracedHeight = -1 // Record the first pass even if a warm return has the same height.
        let write = DispatchWorkItem { [weak self] in self?.writeSizingRecord() }
        sizingRecordWrite = write
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: write)
    }

    private func writeSizingRecord() {
        guard sizingRecordWrite != nil else { return }
        sizingRecordWrite?.cancel()
        sizingRecordWrite = nil
        let mode: String
        switch keyboardPreferences.debugPinnedPresentation {
        case 1: mode = "pinned-banded"
        case 2: mode = "pinned-bandless"
        default: mode = "auto"
        }
        let presentationClass: String
        if KeyboardTheme.legacyPresentation {
            presentationClass = "legacy"
        } else if KeyboardTheme.debugFullZoneStrip {
            presentationClass = "full-zone-strip"
        } else {
            presentationClass = "banded"
        }
        // Heights seen after the first pass that matched the ask — a resize the
        // classifier never sees, because it stops at that pass.
        let settledIndex = layoutTrace.lastIndex { $0 == "|" } ?? 0
        let afterAppear = layoutTrace[settledIndex...].compactMap { Double($0.filter(\.isNumber)) }
        let ask = Double(preferredActiveKeyboardHeight)
        let firstSettle = afterAppear.firstIndex { abs($0 - ask) < 1 }
        let late = firstSettle.map { Array(afterAppear[($0 + 1)...]) } ?? []
        let screen = view.window?.screen.bounds.size ?? UIScreen.main.bounds.size
        KeyboardSizingLog.shared.append(
            KeyboardSizingLog.Entry(
                id: sizingRecordIdentifier,
                date: Date(),
                uptime: presentationUptime,
                presentation: presentationCount,
                pid: ProcessInfo.processInfo.processIdentifier,
                trace: layoutTrace,
                ask: ask,
                strip: Double(currentMetrics.suggestionHeight),
                settled: Double(view.bounds.height),
                mode: mode,
                presentationClass: presentationClass,
                screen: "\(Int(screen.width))x\(Int(screen.height))",
                systemVersion: UIDevice.current.systemVersion,
                dark: traitCollection.userInterfaceStyle == .dark,
                lateHeights: late,
                actualStrip: Double(suggestionBar.bounds.height)
            )
        )
        layoutTrace.removeAll()
    }

    /// One line per distinct height the system lays us out at, from process start
    /// to teardown — the unfiltered ground truth behind the classifier. Includes
    /// whether `viewWillAppear` has run, because passes before it are invisible to
    /// the classifier and that asymmetry is a race candidate.
    private func traceLayoutPass() {
        let height = view.bounds.height
        guard height != lastTracedHeight else { return }
        lastTracedHeight = height
        layoutTrace.append("\(Int(height))\(viewWillAppearWasCalled ? "" : "*")")
        if layoutTrace.count > 32 {
            layoutTrace.removeFirst(layoutTrace.count - 32)
        }
        lifecycleLog.notice("OBADH-GEOMETRY stripRequested=\(self.currentMetrics.suggestionHeight) stripActual=\(self.suggestionBar.bounds.height) stripY=\(self.suggestionBar.frame.minY) keysY=\(self.keyboardStack.convert(self.keyboardStack.bounds, to: self.view).minY)")
        lifecycleLog.notice(
            """
            OBADH-TRACE n\(self.presentationCount) t\(Int((CACurrentMediaTime() - self.processStart) * 1000)) \
            b\(Int(height)) ask\(Int(self.preferredActiveKeyboardHeight)) \
            con\(Int(self.keyboardHeightConstraint?.constant ?? -1))/\(self.keyboardHeightConstraint?.isActive == true ? "on" : "off") \
            iv\(Int(self.inputView?.bounds.height ?? -1)) win\(Int(self.view.window?.bounds.height ?? -1)) \
            wva\(self.viewWillAppearWasCalled ? 1 : 0) cls\(self.presentationClassified ? 1 : 0)
            """
        )
    }
    #endif

    #if DEBUG
    /// Times a main-thread entry point and logs anything over one frame budget. The
    /// keystroke profiler brackets handleKeyPress only, but the host calls BACK into
    /// the proxy callbacks after our insert, and that work is also main-thread. A
    /// 1.4s frame gap with a 1.1ms keystroke means the cost lives here.
    @discardableResult
    private func measureMain<T>(_ label: String, _ body: () -> T) -> T {
        let t0 = CACurrentMediaTime()
        let value = body()
        let ms = (CACurrentMediaTime() - t0) * 1000
        if ms > 8 {
            lifecycleLog.notice("OBADH-STALL \(label, privacy: .public) \(Int(ms), privacy: .public)ms")
        }
        return value
    }
    #endif

    // MARK: Legacy presentation detection

    /// iOS presents third-party keyboards in one of two containers — modern Liquid
    /// Glass or the legacy style for hosts that haven't adopted the current design —
    /// with no public API exposing which. The one observable difference is the
    /// presentation's transient sizing pass: before honoring our height, the system
    /// lays the view out at a presentation-specific intermediate. Those
    /// intermediates are class-quantized and disjoint (measured on every current
    /// width class, iOS 26.5): modern {294, 444, 452} vs legacy {260, 411, 419},
    /// separated by 33-34pt. Classification is nearest-anchor per screen height
    /// with a required margin; modern wins ties, unknown screens, and missing
    /// transients, so a wrong guess can only ever leave the shipped modern look.
    private static let presentationIntermediates: [CGFloat: (modern: CGFloat, legacy: CGFloat)] = [
        667: (294, 260),   // SE class (home button)
        852: (444, 411),   // iPhone 16 class
        874: (444, 411),   // iPhone 17 Pro class
        912: (452, 419),   // iPhone Air class
        932: (452, 419),   // Plus class
        956: (452, 419),   // Pro Max class
    ]

    private func recordPresentationTransient() {
        guard viewWillAppearWasCalled, !presentationClassified else { return }
        let height = view.bounds.height
        guard height > 0 else { return }
        let screenHeight = view.window?.screen.bounds.height ?? UIScreen.main.bounds.height
        if abs(height - preferredActiveKeyboardHeight) < 1 || presentationTransients.count > 8 {
            classifyPresentation(screenHeight: screenHeight)
            return
        }
        if height != screenHeight, presentationTransients.last != height {
            presentationTransients.append(height)
        }
    }

    private func classifyPresentation(screenHeight: CGFloat) {
        presentationClassified = true
        // Existing device captures showed modern framing in Messenger on iOS 27.
        // Keep the iOS 26 transient-height classifier off there: its anchors are
        // empirical, not an API contract. A matching 17pt host-margin regression
        // is independently reported on iOS 27 (FB24460699); extension bounds do
        // not reliably reveal it. Do not infer a missing band from a transient
        // root height or grow our strip to compensate. See keyboard-investigation.md.
        if #available(iOS 27.0, *) {
            return
        }
        guard let anchors = Self.presentationIntermediates[screenHeight],
              let intermediate = presentationTransients.last else {
            return
        }
        let legacyDistance = abs(intermediate - anchors.legacy)
        let modernDistance = abs(intermediate - anchors.modern)
        guard legacyDistance + 8 < modernDistance else { return }
        lifecycleLog.notice("OBADH-LIFECYCLE legacy presentation detected (intermediate \(intermediate, privacy: .public) on screen \(screenHeight, privacy: .public))")
        KeyboardTheme.legacyPresentation = true
        metricsCache = nil
        updateKeyboardHeightConstraintIfReady()
        applyLayoutMetricsIfNeeded(force: true)
        refreshKeyboard()
    }

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        guard !isUpdatingTextProxy else { return }
        // The host is about to change the text out from under us (a send button
        // clearing the field, a paste, another edit). Drop composition bookkeeping;
        // whatever was marked is the host's now.
        resetCompositionBookkeeping()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        guard !isUpdatingTextProxy else { return }
        #if DEBUG
        return measureMain("textDidChange") { textDidChangeBody() }
        #else
        textDidChangeBody()
        #endif
    }

    private func textDidChangeBody() {
        if !composer.hasActiveInput,
           (textDocumentProxy.documentContextBeforeInput ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty {
            engine.clearAutosuggestSession()
        }
        refreshSuggestions()
    }

    // Moving the insertion point — a tap, an arrow key, a selection — is a *selection*
    // change, not a *text* change, so it never reaches textWillChange/textDidChange.
    // Observing it lets us stop tracking the word being composed the moment the cursor
    // leaves it. Because the word is ordinary text (not a marked IME region), stopping
    // tracking is all that's needed: the word stays, and the cursor moves freely — there
    // is nothing to confirm and nothing to strand.
    override func selectionWillChange(_ textInput: UITextInput?) {
        super.selectionWillChange(textInput)
        // Same guard the text callbacks use: our own proxy edits deliver their selection
        // callbacks synchronously inside performTextUpdate, where the flag is set, so
        // this fires only for genuine external moves.
        guard !isUpdatingTextProxy else { return }
        resetCompositionBookkeeping()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        guard !isUpdatingTextProxy else { return }
        #if DEBUG
        return measureMain("selectionDidChange") { selectionDidChangeBody() }
        #else
        selectionDidChangeBody()
        #endif
    }

    private func selectionDidChangeBody() {
        // Backstop for hosts that deliver only one of the two callbacks; idempotent.
        resetCompositionBookkeeping()
        refreshSuggestions()
    }

    private func configureRootView() {
        view.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = true

        // A native-material backdrop covering the whole keyboard: it gives the
        // system keyboard's glassy look uniformly (so there's no visible
        // rectangle around the key area) and, being non-transparent, it is what
        // lets touches over the gaps between keys reach the extension at all —
        // the clear touch surface on top then resolves them.
        keyboardBackgroundView.isUserInteractionEnabled = false
        keyboardBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardBackgroundView)
        NSLayoutConstraint.activate([
            keyboardBackgroundView.topAnchor.constraint(equalTo: view.topAnchor),
            keyboardBackgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardBackgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardBackgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let heightConstraint = view.heightAnchor.constraint(equalToConstant: preferredActiveKeyboardHeight)
        heightConstraint.priority = UILayoutPriority.required - 1
        keyboardHeightConstraint = heightConstraint

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: KeyboardViewController, _) in
            controller.view.backgroundColor = .clear
            controller.view.clipsToBounds = true
            controller.view.setNeedsUpdateConstraints()
            controller.applyLayoutMetricsIfNeeded(force: true)
            controller.refreshKeyboard()
        }
    }

    private func configureSuggestionBar() {
        suggestionBar.delegate = self
        view.addSubview(suggestionBar)

        let metrics = currentMetrics
        keyboardStack.axis = .vertical
        keyboardStack.alignment = .fill
        keyboardStack.distribution = .fill
        keyboardStack.spacing = metrics.rowSpacing
        keyboardStack.isUserInteractionEnabled = true
        keyboardStack.translatesAutoresizingMaskIntoConstraints = false

        // On iOS 26 the key rows live inside one Liquid Glass container so the
        // per-key glass effects merge in a single render pass (perf), and it sits
        // under the touch surface so hit-testing is unchanged. Below iOS 26 the
        // stack goes straight on `view` with the solid key fill. `keyLayoutAnchor`
        // is whichever view carries the key-area layout constraints.
        let keyLayoutAnchor: UIView
        if #available(iOS 26.0, *) {
            let containerEffect = UIGlassContainerEffect()
            containerEffect.spacing = 0
            let container = UIVisualEffectView(effect: containerEffect)
            container.isUserInteractionEnabled = true
            container.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(container)
            container.contentView.addSubview(keyboardStack)
            NSLayoutConstraint.activate([
                keyboardStack.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor),
                keyboardStack.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor),
                keyboardStack.topAnchor.constraint(equalTo: container.contentView.topAnchor),
                keyboardStack.bottomAnchor.constraint(equalTo: container.contentView.bottomAnchor)
            ])
            keyboardGlassContainer = container
            keyLayoutAnchor = container
        } else {
            view.addSubview(keyboardStack)
            keyLayoutAnchor = keyboardStack
        }

        keyboardTouchSurface.delegate = self
        view.addSubview(keyboardTouchSurface)
        keyPreviewCallout.alpha = 0
        keyPreviewCallout.isHidden = true
        view.addSubview(keyPreviewCallout)

        let insets = metrics.keyboardInsets
        let leadingConstraint = keyLayoutAnchor.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        let trailingConstraint = keyLayoutAnchor.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        let topConstraint = keyLayoutAnchor.topAnchor.constraint(equalTo: suggestionBar.bottomAnchor, constant: insets.top)
        // UIKit can offer fullscreen/intermediate root heights even after
        // viewDidAppear. Keep the fixed key block at the bottom while it settles;
        // top anchoring moved the rows by the entire transient excess height.
        // iPhone's measured inset is relative to the safe area; iPad's is from
        // the screen edge. The requested root size and ribbon height stay fixed.
        let bottomConstraint = keyLayoutAnchor.bottomAnchor.constraint(
            equalTo: isPadIdiom ? view.bottomAnchor : view.safeAreaLayoutGuide.bottomAnchor,
            constant: -insets.bottom
        )
        bottomConstraint.priority = UILayoutPriority(999)
        let suggestionTopConstraint = suggestionBar.topAnchor.constraint(equalTo: view.topAnchor)
        if !isPadIdiom {
            suggestionTopConstraint.priority = .defaultLow
        }
        let heightConstraint = keyLayoutAnchor.heightAnchor.constraint(equalToConstant: keyRowsHeight(for: metrics))
        heightConstraint.priority = UILayoutPriority(999)
        // On iPad the bottom edge wins; the top constraint only takes up slack.
        if isPadIdiom {
            topConstraint.priority = UILayoutPriority(250)
        }
        keyboardStackLeadingConstraint = leadingConstraint
        keyboardStackTrailingConstraint = trailingConstraint
        keyboardStackTopConstraint = topConstraint
        keyboardStackBottomConstraint = bottomConstraint
        keyboardStackHeightConstraint = heightConstraint
        suggestionBar.applyMetrics(metrics)

        NSLayoutConstraint.activate([
            suggestionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            suggestionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            suggestionTopConstraint,

            leadingConstraint,
            trailingConstraint,
            topConstraint,
            bottomConstraint,
            heightConstraint,

            keyboardTouchSurface.leadingAnchor.constraint(equalTo: keyboardStack.leadingAnchor),
            keyboardTouchSurface.trailingAnchor.constraint(equalTo: keyboardStack.trailingAnchor),
            // Full-bleed so its near-invisible touch-routing tint is uniform (no
            // rectangle). It ignores touches above `keyAreaTop` (the suggestion
            // bar) and, below the bottom command row down to the view edge, the
            // resolver clamps low thumb taps to the last row.
            keyboardTouchSurface.topAnchor.constraint(equalTo: view.topAnchor),
            keyboardTouchSurface.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureEmojiPanel() {
        emojiPanelView.delegate = self
        emojiPanelView.configure(
            dataStore: emojiDataStore,
            recentEmojis: emojiRecentStore.load()
        )
        view.addSubview(emojiPanelView)

        let bottomToSafeArea = emojiPanelView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        let bottomToKeyboard = emojiPanelView.bottomAnchor.constraint(
            equalTo: keyboardStack.topAnchor,
            constant: -6
        )
        bottomToKeyboard.isActive = false
        emojiPanelBottomToSafeAreaConstraint = bottomToSafeArea
        emojiPanelBottomToKeyboardConstraint = bottomToKeyboard

        NSLayoutConstraint.activate([
            emojiPanelView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emojiPanelView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emojiPanelView.topAnchor.constraint(equalTo: view.topAnchor),
            bottomToSafeArea
        ])
    }

    private func reloadKeyboardRows() {
        let metrics = currentMetrics
        keyboardTouchSurface.cancelTracking()
        hideKeyPreview(animated: false)
        backspaceRepeater.end()
        keyButtons.removeAll(keepingCapacity: true)
        NSLayoutConstraint.deactivate(rowHeightConstraints)
        rowHeightConstraints.removeAll(keepingCapacity: true)
        keyboardStack.arrangedSubviews.forEach { view in
            keyboardStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let rows = KeyboardLayoutProvider.rows(
            for: keyboardMode,
            includesGlobeKey: needsInputModeSwitchKey,
            isPad: isPadIdiom,
            width: Double(layoutWidth),
            family: padFamily,
            landscape: padIsLandscape,
            margin: Double(metrics.keyboardInsets.left),
            gap: Double(metrics.keySpacing)
        )
        for (rowIndex, row) in rows.enumerated() {
            let rowView = KeyboardRowView()
            rowView.translatesAutoresizingMaskIntoConstraints = false
            var rowButtons: [KeyboardKeyButton] = []
            rowButtons.reserveCapacity(row.keys.count)
            let heightOfRow = rowHeight(atIndex: rowIndex, metrics: metrics)

            for (keyIndex, key) in row.keys.enumerated() {
                let button = KeyboardKeyButton(key: key)
                button.onAccessibilityActivate = { [weak self] in
                    guard let self else { return }
                    self.keyboardTouchSurface.cancelTracking()
                    self.handleKeyTouchDown(key)
                    self.handleKeyRelease(key)
                    self.handleKeyPress(key)
                }
                // Only the letters page carries flick-down glyphs, and only on the
                // families where native shows them: the extended layout has a real
                // number row, so its letters are bare exactly like native's.
                // The 13-inch has a real number row, so native leaves its letters
                // BARE — measured 0 flick ink on both extended references, against
                // our 7.5pt. The comment here has always said so; the condition
                // never checked the family.
                button.showsSecondaryLabel = isPadIdiom
                    && keyboardMode == .letters
                    && padFamily != .extended
                // Lets a short row size its type to itself. Only the 13-inch
                // number row is short; everywhere else this equals minimumKeyHeight.
                button.rowHeight = heightOfRow
                button.glyphAlignment = padGlyphAlignment(
                    for: key, at: keyIndex, of: row.keys.count
                )
                button.updateAppearance(
                    shifted: shifted,
                    traitCollection: traitCollection,
                    metrics: metrics,
                    showsSpaceIntro: showsSpaceLanguageIntro && !isEmojiSearchActive,
                    spaceCaption: spaceCaption,
                    capsLocked: capsLocked
                )
                rowButtons.append(button)
                keyButtons.append(button)
            }

            rowView.configure(row: row, buttons: rowButtons, metrics: metrics)
            keyboardStack.addArrangedSubview(rowView)
            let heightConstraint = rowView.heightAnchor.constraint(equalToConstant: heightOfRow)
            heightConstraint.priority = UILayoutPriority(999)
            heightConstraint.isActive = true
            rowHeightConstraints.append(heightConstraint)
        }
        keyboardStack.setNeedsLayout()
        keyboardTouchSurface.keyRows = []
        // Buttons were rebuilt, so force the next appearance pass to restyle them.
        lastAppearanceState = nil
    }

    private func refreshKeyboard() {
        let metrics = currentMetrics
        updateKeyboardHeightConstraintIfReady()
        view.backgroundColor = .clear
        suggestionBar.isHidden = showsEmojiPanel
        keyboardStack.isHidden = showsEmojiPanel && !isEmojiSearchActive
        keyboardGlassContainer?.isHidden = keyboardStack.isHidden
        keyboardTouchSurface.isHidden = keyboardStack.isHidden
        emojiPanelView.isHidden = !showsEmojiPanel
        emojiPanelView.setSearchActive(isEmojiSearchActive)
        emojiPanelBottomToSafeAreaConstraint?.isActive = !isEmojiSearchActive
        emojiPanelBottomToKeyboardConstraint?.isActive = isEmojiSearchActive
        keyboardStackTopConstraint?.constant = keyboardTopConstant(for: metrics)
        updateKeyAppearanceIfNeeded(metrics: metrics)
        refreshSuggestions()
    }

    private struct KeyboardAppearanceState: Equatable {
        let shifted: Bool
        let capsLocked: Bool
        let mode: KeyboardMode
        let showsSpaceIntro: Bool
        let spaceCaption: String
        let style: UIUserInterfaceStyle
        let minimumKeyHeight: CGFloat
    }

    private var lastAppearanceState: KeyboardAppearanceState?

    /// Restyling all ~30 keys runs on every keypress via `refreshKeyboard`, yet a
    /// plain character press changes nothing visible. Skip the loop unless the
    /// state that actually drives key appearance changed.
    private func updateKeyAppearanceIfNeeded(metrics: KeyboardMetrics) {
        let state = KeyboardAppearanceState(
            shifted: shifted,
            capsLocked: capsLocked,
            mode: keyboardMode,
            showsSpaceIntro: showsSpaceLanguageIntro && !isEmojiSearchActive,
            spaceCaption: spaceCaption,
            style: traitCollection.userInterfaceStyle,
            minimumKeyHeight: metrics.minimumKeyHeight
        )
        guard state != lastAppearanceState else { return }
        lastAppearanceState = state

        for button in keyButtons {
            button.updateAppearance(
                shifted: state.shifted,
                traitCollection: traitCollection,
                metrics: metrics,
                showsSpaceIntro: state.showsSpaceIntro,
                spaceCaption: state.spaceCaption,
                capsLocked: state.capsLocked
            )
        }
    }

    /// Enqueues a suggestion query, cancelling whichever one it supersedes. Only for
    /// work whose result the next keystroke invalidates — never for learning or
    /// persistence, which must always complete.
    private func scheduleSuggestionQuery(_ body: @escaping @Sendable () -> Void) {
        pendingSuggestionWork?.cancel()
        let work = DispatchWorkItem(block: body)
        pendingSuggestionWork = work
        engineQueue.async(execute: work)
    }

    private func refreshSuggestions() {
        #if DEBUG
        measureMain("refreshSuggestions") { refreshSuggestionsBody() }
        #else
        refreshSuggestionsBody()
        #endif
    }

    private func refreshSuggestionsBody() {
        suggestionGeneration &+= 1
        let generation = suggestionGeneration
        let engine = self.engine
        activeCursorWord = nil

        if composer.hasActiveInput {
            // The deterministic preview is already known synchronously; show it
            // immediately (not yet quoted — its dictionary status is unknown until the
            // async result below), then fill in autocorrect candidates off the main
            // thread so the FST traversal never blocks typing.
            deterministicIsOOV = false
            updateCompositionSuggestionBar()
            let buffer = composer.romanBuffer
            let composerGeneration = composer.generation
            let limit = composer.autocorrectFetchLimit
            let autoInsert = keyboardPreferences.autoInsertTopCorrection
            let shownWord = composer.preview
            scheduleSuggestionQuery { [weak self] in
                let candidates = engine.compositionSuggestions(for: buffer, limit: limit)
                // The literal's frequency drives both the native-style "keep my
                // spelling" quote (0 = not a word) and, with the detailed records'
                // provenance, the auto-insert gate (when enabled).
                let baselineFrequency = shownWord.isEmpty ? 0 : engine.wordFrequency(shownWord)
                let detailed = autoInsert
                    ? engine.detailedCorrections(for: buffer, limit: limit)
                    : []
                Task { @MainActor in
                    guard let self, self.suggestionGeneration == generation else { return }
                    self.deterministicIsOOV = !shownWord.isEmpty && baselineFrequency == 0
                    self.composer.mergeAutocorrectCandidates(candidates, generation: composerGeneration)
                    self.composer.resolveAutocorrectTarget(
                        autoInsertEnabled: autoInsert,
                        baselineFrequency: baselineFrequency,
                        detailedCorrections: detailed,
                        isProtectedWord: { self.learnedWordStore.isProtected($0) }
                    )
                    self.updateCompositionSuggestionBar()
                }
            }
            return
        }

        let contextBeforeInput = textDocumentProxy.documentContextBeforeInput ?? ""
        guard contextBeforeInput.contains(where: { !$0.isWhitespace }) else {
            suggestionBar.update(suggestions: [], emojis: carriedEmojis)
            return
        }

        // Cursor sitting inside an already-committed word (a word character immediately
        // precedes it): offer corrections for that word, not next-word suggestions.
        let contextAfterInput = textDocumentProxy.documentContextAfterInput ?? ""
        if let cursorWord = CursorWordDetector.wordAtCursor(before: contextBeforeInput, after: contextAfterInput) {
            activeCursorWord = cursorWord
            let slots = suggestionSlotCount
            scheduleSuggestionQuery { [weak self] in
                let alternatives = engine
                    .wordAlternatives(for: cursorWord.word, limit: slots + 1)
                    .filter { !$0.isEmpty && $0 != cursorWord.word }
                    .prefix(slots)
                    .map { KeyboardSuggestion(text: $0, source: .autocorrect) }
                Task { @MainActor in
                    guard let self, self.suggestionGeneration == generation else { return }
                    self.suggestionBar.update(suggestions: alternatives, emojis: self.carriedEmojis)
                }
            }
            return
        }

        // The autosuggest session accumulates as the user types left-to-right; it
        // reflects where typing stopped, not where the cursor is, and it never rewinds.
        // So it's only trustworthy at the end of the text. With the cursor moved into
        // earlier text, it buries the cursor-accurate context lookup — use that alone.
        let cursorAtEnd = (textDocumentProxy.documentContextAfterInput ?? "").isEmpty
        let slots = suggestionSlotCount
        // Fetch a little deeper than the strip can show so dedup between the session
        // and context sources still leaves a full row.
        let fetchLimit = slots * 2
        scheduleSuggestionQuery { [weak self] in
            let contextSuggestions = engine
                .autosuggestSuggestions(for: contextBeforeInput, limit: fetchLimit)
                .filter { !$0.isEmpty }
                .map { KeyboardSuggestion(text: $0, source: .autosuggest) }
            let merged: [KeyboardSuggestion]
            if cursorAtEnd {
                let sessionSuggestions = engine
                    .autosuggestSessionSuggestions(limit: fetchLimit)
                    .map { KeyboardSuggestion(text: $0, source: .autosuggest) }
                merged = KeyboardComposer.mergeSuggestions(
                    primary: sessionSuggestions,
                    fallback: contextSuggestions,
                    limit: slots
                )
            } else {
                merged = Array(contextSuggestions.prefix(slots))
            }
            Task { @MainActor in
                guard let self, self.suggestionGeneration == generation else { return }
                self.suggestionBar.update(suggestions: merged, emojis: self.carriedEmojis)
            }
        }
    }

    private func showSpaceLanguageIntro() {
        spaceLanguageIntroDismissal?.cancel()
        showsSpaceLanguageIntro = true
        refreshKeyboard()

        let dismissal = DispatchWorkItem { [weak self] in
            guard let self else { return }
            showsSpaceLanguageIntro = false
            for button in keyButtons where button.key == .space {
                UIView.transition(
                    with: button,
                    duration: 0.22,
                    options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]
                ) {
                    button.updateAppearance(
                        shifted: self.shifted,
                        traitCollection: self.traitCollection,
                        metrics: self.currentMetrics,
                        showsSpaceIntro: false,
                        spaceCaption: self.spaceCaption,
                        capsLocked: self.capsLocked
                    )
                }
            }
        }
        spaceLanguageIntroDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.35, execute: dismissal)
    }

    private func handleKeyTouchDown(_ key: KeyboardKey) {
        if isEmojiSearchActive, key == .backspace {
            beginEmojiSearchBackspacePress()
            return
        }

        if key == .backspace {
            beginBackspacePress()
        } else {
            feedbackController.keyTouched(key)
        }
    }

    private func handleKeyRelease(_ key: KeyboardKey) {
        if key == .backspace {
            endBackspacePress()
        }
    }

    private func handleKeyPress(_ key: KeyboardKey) {
        #if DEBUG
        KeystrokeProfile.shared.beginKeystroke()
        defer { KeystrokeProfile.shared.endKeystroke() }
        #endif
        if isEmojiSearchActive {
            if key == .backspace {
                endBackspacePress()
                return
            }
            handleEmojiSearchKeyPress(key)
            refreshKeyboard()
            return
        }

        switch key {
        case let .character(value):
            // The next letter starts a new word, so the previous word's emoji stop
            // being relevant — from here the composing path supplies its own.
            carriedEmojis = []
            #if DEBUG
            KeystrokeProfile.shared.measureEngine { composer.append(shifted ? value.uppercased() : value) }
            #else
            composer.append(shifted ? value.uppercased() : value)
            #endif
            shifted = capsLocked
            refreshCompositionPreview()
        case let .symbol(symbol):
            // A symbol that is part of Bangla's roman orthography joins the word
            // being composed rather than ending it. Today that is only the colon,
            // which is how bisarga is typed: `du` `:` `kho` is দুঃখ.
            //
            // Without this bisarga is simply unreachable. `insertLiteralSymbol`
            // commits the composition first, so the engine only ever saw `du` and
            // then a separate `:` — it never got `du:kho` as one token, and no
            // sequence of keys on this keyboard could produce ঃ.
            if symbol.role == .literal,
               Self.compositionJoiningSymbols.contains(symbol.output),
               composer.hasActiveInput {
                composer.append(symbol.output)
                refreshCompositionPreview()
                return
            }
            switch symbol.role {
            case .sentenceTerminator:
                insertSentenceTerminator(symbol.output)
            case .literal:
                insertLiteralSymbol(symbol.output)
            }
        case .space:
            handleSpaceKey()
        case .returnKey:
            if !commitActiveInputIfNeeded(trailingText: "\n") {
                engine.clearAutosuggestSession()
                performTextUpdate {
                    textDocumentProxy.insertText("\n")
                }
            }
        case .backspace:
            backspaceRepeater.end()
        case .shift:
            shifted.toggle()
        case let .modeSwitch(value):
            switch value {
            case "123", ".?123":
                keyboardMode = .numbers
            case "#+=":
                keyboardMode = .symbols
            default:
                keyboardMode = .letters
            }
            shifted = false
            capsLocked = false
            reloadKeyboardRows()
        case .emoji:
            showEmojiPanel()
        case .globe:
            advanceToNextInputMode()
        case .tab:
            textDocumentProxy.insertText("\t")
        case .capsLock:
            capsLocked.toggle()
            shifted = capsLocked
        case .hideKeyboard:
            dismissKeyboard()
        }
        previousKeyWasSpace = key == .space
        refreshKeyboard()
    }

    private func showEmojiPanel() {
        if composer.hasActiveInput {
            _ = commitActiveInputIfNeeded()
        }
        showsEmojiPanel = true
        isEmojiSearchActive = false
        emojiSearchQuery = ""
        emojiPanelView.configure(
            dataStore: emojiDataStore,
            recentEmojis: emojiRecentStore.load()
        )
    }

    private func hideEmojiPanel() {
        showsEmojiPanel = false
        isEmojiSearchActive = false
        emojiSearchQuery = ""
        emojiPanelView.setSearchQuery("")
        emojiPanelView.setSearchActive(false)
        keyboardMode = .letters
        shifted = false
        reloadKeyboardRows()
    }

    private func enterEmojiSearch() {
        guard showsEmojiPanel else { return }
        isEmojiSearchActive = true
        emojiSearchQuery = ""
        emojiSearchLanguage = keyboardPreferences.defaultEmojiSearchLanguage
        shifted = false
        keyboardMode = .letters
        emojiPanelView.setSearchActive(true)
        syncEmojiSearchQuery()
        reloadKeyboardRows()
        // Search needs a taller keyboard than browsing does — it draws the whole
        // alphabetic keyboard below the results — and nothing here was asking for
        // it. The panel kept the browsing height, the keyboard took what it needed
        // from the bottom, and the results grid was left with 63..63: zero points.
        updateKeyboardHeightConstraintIfReady()
        applyLayoutMetricsIfNeeded(force: true)
    }

    private func exitEmojiSearch() {
        isEmojiSearchActive = false
        emojiSearchQuery = ""
        emojiPanelView.setSearchQuery("")
        emojiPanelView.setSearchActive(false)
        keyboardMode = .letters
        shifted = false
        reloadKeyboardRows()
        updateKeyboardHeightConstraintIfReady()
        applyLayoutMetricsIfNeeded(force: true)
    }

    private func handleEmojiSearchKeyPress(_ key: KeyboardKey) {
        switch key {
        case let .character(value):
            emojiSearchQuery.append(shifted ? value.uppercased() : value)
            shifted = false
            syncEmojiSearchQuery()
        case let .symbol(symbol):
            emojiSearchQuery.append(symbol.output)
            syncEmojiSearchQuery()
        case .space:
            if emojiSearchQuery.last?.isWhitespace != true {
                emojiSearchQuery.append(" ")
                syncEmojiSearchQuery()
            }
        case .returnKey, .emoji, .globe, .hideKeyboard:
            exitEmojiSearch()
        case .tab, .capsLock:
            break
        case .backspace:
            if emojiSearchQuery.isEmpty {
                exitEmojiSearch()
            } else {
                emojiSearchQuery.removeLast()
                syncEmojiSearchQuery()
            }
        case .shift:
            shifted.toggle()
        case let .modeSwitch(value):
            switch value {
            case "123", ".?123":
                keyboardMode = .numbers
            case "#+=":
                keyboardMode = .symbols
            default:
                keyboardMode = .letters
            }
            shifted = false
            reloadKeyboardRows()
        }
    }

    private func syncEmojiSearchQuery() {
        // In Bangla mode the typed roman is transliterated into the Bangla query
        // shown in the field and searched against the Bangla index.
        let query = emojiSearchLanguage == .bangla
            ? engine.transliterate(emojiSearchQuery)
            : emojiSearchQuery
        emojiPanelView.setSearchQuery(query, language: emojiSearchLanguage)
    }

    private func beginEmojiSearchBackspacePress() {
        guard !backspaceRepeater.isActive else { return }

        guard performEmojiSearchBackspace() else { return }
        feedbackController.keyTouched(.backspace)
        backspaceRepeater.begin { [weak self] _ in
            guard let self else { return }
            guard performEmojiSearchBackspace() else {
                endBackspacePress()
                return
            }
            feedbackController.backspaceRepeated(unit: .character)
        }
    }

    @discardableResult
    private func performEmojiSearchBackspace() -> Bool {
        guard !emojiSearchQuery.isEmpty else {
            exitEmojiSearch()
            refreshKeyboard()
            return false
        }

        emojiSearchQuery.removeLast()
        syncEmojiSearchQuery()
        refreshKeyboard()
        return true
    }

    private func beginBackspacePress() {
        guard !backspaceRepeater.isActive else { return }

        guard performBackspace(unit: .character, requiresTextEvidence: true) else { return }
        feedbackController.keyTouched(.backspace)
        backspaceRepeater.begin { [weak self] unit in
            guard let self else { return }
            // Honour the escalation the policy hands us: a sustained hold graduates
            // from characters to whole words, native-style. Previously this arm threw
            // the unit away and always deleted one character, so clearing several
            // words meant holding backspace forever.
            performBackspace(unit: unit, requiresTextEvidence: false)
            feedbackController.backspaceRepeated(unit: unit)
        }
    }

    private func endBackspacePress() {
        backspaceRepeater.end()
    }

    @discardableResult
    private func performBackspace(
        unit: BackspaceDeletionUnit,
        requiresTextEvidence: Bool = true
    ) -> Bool {
        if composer.hasActiveInput {
            switch unit {
            case .character:
                if composer.deleteBackward() {
                    refreshCompositionPreview()
                    return true
                }
            case .word, .sentence, .availableContext:
                composer.clear()
                performTextUpdate {
                    compositionController.clearComposition(in: documentEditor)
                }
                refreshSuggestions()
                return true
            }
        }

        let contextBeforeInput = textDocumentProxy.documentContextBeforeInput
        guard !requiresTextEvidence || textDocumentProxy.hasText || contextBeforeInput?.isEmpty == false else {
            refreshSuggestions()
            return false
        }

        if unit == .character || contextBeforeInput?.isEmpty != false {
            performTextUpdate {
                textDocumentProxy.deleteBackward()
            }
            engine.clearAutosuggestSession()
            refreshSuggestions()
            return true
        }

        let deleteCount = BackspaceDeletionPlanner.deleteCount(
            before: contextBeforeInput ?? "",
            unit: unit
        )
        guard deleteCount > 0 else {
            performTextUpdate {
                textDocumentProxy.deleteBackward()
            }
            refreshSuggestions()
            return true
        }

        performTextUpdate {
            for _ in 0..<deleteCount {
                textDocumentProxy.deleteBackward()
            }
        }
        engine.clearAutosuggestSession()
        refreshSuggestions()
        return true
    }

    @discardableResult
    private func commitActiveInputIfNeeded(trailingText: String = "") -> Bool {
        guard composer.hasActiveInput else { return false }
        // Captured BEFORE the commit clears the composer. The emoji belong to the
        // word just typed and stay on screen after it commits, so a space does not
        // snatch away the one suggestion the user was reaching for.
        carriedEmojis = resolvedEmojiSuggestions()
        guard let committed = composer.commitActiveInput() else { return false }
        performTextUpdate {
            compositionController.commit(finalText: committed, trailingText: trailingText, in: documentEditor)
        }
        observeCommittedToken(committed)
        observeAutosuggestBoundary(trailingText)
        return true
    }

    /// দাঁড়ি `।`, `?`, `!`: finalize any active composition, insert the glyph,
    /// and reset the autosuggest session for a new sentence. Handled purely on
    /// the iOS layer — the engine is not consulted.
    private func insertSentenceTerminator(_ output: String) {
        if !commitActiveInputIfNeeded(trailingText: output) {
            performTextUpdate {
                textDocumentProxy.insertText(output)
            }
        }
        engine.clearAutosuggestSession()
    }

    /// Any other symbol (digits, `,`, `.`, `৳`, brackets, quotes, dashes…):
    /// finalize active composition, otherwise insert with Apple-style smart
    /// punctuation (`--`→—, `...`→…, straight→curly quotes).
    /// Symbols that continue a composition instead of committing it, but only
    /// while one is already active.
    ///
    /// Scoped deliberately. A standalone colon stays a literal colon, so ordinary
    /// punctuation is unaffected; it only becomes bisarga when it lands inside a
    /// word the engine is already transliterating. The engine settles the rest:
    /// 0.9.2 keeps a colon between digits literal, so `9:45` is ৯:৪৫ even though
    /// the same key produces ঃ in দুঃখ.
    private static let compositionJoiningSymbols: Set<String> = [":"]

    private func insertLiteralSymbol(_ output: String) {
        if commitActiveInputIfNeeded(trailingText: output) {
            return
        }
        let contextBefore = textDocumentProxy.documentContextBeforeInput ?? ""
        let substitution = SmartPunctuation.literalSubstitution(for: output, contextBefore: contextBefore)
        performTextUpdate {
            applySmartPunctuation(substitution)
        }
    }

    private func handleSpaceKey() {
        let now = CACurrentMediaTime()
        let withinDoubleTapWindow = previousKeyWasSpace
            && now - lastSpaceKeyTime <= Self.dariDoubleSpaceWindow
        lastSpaceKeyTime = now
        if commitActiveInputIfNeeded(trailingText: " ") {
            return
        }
        let contextBefore = textDocumentProxy.documentContextBeforeInput ?? ""
        // Double-space → dari ends a sentence: only at the end of the text, and only
        // as a quick double-tap, matching the native shortcut. A slow second space,
        // or any space mid-text, types a plain space — always.
        let cursorAtEnd = (textDocumentProxy.documentContextAfterInput ?? "").isEmpty
        if cursorAtEnd, withinDoubleTapWindow,
           let substitution = SmartPunctuation.doubleSpaceSubstitution(contextBefore: contextBefore) {
            performTextUpdate {
                applySmartPunctuation(substitution)
            }
            return
        }
        performTextUpdate {
            insertSpace()
        }
    }

    private func applySmartPunctuation(_ substitution: SmartPunctuationResult) {
        for _ in 0..<substitution.deleteBefore {
            textDocumentProxy.deleteBackward()
        }
        textDocumentProxy.insertText(substitution.insertion)
    }

    private func refreshCompositionPreview() {
        performTextUpdate {
            compositionController.setComposition(composer.preview, in: documentEditor)
        }
    }

    /// Show the composition candidates, quoting the literal when it is not a dictionary
    /// word (native-style "keep my spelling"), so the first slot always reads as the
    /// user's own text and stays tappable. OOV-ness subsumes the auto-insert case —
    /// auto-insert only ever targets a non-lexicon literal.
    private func updateCompositionSuggestionBar() {
        suggestionBar.update(
            suggestions: composer.activeSuggestions,
            emojis: resolvedEmojiSuggestions(),
            quotedText: deterministicIsOOV ? composer.preview : nil
        )
    }

    /// Stop tracking the word in progress. The word is ordinary document text, so this
    /// touches nothing — it just means the next keystroke starts a fresh word. Call it
    /// whenever the composition is no longer ours to rewrite: the cursor moved, the
    /// keyboard is switching away, or the host changed the field. Because there is no
    /// marked region, there is nothing to strand and the cursor is never trapped.
    private func resetCompositionBookkeeping() {
        // Invalidate before the next context callback or appearance. A query can
        // already have posted its completion to the main queue; cancelling the
        // work item alone cannot prevent that result from restoring stale choices.
        suggestionGeneration &+= 1
        pendingSuggestionWork?.cancel()
        pendingSuggestionWork = nil
        activeCursorWord = nil
        deterministicIsOOV = false
        carriedEmojis = []
        suggestionBar.update(suggestions: [])
        composer.clear()
        compositionController.resetHostState()
        previousKeyWasSpace = false
    }

    private func commitMarkedSuggestion(_ text: String) {
        performTextUpdate {
            compositionController.commitSuggestion(text, in: documentEditor)
        }
    }

    /// Marks proxy edits so our own text/selection callbacks are ignored. The edit and
    /// the callbacks it triggers are synchronous, so the flag need only span this call —
    /// the same contract the text-change delegates already rely on.
    private func performTextUpdate(_ update: () -> Void) {
        isUpdatingTextProxy = true
        defer { isUpdatingTextProxy = false }
        update()
    }

    private func insertSpace() {
        compositionController.insertSpace(in: documentEditor)
    }

    private func restorePersonalAutosuggest() {
        guard let snapshot = personalAutosuggestStore.loadSnapshot() else {
            return
        }
        if !engine.importPersonalAutosuggestSnapshot(snapshot) {
            personalAutosuggestStore.removeSnapshot()
        }
    }

    /// Learn from a committed word. `keep` marks the strong signal — the user tapped
    /// their quoted spelling to reject a correction — versus an ordinary commit.
    private func observeCommittedToken(_ token: String, keep: Bool = false) {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        // Every bridge call here is off the space-key critical path, including the
        // commit itself: it takes the autosuggest handle, which the snapshot export
        // below also holds for as long as it takes to serialize. Committing on the
        // main thread meant one space key could block on the previous space key's
        // export. Ordering is preserved because engineQueue is serial.
        let engine = self.engine
        let store = self.personalAutosuggestStore
        let learnedWordStore = self.learnedWordStore
        engineQueue.async {
            // Word protection FIRST, and independent of autosuggest: they are unrelated
            // subsystems, and an unavailable autosuggest handle must not silence
            // learning. On iOS the artifact is always bundled so this never bit here,
            // but a straight port to a client that ships no autosuggest learned nothing
            // at all (issue #19).
            //
            // An explicit keep is never gated on the lexicon. The `isLexiconWord` guard
            // is right for the weak signal — it stops the store filling with words that
            // were never at risk — but wrong for the strong one: the user tapping their
            // own quoted spelling is saying "leave this alone", and whether the lexicon
            // knows the word is beside the point. Gating both silenced protection for
            // exactly the main case, because the frequency-ratio gate exists to correct
            // RARE LEXICON WORDS: মানুস (49) → মানুষ (95278) and বন্দু (25) → বন্ধু
            // (21081) are both lexicon entries, so a keep on either stored nothing and
            // the same correction came back forever, with no way to stop it.
            if keep {
                learnedWordStore.reinforce(token, signal: .explicitKeep)
            } else if !engine.isLexiconWord(token) {
                learnedWordStore.reinforce(token, signal: .commit)
            }
            guard engine.commitAutosuggestToken(token) else { return }
            if let snapshot = engine.exportPersonalAutosuggestSnapshot() {
                store.saveSnapshot(snapshot)
            }
        }
    }

    private func observeAutosuggestBoundary(_ text: String) {
        guard !text.isEmpty else {
            return
        }
        if text.contains(where: \.isNewline) {
            engine.clearAutosuggestSession()
        }
    }

    private var documentEditor: DocumentProxyEditor {
        DocumentProxyEditor(proxy: textDocumentProxy)
    }

    private struct MetricsCacheKey: Equatable {
        let size: CGSize
        let verticalSizeClass: UIUserInterfaceSizeClass
    }

    private var metricsCache: (key: MetricsCacheKey, value: KeyboardMetrics)?

    private var currentMetrics: KeyboardMetrics {
        // Metrics MUST derive from the intended height, never from view.bounds.height:
        // the suggestion strip's required height feeds the view's fitting size, which
        // is what the system sizes the container by. Basing metrics on current bounds
        // creates a feedback loop (bounds→strip→fitting→bounds) that locks the
        // container at whatever it currently is and makes height changes impossible —
        // measured as the 290/314 "phantom grants" that were our own clamps echoed.
        let size: CGSize
        let bounds = view.bounds.size
        if bounds.width > 0 {
            size = CGSize(width: bounds.width, height: preferredKeyboardHeight)
        } else {
            let screenSize = view.window?.screen.bounds.size ?? UIScreen.main.bounds.size
            size = CGSize(width: min(screenSize.width, screenSize.height), height: preferredKeyboardHeight)
        }

        // KeyboardTheme.metrics depends only on the size and vertical size class,
        // yet it is read several times per keypress; memoize within a layout pass.
        let key = MetricsCacheKey(size: size, verticalSizeClass: traitCollection.verticalSizeClass)
        if let cached = metricsCache, cached.key == key {
            return cached.value
        }
        let value = KeyboardTheme.metrics(
            for: size,
            traitCollection: traitCollection,
            screenSize: screenSize
        )
        metricsCache = (key, value)
        return value
    }

    private var preferredKeyboardHeight: CGFloat {
        KeyboardTheme.preferredKeyboardHeight(
            for: view.window?.screen.bounds.size ?? UIScreen.main.bounds.size,
            traitCollection: traitCollection
        )
    }

    private var preferredActiveKeyboardHeight: CGFloat {
        #if DEBUG
        if let debugAskOverride {
            return debugAskOverride
        }
        #endif
        let screenSize = view.window?.screen.bounds.size ?? UIScreen.main.bounds.size
        if showsEmojiPanel {
            // Search mode draws the alphabetic keyboard inside the panel, so the
            // results only exist in whatever height is left over. Ask for the
            // keyboard PLUS the search field and one row of results, rather than
            // letting the results be the remainder — on iPad the remainder was
            // 10pt and the panel showed no results at all.
            if isEmojiSearchActive {
                // Search swaps the suggestion strip for a search field plus a row of
                // results, and draws the whole alphabetic keyboard below them. Asking
                // for the browsing height left the results grid at 63..63 — literally
                // zero points — on an iPhone, and 10pt on an iPad.
                return KeyboardTheme.preferredKeyboardHeight(
                    for: screenSize,
                    traitCollection: traitCollection
                ) + EmojiPanelView.searchChromeHeight - currentMetrics.suggestionHeight
            }
            return KeyboardTheme.preferredEmojiKeyboardHeight(
                for: screenSize,
                traitCollection: traitCollection
            )
        }
        return KeyboardTheme.preferredKeyboardHeight(
            for: screenSize,
            traitCollection: traitCollection
        )
    }

    private func applyLayoutMetricsIfNeeded(force: Bool = false) {
        let size = view.bounds.size
        let preferredHeight = preferredActiveKeyboardHeight
        let metricSize = CGSize(width: size.width, height: preferredKeyboardHeight)
        let shouldReloadRows = force || metricSize != lastAppliedMetricSize
        guard shouldReloadRows || keyboardHeightConstraint?.constant != preferredHeight else {
            return
        }
        lastAppliedMetricSize = metricSize

        let metrics = currentMetrics
        let insets = metrics.keyboardInsets
        updateKeyboardHeightConstraintIfReady()
        keyboardStack.spacing = metrics.rowSpacing
        keyboardStackLeadingConstraint?.constant = 0
        keyboardStackTrailingConstraint?.constant = 0
        keyboardStackTopConstraint?.constant = keyboardTopConstant(for: metrics)
        keyboardStackBottomConstraint?.constant = -insets.bottom
        keyboardStackHeightConstraint?.constant = keyRowsHeight(for: metrics)
        view.backgroundColor = .clear
        suggestionBar.applyMetrics(metrics)
        // Rotating an iPad can move it to a layout family with a different slot
        // count, so the composer's candidate limit follows the strip.
        composer.compositionSuggestionLimit = metrics.suggestionSlotCount

        if shouldReloadRows {
            reloadKeyboardRows()
            refreshSuggestions()
            return
        }

        for case let rowView as KeyboardRowView in keyboardStack.arrangedSubviews {
            rowView.metrics = metrics
            rowView.setNeedsLayout()
        }
        for (index, constraint) in rowHeightConstraints.enumerated() {
            constraint.constant = rowHeight(atIndex: index, metrics: metrics)
        }
        // Row heights can change under the same set of buttons (rotation), and a
        // short row sizes its type to itself, so refresh that before redrawing.
        for (index, subview) in keyboardStack.arrangedSubviews.enumerated() {
            guard let rowView = subview as? KeyboardRowView else { continue }
            let heightOfRow = rowHeight(atIndex: index, metrics: metrics)
            for button in rowView.keyButtons {
                button.rowHeight = heightOfRow
            }
        }
        for button in keyButtons {
            button.updateAppearance(
                shifted: shifted,
                traitCollection: traitCollection,
                metrics: metrics,
                showsSpaceIntro: showsSpaceLanguageIntro && !isEmojiSearchActive,
                spaceCaption: spaceCaption,
                capsLocked: capsLocked
            )
        }
        updateKeyboardTouchRegions()
    }

    private var spaceCaption: String {
        isEmojiSearchActive ? "En" : "বাংলা"
    }

    private func keyboardTopConstant(for metrics: KeyboardMetrics) -> CGFloat {
        guard isEmojiSearchActive else {
            return metrics.keyboardInsets.top
        }

        let keyRowsHeight = keyRowsHeight(for: metrics)
        // The floor is what emoji SEARCH needs above the keys: the search field and
        // one row of results. It used to be `suggestionHeight + top`, which is the
        // strip search doesn't draw — so the keys were free to sit directly under
        // the field and the results grid got zero height.
        let targetTop = max(
            EmojiPanelView.searchChromeHeight,
            view.bounds.height - keyRowsHeight - metrics.keyboardInsets.bottom
        )
        return targetTop - metrics.suggestionHeight
    }

    /// Where a command key's glyph sits inside its key on iPad.
    ///
    /// Native pins them to the bottom-OUTER corner, so the modifiers hug the
    /// outside edges of the keyboard: the side is simply which half of the row the
    /// key is in, which is what makes a left shift and a right shift — the same
    /// key — point their glyphs at opposite edges. Letters and symbols are never
    /// moved; they stay centred with the flick offset applied.
    private func padGlyphAlignment(
        for key: KeyboardKey,
        at index: Int,
        of count: Int
    ) -> KeyboardKeyButton.GlyphAlignment {
        guard isPadIdiom else { return .centred }
        switch key {
        case .character, .symbol, .space:
            return .centred
        default:
            // The index, not the key: a left shift and a right shift are the same
            // key and must point their glyphs at opposite edges.
            return Double(index) >= Double(count) / 2 ? .bottomTrailing : .bottomLeading
        }
    }

    /// Row heights are uniform everywhere except the 13-inch iPad's number row,
    /// which native draws 15.5pt shorter than the letter rows below it.
    private func rowHeight(atIndex index: Int, metrics: KeyboardMetrics) -> CGFloat {
        index == 0 && metrics.padNumberRowHeight > 0
            ? metrics.padNumberRowHeight
            : metrics.minimumKeyHeight
    }

    private func keyRowsHeight(for metrics: KeyboardMetrics) -> CGFloat {
        let count = KeyboardLayoutProvider.rows(
            for: keyboardMode,
            includesGlobeKey: needsInputModeSwitchKey,
            isPad: isPadIdiom,
            width: Double(layoutWidth),
            family: padFamily,
            landscape: padIsLandscape,
            margin: Double(metrics.keyboardInsets.left),
            gap: Double(metrics.keySpacing)
        ).count
        guard count > 0 else { return 0 }
        let keys = (0..<count).reduce(CGFloat(0)) { $0 + rowHeight(atIndex: $1, metrics: metrics) }
        return keys + CGFloat(count - 1) * metrics.rowSpacing
    }

    private func updateKeyboardHeightConstraintIfReady() {
        guard viewWillAppearWasCalled, let keyboardHeightConstraint else {
            return
        }

        keyboardHeightConstraint.constant = preferredActiveKeyboardHeight
        if !keyboardHeightConstraint.isActive {
            keyboardHeightConstraint.isActive = true
        }
    }

    private func beginTouch(on key: KeyboardKey) {
        activeTouchKey = key
        setHighlightedKey(key)
        handleKeyTouchDown(key)
    }

    private func moveTouch(to key: KeyboardKey) {
        guard key != activeTouchKey else { return }
        if let activeTouchKey {
            handleKeyRelease(activeTouchKey)
        }
        activeTouchKey = key
        setHighlightedKey(key)
        handleKeyTouchDown(key)
    }

    private func endTouch(on key: KeyboardKey?) {
        let finalKey = key ?? activeTouchKey
        if let finalKey, finalKey != activeTouchKey {
            moveTouch(to: finalKey)
        }
        if let activeTouchKey {
            handleKeyRelease(activeTouchKey)
        }
        clearHighlightedKey()
        activeTouchKey = nil
        if let finalKey {
            handleKeyPress(finalKey)
        }
    }

    private func cancelTouch() {
        if let activeTouchKey {
            handleKeyRelease(activeTouchKey)
        }
        clearHighlightedKey()
        activeTouchKey = nil
    }

    private func setHighlightedKey(_ key: KeyboardKey) {
        guard highlightedKeyButton?.key != key else { return }
        highlightedKeyButton?.isHighlighted = false
        let keyButton = keyButtons.first { $0.key == key }
        keyButton?.isHighlighted = true
        highlightedKeyButton = keyButton
        if let keyButton {
            showKeyPreview(for: keyButton)
        } else {
            hideKeyPreview(animated: false)
        }
    }

    private func clearHighlightedKey() {
        highlightedKeyButton?.isHighlighted = false
        highlightedKeyButton = nil
        scheduleKeyPreviewDismissal()
    }

    private func showKeyPreview(for button: KeyboardKeyButton) {
        keyPreviewDismissal?.cancel()
        keyPreviewDismissal = nil

        // iPad draws no key-press callout. Native does not: the popover is an
        // iPhone affordance, where the finger covers the key it is pressing. iPad
        // keys are wide enough to read around a fingertip, and the flick animation
        // is what a key does under the finger there instead.
        guard !isPadIdiom else { return }

        let metrics = currentMetrics
        guard
            metrics.keyPreviewHeight > 0,
            let previewText = button.previewText,
            !previewText.isEmpty
        else {
            hideKeyPreview(animated: false)
            return
        }

        keyPreviewCallout.update(
            text: previewText,
            metrics: metrics,
            traitCollection: traitCollection
        )

        let size = KeyboardKeyPreviewCallout.preferredSize(
            for: button.bounds,
            metrics: metrics
        )
        let frameInView = button.convert(button.bounds, to: view)
        let desiredX = frameInView.midX - size.width / 2
        let x = min(max(0, desiredX), max(0, view.bounds.width - size.width))
        // Flush above the pressed key, like native (its preview never overlaps the
        // key face; verified on iOS 27 device screenshots).
        let y = min(
            max(0, frameInView.minY - size.height),
            max(0, view.bounds.height - size.height)
        )

        keyPreviewCallout.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        view.bringSubviewToFront(keyPreviewCallout)

        guard keyPreviewCallout.isHidden || keyPreviewCallout.alpha < 1 else {
            keyPreviewCallout.transform = .identity
            return
        }

        keyPreviewCallout.isHidden = false
        keyPreviewCallout.alpha = 0
        keyPreviewCallout.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        UIView.animate(
            withDuration: 0.055,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
        ) {
            self.keyPreviewCallout.alpha = 1
            self.keyPreviewCallout.transform = .identity
        }
    }

    private func scheduleKeyPreviewDismissal() {
        guard !keyPreviewCallout.isHidden else { return }
        keyPreviewDismissal?.cancel()
        let dismissal = DispatchWorkItem { [weak self] in
            self?.hideKeyPreview(animated: true)
        }
        keyPreviewDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055, execute: dismissal)
    }

    private func hideKeyPreview(animated: Bool) {
        keyPreviewDismissal?.cancel()
        keyPreviewDismissal = nil
        guard !keyPreviewCallout.isHidden else { return }

        let finish = {
            self.keyPreviewCallout.alpha = 0
            self.keyPreviewCallout.transform = .identity
            self.keyPreviewCallout.isHidden = true
        }

        guard animated else {
            finish()
            return
        }

        UIView.animate(
            withDuration: 0.09,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseIn]
        ) {
            self.keyPreviewCallout.alpha = 0
            self.keyPreviewCallout.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
        } completion: { _ in
            finish()
        }
    }

    private func updateKeyboardTouchRegions() {
        guard !keyboardStack.isHidden, keyboardTouchSurface.bounds.width > 0 else {
            keyboardTouchSurface.keyRows = []
            return
        }

        keyboardStack.layoutIfNeeded()
        let rows = keyboardStack.arrangedSubviews.compactMap { view -> [KeyboardTouchKeyRegion]? in
            guard let rowView = view as? KeyboardRowView else { return nil }
            let regions = rowView.keyRegions(in: keyboardTouchSurface)
            return regions.isEmpty ? nil : regions
        }
        keyboardTouchSurface.keyRows = rows
        // The full-bleed surface must not eat suggestion-bar taps.
        keyboardTouchSurface.keyAreaTop = suggestionBar.frame.maxY
        // Flick-down is an iPad affordance only, and only where a secondary is
        // actually drawn — see `showsSecondaryLabel`. A third of the key height
        // is far enough to be deliberate and short enough to stay on the key.
        // A sixth of the key, not a third. At a third this was 18.5pt in portrait
        // and 24.7 in landscape — roughly twice what native asks for, far enough
        // that the gesture reads as broken rather than absent.
        keyboardTouchSurface.flickThreshold = isPadIdiom && keyboardMode == .letters
            ? currentMetrics.minimumKeyHeight / 6
            : 0
    }
}

extension KeyboardViewController: KeyboardTouchSurfaceViewDelegate {
    func keyboardTouchSurface(_ view: KeyboardTouchSurfaceView, didBegin key: KeyboardKey) {
        beginTouch(on: key)
    }

    func keyboardTouchSurface(_ view: KeyboardTouchSurfaceView, didMoveTo key: KeyboardKey) {
        moveTouch(to: key)
    }

    func keyboardTouchSurface(
        _ view: KeyboardTouchSurfaceView,
        didUpdateFlickProgress progress: CGFloat,
        on key: KeyboardKey
    ) {
        guard let button = keyButtons.first(where: { $0.key == key }) else { return }
        // Driven straight off the finger while dragging, so it tracks 1:1. Only the
        // release is animated, and only back to rest — a flick that fires replaces
        // the glyph anyway, and animating that would show the wrong character for
        // the length of the animation.
        if progress > 0 {
            button.flickProgress = progress
        } else if button.flickProgress != 0 {
            UIView.animate(withDuration: 0.14, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
                button.flickProgress = 0
            }
        }
    }

    func keyboardTouchSurface(
        _ view: KeyboardTouchSurfaceView,
        didEnd key: KeyboardKey?,
        flickedDown: Bool
    ) {
        // A flick on a key that has a secondary inserts the secondary instead of
        // the primary. Keys without one fall through to the normal tap so a
        // slightly downward press never becomes a dead touch.
        if flickedDown, let key, let secondary = key.padSecondary {
            keyButtons.first { $0.key == key }?.snapFlickToRest()
            endTouch(on: .symbol(secondary))
            return
        }
        endTouch(on: key)
    }

    func keyboardTouchSurfaceDidCancel(_ view: KeyboardTouchSurfaceView) {
        cancelTouch()
    }
}

extension KeyboardViewController: SuggestionBarViewDelegate {
    func suggestionBar(_ suggestionBar: SuggestionBarView, didSelectEmoji emoji: String) {
        feedbackController.suggestionAccepted()
        acceptEmojiSuggestion(emoji)
    }

    /// Long-press variant options — the emoji panel index loads lazily HERE (only
    /// on a long-press), never during typing.
    func suggestionBar(_ suggestionBar: SuggestionBarView, variantOptionsFor base: String) -> [EmojiItem] {
        guard let item = emojiDataStore.item(for: base) else { return [] }
        return emojiDataStore.variantOptions(for: item)
    }

    func suggestionBar(_ suggestionBar: SuggestionBarView, didPickEmojiVariant emoji: String, base: String) {
        feedbackController.suggestionAccepted()
        emojiVariantPreferenceStore.record(baseEmoji: base, selectedEmoji: emoji)
        acceptEmojiSuggestion(emoji)
    }

    /// Resolve each base suggestion emoji to the user's remembered skin tone — a
    /// dict lookup in the shared App Group store, no `EmojiDataStore` load.
    private func resolvedEmojiSuggestions() -> [EmojiSuggestion] {
        let preferences = emojiVariantPreferenceStore.load()
        return composer.activeEmojis.map { base in
            EmojiSuggestion(base: base, display: preferences[base] ?? base)
        }
    }

    func suggestionBar(_ suggestionBar: SuggestionBarView, didSelect suggestion: KeyboardSuggestion) {
        feedbackController.suggestionAccepted()
        if composer.hasActiveInput {
            // Native-style: every shown slot is tappable. Tapping the deterministic
            // literal keeps the user's spelling (a strong "I mean this word" signal);
            // tapping a correction replaces it. Either commits the tapped text in place
            // and finalizes the word.
            let keepsLiteral = suggestion.source == .deterministic
            commitMarkedSuggestion(suggestion.text)
            // Native-style: accepting a candidate finishes the word, so the
            // separator comes with it (quoted "keep my spelling" included).
            performTextUpdate {
                textDocumentProxy.insertText(" ")
            }
            composer.clear()
            observeCommittedToken(suggestion.text, keep: keepsLiteral)
            observeAutosuggestBoundary(" ")
        } else if let cursorWord = activeCursorWord {
            // A correction for the word the cursor sits in: replace that word in place.
            replaceCursorWord(cursorWord, with: suggestion.text)
            observeCommittedToken(suggestion.text)
        } else {
            performTextUpdate {
                compositionController.commitNextWordSuggestion(suggestion.text, in: documentEditor)
            }
            observeCommittedToken(suggestion.text)
            observeAutosuggestBoundary(" ")
        }
        refreshKeyboard()
    }

    /// Replace the already-committed word the cursor is in with a chosen alternative.
    /// Move the cursor to the word's end so the whole word is behind it, then swap it.
    private func replaceCursorWord(_ cursorWord: CursorWord, with replacement: String) {
        activeCursorWord = nil
        performTextUpdate {
            if !cursorWord.after.isEmpty {
                textDocumentProxy.adjustTextPosition(byCharacterOffset: cursorWord.after.utf16.count)
            }
            compositionController.replaceWordBeforeCursor(cursorWord.word, with: replacement, in: documentEditor)
        }
    }

    /// Tapping the inline emoji REPLACES the word being composed — the typed text
    /// was the emoji's query (native-style: "bhalobasha" + tap → ❤️, not
    /// "ভালোবাসা❤️"). The discarded query is not committed to autosuggest. Also
    /// feeds the emoji panel's recents.
    private func acceptEmojiSuggestion(_ emoji: String) {
        if composer.hasActiveInput {
            performTextUpdate {
                compositionController.clearComposition(in: documentEditor)
            }
            composer.clear()
        }
        performTextUpdate {
            textDocumentProxy.insertText(emoji)
        }
        // Taking the offer ends it. Without this the carried slot keeps offering the
        // same emoji after it has been inserted, and a second tap doubles it.
        carriedEmojis = []
        emojiRecentStore.record(emoji)
        emojiPanelView.recordRecentEmoji(emoji)
        refreshKeyboard()
    }
}

extension KeyboardViewController: EmojiPanelViewDelegate {
    func emojiPanelView(_ view: EmojiPanelView, didSelect item: EmojiItem) {
        feedbackController.suggestionAccepted()
        performTextUpdate {
            textDocumentProxy.insertText(item.emoji)
        }
        emojiRecentStore.record(item.emoji)
        view.recordRecentEmoji(item.emoji)
    }

    func emojiPanelViewDidRequestSearch(_ view: EmojiPanelView) {
        feedbackController.suggestionAccepted()
        enterEmojiSearch()
        refreshKeyboard()
    }

    func emojiPanelViewDidRequestClearSearch(_ view: EmojiPanelView) {
        feedbackController.suggestionAccepted()
        emojiSearchQuery = ""
        syncEmojiSearchQuery()
        refreshKeyboard()
    }

    func emojiPanelViewDidRequestKeyboard(_ view: EmojiPanelView) {
        feedbackController.suggestionAccepted()
        hideEmojiPanel()
        refreshKeyboard()
    }

    func emojiPanelViewDidBeginBackspace(_ view: EmojiPanelView) {
        beginBackspacePress()
    }

    func emojiPanelViewDidEndBackspace(_ view: EmojiPanelView) {
        endBackspacePress()
    }

    func emojiPanelViewDidToggleSearchLanguage(_ view: EmojiPanelView) {
        emojiSearchLanguage = emojiSearchLanguage.toggled
        feedbackController.suggestionAccepted()
        syncEmojiSearchQuery()
    }
}

private struct DocumentProxyEditor: TextDocumentEditing {
    let proxy: any UITextDocumentProxy

    // Every accessor below is a synchronous round-trip to the HOST app's process.
    // In DEBUG each one is timed and counted (see KeystrokeProfile) because the
    // reshape path can issue many per keypress.
    var contextBeforeInput: String? {
        #if DEBUG
        return KeystrokeProfile.shared.measureProxy(.context) { proxy.documentContextBeforeInput }
        #else
        return proxy.documentContextBeforeInput
        #endif
    }

    func insertText(_ text: String) {
        #if DEBUG
        KeystrokeProfile.shared.measureProxy(.insert) { proxy.insertText(text) }
        #else
        proxy.insertText(text)
        #endif
    }

    func deleteBackward() {
        #if DEBUG
        KeystrokeProfile.shared.measureProxy(.delete) { proxy.deleteBackward() }
        #else
        proxy.deleteBackward()
        #endif
    }
}

#if DEBUG
extension KeyboardViewController: KeyboardDebugCommandHandler {
    var canHandleDebugCommands: Bool {
        viewWillAppearWasCalled && viewIfLoaded?.window != nil
    }

    /// DEBUG-only. Drives the keyboard from the agentic control channel so tooling
    /// can switch keyboards, pages, and key materials without simulating touches.
    /// Compile-excluded from Release (see KeyboardDebugChannel).
    func handleDebugCommand(_ command: String, argument: String?) {
        switch command {
        case "advance":
            // The public API the globe key calls — cycle to the next keyboard.
            advanceToNextInputMode()
        case "mode":
            switch argument {
            case "numbers": keyboardMode = .numbers
            case "symbols": keyboardMode = .symbols
            default: keyboardMode = .letters
            }
            shifted = false
            reloadKeyboardRows()
            refreshKeyboard()
        case "glass":
            guard let argument, let style = KeyboardGlassStyle(rawValue: argument) else {
                lifecycleLog.notice("OBADH-DEBUG glass: unknown style \(argument ?? "", privacy: .public)")
                return
            }
            KeyboardGlassStyle.current = style
            reloadKeyboardRows()
            refreshKeyboard()
        case "probe":
            // Mouse-free sim driving of the presentation probe overlay.
            keyboardPreferences.debugPresentationProbeEnabled = argument != "off"
            updatePresentationProbe()
        case "backdrop":
            // Structural test: does the system's container paint keyboard material
            // BEHIND our view? If it does, our own backdrop is redundant and is what
            // creates the band/strip seam; if it does not, we must keep painting it.
            keyboardBackgroundView.isHidden = argument == "off"
            lifecycleLog.notice("OBADH-DEBUG backdrop hidden=\(self.keyboardBackgroundView.isHidden)")
        case "ask":
            // Sizing investigation: force the asked height without touching what we
            // render, so sweeping it isolates how the system's container band
            // responds to the ask. `ask:0` restores the computed height.
            let value = CGFloat(argument.flatMap(Double.init) ?? 0)
            debugAskOverride = value > 0 ? value : nil
            lifecycleLog.notice("OBADH-DEBUG ask override=\(self.debugAskOverride.map { String(Int($0)) } ?? "none", privacy: .public)")
            updateKeyboardHeightConstraintIfReady()
            applyLayoutMetricsIfNeeded(force: true)
            view.setNeedsLayout()
        case "strip":
            // Force the strip height so band and strip can be varied independently
            // while measuring.
            switch argument {
            case "bandless", "fullzone": KeyboardTheme.debugFullZoneStrip = true
            case "banded": KeyboardTheme.debugFullZoneStrip = false
            default: break
            }
            metricsCache = nil
            updateKeyboardHeightConstraintIfReady()
            applyLayoutMetricsIfNeeded(force: true)
            refreshKeyboard()
        case "tap":
            // Inject keys through the exact production path so input behavior
            // (spaces, dari timing, composition) is scriptable on the simulator.
            // Comma-separated keys fire back-to-back within one poll — the quick
            // double-tap case: tap:space,space.
            guard let argument else { return }
            for name in argument.split(separator: ",") {
                if name == "space" {
                    handleKeyPress(.space)
                } else if name == "return" {
                    handleKeyPress(.returnKey)
                } else if name.count == 1 {
                    handleKeyPress(.character(String(name)))
                }
            }
        case "sym":
            // Press a SYMBOL key, which `tap` cannot: `tap` sends `.character`, so
            // it goes straight to the composer and bypasses the symbol routing
            // entirely — including the colon-joins-a-composition rule that makes
            // bisarga reachable. `sym::` is the colon key on the numbers page.
            if let argument, !argument.isEmpty {
                handleKeyPress(.symbol(.literal(argument)))
            }
        case "flick":
            // Drive the iPad flick through its real delegate path, which no other
            // command reaches: `tap` sends `.character` and `sym` sends `.symbol`,
            // but a flick resolves the secondary itself and routes through
            // endTouch. `flick:m` is a downward flick on the m key.
            if let argument, argument.count == 1 {
                keyboardTouchSurface(
                    keyboardTouchSurface,
                    didEnd: .character(argument),
                    flickedDown: true
                )
            }
        case "cursor":
            if let argument, let offset = Int(argument) {
                textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
            }
        case "context":
            let before = textDocumentProxy.documentContextBeforeInput ?? ""
            let after = textDocumentProxy.documentContextAfterInput ?? ""
            lifecycleLog.notice("OBADH-CONTEXT before=[\(before, privacy: .public)] after=[\(after, privacy: .public)]")
        case "autoinsert":
            keyboardPreferences.autoInsertTopCorrection = argument != "off"
        case "pick":
            // Tap a suggestion slot through the real delegate path.
            if let argument, let index = Int(argument),
               composer.activeSuggestions.indices.contains(index) {
                suggestionBar(self.suggestionBar, didSelect: composer.activeSuggestions[index])
            }
        case "pickemoji":
            if let first = resolvedEmojiSuggestions().first {
                suggestionBar(self.suggestionBar, didSelectEmoji: first.display)
            }
        case "preview":
            // Show the key preview + pressed state programmatically so the parity
            // suite can capture the popover (a real touch cannot be scripted).
            if let argument, argument != "off",
               let button = keyButtons.first(where: { $0.previewText?.lowercased() == argument.lowercased() }) {
                button.isHighlighted = true
                showKeyPreview(for: button)
            } else {
                for button in keyButtons { button.isHighlighted = false }
                hideKeyPreview(animated: false)
                refreshKeyboard()
            }
        case "emoji":
            switch argument {
            case "close": hideEmojiPanel()
            default: showEmojiPanel()
            }
            refreshKeyboard()
        case "emojisearch":
            // Emoji search is entered by tapping the search field, which cannot be
            // scripted, so it was the one surface the capture matrix could not
            // reach — and it is where a real clipping bug was reported. Opens the
            // panel, enters search, and types the query through the production key
            // path: `emojisearch:smile`.
            showEmojiPanel()
            enterEmojiSearch()
            for character in argument ?? "" {
                handleEmojiSearchKeyPress(.character(String(character)))
            }
            refreshKeyboard()
        case "dump":
            lifecycleLog.notice("OBADH-DEBUG state build=\(AppBuildInfo.summary, privacy: .public) mode=\(String(describing: self.keyboardMode), privacy: .public) shifted=\(self.shifted) glass=\(KeyboardGlassStyle.current.rawValue, privacy: .public) appearance=\(self.traitCollection.userInterfaceStyle == .dark ? "dark" : "light", privacy: .public) size=\(NSCoder.string(for: self.view.bounds.size), privacy: .public) emojiPanel=\(self.showsEmojiPanel ? "shown" : "hidden") \(self.emojiPanelView.debugStateSummary, privacy: .public)")
        default:
            lifecycleLog.notice("OBADH-DEBUG unknown command=\(command, privacy: .public)")
        }
    }
}
#endif
