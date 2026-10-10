import UIKit

/// An isolated study surface. It draws the production key geometry, records only
/// prompted word gestures, and never runs inside the shipping keyboard extension.
@MainActor
final class SwipeStudyController: UIViewController {
    private struct Prompt {
        let roman: String
        let bangla: String
    }
    private struct Point: Codable {
        let milliseconds: Double
        let x: Double
        let y: Double
    }
    private struct KeyCenter: Codable {
        let letter: String
        let x: Double
        let y: Double
    }
    private struct Trial: Codable {
        let roman: String
        let bangla: String
        let points: [Point]
        let keyCenters: [KeyCenter]
        let letterAreaWidth: Double
        let letterAreaHeight: Double
    }
    private struct Session: Codable {
        let schemaVersion: Int
        let source: String
        let sourceRevision: String
        let vocabularySourceFSTSHA256: String
        let id: UUID
        let createdAt: Date
        let osVersion: String
        let deviceModel: String
        var trials: [Trial]
    }

    private let prompts = [
        Prompt(roman: "ami", bangla: "আমি"),
        Prompt(roman: "tumi", bangla: "তুমি"),
        Prompt(roman: "bhalo", bangla: "ভালো"),
        Prompt(roman: "valo", bangla: "ভালো"),
        Prompt(roman: "kemon", bangla: "কেমন"),
        Prompt(roman: "amar", bangla: "আমার"),
        Prompt(roman: "bangla", bangla: "বাংলা"),
        Prompt(roman: "aj", bangla: "আজ"),
        Prompt(roman: "kal", bangla: "কাল"),
        Prompt(roman: "kotha", bangla: "কথা"),
        Prompt(roman: "ebng", bangla: "এবং")
    ]
    private let titleLabel = UILabel()
    private let instructionLabel = UILabel()
    private let promptLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    private let keyboard = UIView()
    private let capture = SwipeStudyCaptureView()
    private var rows: [KeyboardRowView] = []
    private var keyCenters: [KeyCenter] = []
    private var letterAreaHeight: CGFloat = 1
    private var previousSize: CGSize = .zero
    private var index = -1
    private var points: [Point] = []
    private var touchStart: TimeInterval?
    private var completedStroke = false
    private var session = Session(schemaVersion: 1, source: "obadh-ios-swipe-study",
        sourceRevision: Bundle.main.object(forInfoDictionaryKey: "AccuracySourceRevision") as? String ?? "unrecorded",
        vocabularySourceFSTSHA256: "8d38937763ed96ea8ed291fa6097899a324620f58bd89625d1f6609f1b634766",
        id: UUID(), createdAt: Date(), osVersion: UIDevice.current.systemVersion,
        deviceModel: UIDevice.current.model, trials: [])

    private var metrics: KeyboardMetrics {
        KeyboardTheme.metrics(for: CGSize(width: view.bounds.width, height: 253),
            traitCollection: traitCollection,
            screenSize: view.window?.screen.bounds.size ?? .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.text = "Obadh swipe study"
        instructionLabel.font = .preferredFont(forTextStyle: .body)
        instructionLabel.textColor = .secondaryLabel
        instructionLabel.text = "Swipe the shown Roman spelling at a natural pace. Only these prompted gestures and key positions are saved on this device. No typed messages or editor context are collected."
        promptLabel.font = .monospacedSystemFont(ofSize: 27, weight: .semibold)
        promptLabel.textAlignment = .center
        for label in [titleLabel, instructionLabel, promptLabel] {
            label.numberOfLines = 0
        }
        actionButton.setTitle("Begin", for: .normal)
        actionButton.addTarget(self, action: #selector(advance), for: .touchUpInside)
        actionButton.accessibilityIdentifier = "swipe-study-next"
        retryButton.setTitle("Retry gesture", for: .normal)
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        retryButton.isHidden = true
        exportButton.setTitle("Export recorded gestures", for: .normal)
        exportButton.addTarget(self, action: #selector(exportStudy), for: .touchUpInside)
        exportButton.isHidden = true
        let controls = UIStackView(arrangedSubviews: [actionButton, retryButton, exportButton])
        controls.axis = .vertical
        controls.spacing = 8
        let stack = UIStackView(arrangedSubviews: [titleLabel, instructionLabel, promptLabel, controls])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18)
        ])
        keyboard.backgroundColor = .secondarySystemBackground
        view.addSubview(keyboard)
        keyboard.addSubview(capture)
        capture.onSample = { [weak self] phase, touch in self?.record(phase, touch: touch) }
        capture.isUserInteractionEnabled = false
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard previousSize != view.bounds.size else { return }
        previousSize = view.bounds.size
        if index >= 0 && !points.isEmpty { retry() }
        buildKeyboard()
    }

