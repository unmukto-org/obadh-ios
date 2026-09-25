import UIKit

@main
@MainActor
final class AccuracyLabApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = AccuracyLabController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

@MainActor
private final class RecordingSurface: KeyboardTouchSurfaceView {
    var record: ((String, Set<UITouch>) -> Void)?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { record?("down", touches); super.touchesBegan(touches, with: event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { record?("move", touches); super.touchesMoved(touches, with: event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { record?("up", touches); super.touchesEnded(touches, with: event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { record?("cancel", touches); super.touchesCancelled(touches, with: event) }
}

@MainActor
private final class RecordingBaseline: BaselineKeyboardTouchSurfaceView {
    var record: ((String, Set<UITouch>) -> Void)?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { record?("down", touches); super.touchesBegan(touches, with: event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { record?("move", touches); super.touchesMoved(touches, with: event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { record?("up", touches); super.touchesEnded(touches, with: event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { record?("cancel", touches); super.touchesCancelled(touches, with: event) }
}

/// Deliberately a motor-input experiment, not a replacement keyboard extension.
/// Both arms render the same production key views and frames. Suggestions and
/// autocorrection are absent so they cannot hide spatial/routing errors.
@MainActor
final class AccuracyLabController: UIViewController, KeyboardTouchSurfaceViewDelegate, BaselineKeyboardTouchSurfaceViewDelegate {
    private struct Round {
        let variant: String
        let posture: String
        let prompt: String
    }
    private let candidate = RecordingSurface()
    private let baseline = RecordingBaseline()
    private let titleLabel = UILabel()
    private let instructions = UILabel()
    private let promptLabel = UILabel()
    private let enteredLabel = UILabel()
    private let nextButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    private let keyboard = UIView()
    private var rows: [KeyboardRowView] = []
    private var buttons: [KeyboardKeyButton] = []
    private var round = -1
    private var entered = ""
    private var actions = 0
    private var backspaces = 0
    private var shifted = false
    private var startedAt: Double?
    private var lastUp: Double?
    private var samples: [AccuracyTouchSample] = []
    private var commits: [AccuracyCommit] = []
    private var contactIDs: [ObjectIdentifier: Int] = [:]
    private var nextContactID = 0
    private var frames: [AccuracyKeyFrame] = []
    private var invalidReason: String?
    private var previousSize: CGSize = .zero
    private var plan: [Round] = []
    private var session: AccuracySession!
    private var saveURL: URL!
    private var metrics: KeyboardMetrics { KeyboardTheme.metrics(for: CGSize(width: view.bounds.width, height: 253), traitCollection: traitCollection, screenSize: view.window?.screen.bounds.size ?? .zero) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        promptLabel.font = .monospacedSystemFont(ofSize: 22, weight: .medium)
        enteredLabel.font = .monospacedSystemFont(ofSize: 22, weight: .regular)
        enteredLabel.textColor = .secondaryLabel
        for label in [titleLabel, instructions, promptLabel, enteredLabel] { label.numberOfLines = 0 }
        titleLabel.text = "Obadh typing study"
        instructions.text = "Copy the Roman text at your normal pace and correct mistakes normally. Each round specifies one thumb or two thumbs. Only these practice touches and text are saved locally. This measures finger input; Bangla prediction is a separate test."
        nextButton.setTitle("Begin", for: .normal)
        nextButton.addTarget(self, action: #selector(nextRound), for: .touchUpInside)
        exportButton.setTitle("Export results", for: .normal)
        exportButton.addTarget(self, action: #selector(exportResults), for: .touchUpInside)
        exportButton.isHidden = true
        let stack = UIStackView(arrangedSubviews: [titleLabel, instructions, promptLabel, enteredLabel, nextButton, exportButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12)
        ])
        keyboard.backgroundColor = .secondarySystemBackground
        view.addSubview(keyboard)
        candidate.delegate = self
        baseline.delegate = self
        candidate.record = { [weak self] phase, touches in self?.record(phase, touches, in: self?.candidate) }
        baseline.record = { [weak self] phase, touches in self?.record(phase, touches, in: self?.baseline) }
        keyboard.addSubview(candidate)
        keyboard.addSubview(baseline)
        candidate.isHidden = true
        baseline.isHidden = true
        buildPlan()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: UIApplication.willResignActiveNotification, object: nil)
    }

    private func buildPlan() {
        let postures = Bool.random() ? ["one-thumb", "two-thumbs"] : ["two-thumbs", "one-thumb"]
        let variants = Bool.random() ? ["baseline-112", "ordered-rollover"] : ["ordered-rollover", "baseline-112"]
        // Author-written prompts, intentionally not a language-frequency corpus.
        // Repeated phrases make paired motor comparisons possible; order is saved.
        let prompts = ["ami banglay likhi tumi kemon acho", "aj bikale nodir pare dekha hobe"]
        for (index, posture) in postures.enumerated() {
            for variant in index == 0 ? variants : Array(variants.reversed()) {
                for prompt in prompts { plan.append(Round(variant: variant, posture: posture, prompt: prompt)) }
            }
        }
        let id = UUID().uuidString
        session = AccuracySession(schemaVersion: 1, sessionID: id,
            provenance: ProcessInfo.processInfo.arguments.contains("-accuracy-ui-test") ? "automated-ui-smoke" : "prompted-human-pilot",
            sourceRevision: Bundle.main.object(forInfoDictionaryKey: "AccuracySourceRevision") as? String ?? "unrecorded",
            osVersion: UIDevice.current.systemVersion, deviceModel: UIDevice.current.model,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            trialOrder: plan.map { "\($0.posture)/\($0.variant)/\($0.prompt)" }, trials: [])
        saveURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("accuracy-\(id).json")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if previousSize != view.bounds.size {
            if startedAt != nil { invalidReason = "geometry changed during trial" }
            previousSize = view.bounds.size
            buildKeyboard()
        }
    }

    private func buildKeyboard() {
        candidate.cancelTracking()
        baseline.cancelTracking()
        rows.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        buttons.removeAll()
        let m = metrics
        let height = m.minimumKeyHeight * 4 + m.rowSpacing * 3 + m.keyboardInsets.bottom
        keyboard.frame = CGRect(x: 0, y: view.bounds.height - view.safeAreaInsets.bottom - height, width: view.bounds.width, height: height)
        let definitions = KeyboardLayoutProvider.rows(for: .letters, includesGlobeKey: false)
        for (index, definition) in definitions.enumerated() {
            let row = KeyboardRowView()
            let keys = definition.keys.map { KeyboardKeyButton(key: $0) }
            row.frame = CGRect(x: 0, y: CGFloat(index) * (m.minimumKeyHeight + m.rowSpacing), width: keyboard.bounds.width, height: m.minimumKeyHeight)
            row.configure(row: definition, buttons: keys, metrics: m)
            keyboard.insertSubview(row, belowSubview: candidate)
            row.layoutIfNeeded()
            rows.append(row)
            buttons.append(contentsOf: keys)
        }
        candidate.frame = keyboard.bounds
        baseline.frame = keyboard.bounds
        let regions = rows.map { row in
            row.subviews.compactMap { $0 as? KeyboardKeyButton }.map {
                KeyboardTouchKeyRegion(key: $0.key, visualFrame: $0.convert($0.bounds, to: candidate))
            }
        }
        candidate.keyRows = regions
        baseline.keyRows = regions
        frames = regions.enumerated().flatMap { index, row in row.map {
            AccuracyKeyFrame(row: index, key: token($0.key), x: $0.visualFrame.minX, y: $0.visualFrame.minY, width: $0.visualFrame.width, height: $0.visualFrame.height)
        }}
        updateAppearance()
    }

    private func updateAppearance() {
        for button in buttons {
            button.updateAppearance(shifted: shifted, traitCollection: traitCollection, metrics: metrics,
                showsSpaceIntro: false, spaceCaption: "space", capsLocked: false)
        }
    }

    @objc private func nextRound() {
        candidate.cancelTracking()
        baseline.cancelTracking()
        if round >= 0 && round < plan.count {
            guard let start = startedAt, let end = lastUp, end > start else { return }
            let task = plan[round]
            session.trials.append(AccuracyTrial(id: round, variant: task.variant, posture: task.posture,
                prompt: task.prompt, entered: entered, startedAt: start, endedAt: end,
                actions: actions, backspaces: backspaces, invalidReason: invalidReason,
                surfaceWidth: candidate.bounds.width, surfaceHeight: candidate.bounds.height,
                frames: frames, samples: samples, commits: commits))
            do { try save() } catch { session.trials.removeLast(); instructions.text = "Could not save results: \(error.localizedDescription)"; return }
        }
        round += 1
        entered = ""; actions = 0; backspaces = 0; shifted = false
        startedAt = nil; lastUp = nil; invalidReason = nil
        samples.removeAll(); commits.removeAll(); contactIDs.removeAll(); nextContactID = 0
        enteredLabel.text = " "
        exportButton.isHidden = session.trials.isEmpty
        guard round < plan.count else {
            candidate.isHidden = true; baseline.isHidden = true
            titleLabel.text = "Practice complete"
            instructions.text = "Results are saved on this phone. Export them for the paired comparison. These rounds measure finger input, not Bangla correction quality."
            promptLabel.text = nil
            nextButton.isHidden = true
            return
        }
        let task = plan[round]
        titleLabel.text = "Round \(round + 1) of \(plan.count) · \(task.posture == "one-thumb" ? "One thumb" : "Two thumbs")"
        instructions.text = "Copy this text at your normal pace. Correct mistakes as usual, then tap Next. Keep the same grip for this round."
        promptLabel.text = task.prompt
        nextButton.setTitle("Next", for: .normal)
        candidate.isHidden = task.variant != "ordered-rollover"
        baseline.isHidden = task.variant != "baseline-112"
        updateAppearance()
    }

    private func record(_ phase: String, _ touches: Set<UITouch>, in surface: UIView?) {
        guard round >= 0, round < plan.count, let surface else { return }
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let identity = ObjectIdentifier(touch)
            if phase == "down" {
                nextContactID += 1
                contactIDs[identity] = nextContactID
                if startedAt == nil { startedAt = touch.timestamp }
            }
            guard let id = contactIDs[identity] else { continue }
            let p = touch.location(in: surface)
            samples.append(AccuracyTouchSample(contact: id, phase: phase, time: touch.timestamp,
                x: p.x, y: p.y, radius: touch.majorRadius))
            if phase == "up" || phase == "cancel" {
                lastUp = max(lastUp ?? 0, touch.timestamp)
                contactIDs.removeValue(forKey: identity)
            }
        }
    }

    private func token(_ key: KeyboardKey) -> String {
        switch key {
        case .character(let value): return "character:" + value
        case .symbol(let value): return "symbol:" + value.output
        case .modeSwitch(let value): return "mode:" + value
        case .space: return "space"
        case .backspace: return "backspace"
        case .shift: return "shift"
        case .returnKey: return "return"
        case .emoji: return "emoji"
        case .globe: return "globe"
        case .tab: return "tab"
        case .capsLock: return "capsLock"
        case .hideKeyboard: return "hideKeyboard"
        }
    }

    private func highlight(_ key: KeyboardKey?) {
        for button in buttons { button.isHighlighted = button.key == key }
    }

    private func commit(_ key: KeyboardKey?) {
        guard round >= 0, round < plan.count, let key else { return }
        actions += 1
        commits.append(AccuracyCommit(key: token(key), time: ProcessInfo.processInfo.systemUptime))
        switch key {
        case let .character(value): entered += shifted ? value.uppercased() : value; shifted = false
        case .space: entered += " "
        case .backspace: backspaces += 1; if !entered.isEmpty { entered.removeLast() }
        case .shift: shifted.toggle()
        default: break // Other commands are visible but excluded from these prompts.
        }
        highlight(nil)
        enteredLabel.text = entered.isEmpty ? " " : entered
        updateAppearance()
    }

    @objc private func interrupted() {
        guard startedAt != nil else { return }
        invalidReason = "app interrupted during trial"
        candidate.cancelTracking(); baseline.cancelTracking()
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: saveURL, options: [.atomic, .completeFileProtection])
    }

    @objc private func exportResults() {
        guard !session.trials.isEmpty else { return }
        do {
            try save()
            let sheet = UIActivityViewController(activityItems: [saveURL as Any], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = exportButton
            present(sheet, animated: true)
        } catch { instructions.text = "Could not export: \(error.localizedDescription)" }
    }

    func keyboardTouchSurface(_ view: KeyboardTouchSurfaceView, didBegin key: KeyboardKey) { highlight(key) }
    func keyboardTouchSurface(_ view: KeyboardTouchSurfaceView, didMoveTo key: KeyboardKey) { highlight(key) }
    func keyboardTouchSurface(_ view: KeyboardTouchSurfaceView, didUpdateFlickProgress progress: CGFloat, on key: KeyboardKey) {}
    func keyboardTouchSurface(_ view: KeyboardTouchSurfaceView, didEnd key: KeyboardKey?, flickedDown: Bool) { commit(key) }
    func keyboardTouchSurfaceDidCancel(_ view: KeyboardTouchSurfaceView) { highlight(nil) }
    func keyboardTouchSurface(_ view: BaselineKeyboardTouchSurfaceView, didBegin key: KeyboardKey) { highlight(key) }
    func keyboardTouchSurface(_ view: BaselineKeyboardTouchSurfaceView, didMoveTo key: KeyboardKey) { highlight(key) }
    func keyboardTouchSurface(_ view: BaselineKeyboardTouchSurfaceView, didUpdateFlickProgress progress: CGFloat, on key: KeyboardKey) {}
    func keyboardTouchSurface(_ view: BaselineKeyboardTouchSurfaceView, didEnd key: KeyboardKey?, flickedDown: Bool) { commit(key) }
    func keyboardTouchSurfaceDidCancel(_ view: BaselineKeyboardTouchSurfaceView) { highlight(nil) }
}