    private func buildKeyboard() {
        rows.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        let m = metrics
        let height = m.minimumKeyHeight * 4 + m.rowSpacing * 3 + m.keyboardInsets.bottom
        keyboard.frame = CGRect(x: 0, y: view.bounds.height - view.safeAreaInsets.bottom - height,
            width: view.bounds.width, height: height)
        let definitions = KeyboardLayoutProvider.rows(for: .letters, includesGlobeKey: false)
        for (index, definition) in definitions.enumerated() {
            let row = KeyboardRowView()
            let buttons = definition.keys.map { KeyboardKeyButton(key: $0) }
            row.frame = CGRect(x: 0, y: CGFloat(index) * (m.minimumKeyHeight + m.rowSpacing),
                width: keyboard.bounds.width, height: m.minimumKeyHeight)
            row.configure(row: definition, buttons: buttons, metrics: m)
            keyboard.insertSubview(row, belowSubview: capture)
            row.layoutIfNeeded()
            for button in buttons {
                button.updateAppearance(shifted: false, traitCollection: traitCollection,
                    metrics: m, showsSpaceIntro: false, spaceCaption: "space", capsLocked: false)
            }
            rows.append(row)
        }
        capture.frame = keyboard.bounds
        letterAreaHeight = rows[2].frame.maxY
        keyCenters = rows.prefix(3).flatMap { row in
            row.keyRegions(in: capture).compactMap { region in
                guard case let .character(letter) = region.key else { return nil }
                return KeyCenter(letter: letter,
                    x: Double(region.visualFrame.midX / capture.bounds.width),
                    y: Double(region.visualFrame.midY / letterAreaHeight))
            }
        }
    }

    @objc private func advance() {
        if index >= 0 && index < prompts.count * 3 {
            guard completedStroke, points.count >= 3 else { return }
            let prompt = prompts[index % prompts.count]
            session.trials.append(Trial(roman: prompt.roman, bangla: prompt.bangla,
                points: points, keyCenters: keyCenters,
                letterAreaWidth: Double(capture.bounds.width),
                letterAreaHeight: Double(letterAreaHeight)))
            do { try save() } catch {
                session.trials.removeLast()
                instructionLabel.text = "Could not save this gesture: \(error.localizedDescription)"
                return
            }
        }
        index += 1
        retry()
        exportButton.isHidden = session.trials.isEmpty
        guard index < prompts.count * 3 else {
            titleLabel.text = "Study complete"
            instructionLabel.text = "The gestures are saved only on this device. Export the file when you are ready."
            promptLabel.text = nil
            actionButton.isHidden = true
            retryButton.isHidden = true
            capture.isUserInteractionEnabled = false
            return
        }
        let prompt = prompts[index % prompts.count]
        titleLabel.text = "Word \(index + 1) of \(prompts.count * 3)"
        instructionLabel.text = "Swipe the Roman spelling below in one continuous stroke. Lift your finger when done."
        promptLabel.text = "\(prompt.bangla)  ·  \(prompt.roman)"
        actionButton.setTitle("Next word", for: .normal)
        actionButton.isEnabled = false
        capture.isUserInteractionEnabled = true
    }

    @objc private func retry() {
        points.removeAll(keepingCapacity: true)
        touchStart = nil
        completedStroke = false
        capture.clearTrail()
        retryButton.isHidden = true
        actionButton.isEnabled = index < 0
    }

    private func record(_ phase: SwipeStudyCaptureView.Phase, touch: UITouch) {
        guard index >= 0, index < prompts.count * 3, !completedStroke else { return }
        if phase == .began {
            points.removeAll(keepingCapacity: true)
            touchStart = touch.timestamp
        }
        guard let touchStart else { return }
        let location = touch.location(in: capture)
        points.append(Point(milliseconds: max(0, (touch.timestamp - touchStart) * 1_000),
            x: Double(location.x / capture.bounds.width),
            y: Double(location.y / letterAreaHeight)))
        capture.appendTrail(location, begin: phase == .began)
        if phase == .ended {
            completedStroke = points.count >= 3
            actionButton.isEnabled = completedStroke
            retryButton.isHidden = false
        } else if phase == .cancelled {
            retry()
        }
    }

    @objc private func interrupted() {
        if !completedStroke { retry() }
    }

    private func save() throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("swipe-study-\(session.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(session).write(to: url, options: [.atomic, .completeFileProtection])
    }

    @objc private func exportStudy() {
        guard !session.trials.isEmpty else { return }
        do {
            try save()
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = directory.appendingPathComponent("swipe-study-\(session.id).json")
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = exportButton
            present(sheet, animated: true)
        } catch {
            instructionLabel.text = "Could not export the gestures: \(error.localizedDescription)"
        }
    }
}

@MainActor
private final class SwipeStudyCaptureView: UIView {
    enum Phase { case began, moved, ended, cancelled }
    var onSample: ((Phase, UITouch) -> Void)?
    private weak var activeTouch: UITouch?
    private let trail = CAShapeLayer()
    private let path = UIBezierPath()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.004)
        isMultipleTouchEnabled = false
        trail.strokeColor = UIColor.systemBlue.cgColor
        trail.lineWidth = 3
        trail.lineCap = .round
        trail.fillColor = UIColor.clear.cgColor
        layer.addSublayer(trail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func clearTrail() {
        path.removeAllPoints()
        trail.path = nil
        activeTouch = nil
    }

    func appendTrail(_ point: CGPoint, begin: Bool) {
        if begin { path.removeAllPoints(); path.move(to: point) }
        else { path.addLine(to: point) }
        trail.path = path.cgPath
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        onSample?(.began, touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        for sample in (event?.coalescedTouches(for: activeTouch) ?? [activeTouch]) {
            onSample?(.moved, sample)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        onSample?(.ended, activeTouch)
        self.activeTouch = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        onSample?(.cancelled, activeTouch)
        self.activeTouch = nil
    }
}
