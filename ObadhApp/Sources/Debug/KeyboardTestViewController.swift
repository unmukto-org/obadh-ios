import SwiftUI
import UIKit

// DEBUG-only. A text field to summon the keyboard, plus the on-device tuning and
// diagnostics panel. Release ships no text input at all -- see ObadhApp.swift.
#if DEBUG
/// DEBUG-only navigation controller that can pin the interface orientation.
///
/// iPad apps are resizable, so `requestGeometryUpdate` alone is ignored — the
/// scene only rotates when the supported set actually excludes the current
/// orientation. Used by `--landscape` so the parity captures can be taken on
/// several simulators at once; `simctl` has no rotation primitive and the
/// alternatives all need the Simulator window to be frontmost.
final class OrientationPinningNavigationController: UINavigationController {
    var pinned: UIInterfaceOrientationMask?

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        pinned ?? super.supportedInterfaceOrientations
    }

    override var shouldAutorotate: Bool { true }
}

/// Hosts the UIKit test screen so it can sit behind a SwiftUI NavigationLink.
struct KeyboardTestScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> KeyboardTestViewController {
        KeyboardTestViewController()
    }

    func updateUIViewController(_ controller: KeyboardTestViewController, context: Context) {}
}

final class KeyboardTestViewController: UIViewController {
    private let geometryRecorder = HostKeyboardGeometryRecorder()
    private let textView = KeyboardProbeTextView()
    private let buildLabel = UILabel()
    // A vibrant gradient behind everything (incl. behind the keyboard) so the
    // key material's translucency is visible for native-vs-Obadh comparison.
    private let gradientLayer = CAGradientLayer()
    private var startsWithGradient: Bool {
        ProcessInfo.processInfo.arguments.contains("--gradient-bg")
    }
    /// Measurement backdrop: a flat mid-gray distinct from every keyboard material in
    /// BOTH appearances, so the parity suite can find the container edge without
    /// ambiguity (the normal solid background ≈ the panel color in dark mode).
    /// Contract with scripts/parity/.
    private var startsWithMeasureBackground: Bool {
        ProcessInfo.processInfo.arguments.contains("--measure-bg")
    }
    private var allowsSizingExperiments: Bool {
        ProcessInfo.processInfo.arguments.contains("--experimental-sizing")
    }
    /// Sizing investigation: attach a host `inputAccessoryView` (what a chat
    /// composer like Messenger's uses) so we can test whether the system's
    /// container band above the extension depends on the host, not on us.
    /// `--accessory[=<pt>]`, default 44pt.
    private var accessoryHeight: CGFloat? {
        guard let argument = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--accessory") }) else { return nil }
        let value = argument.split(separator: "=").last.flatMap { Double($0) }
        return CGFloat(value ?? 44)
    }

    // On-device tuning + diagnostics, written to the shared App Group so the live
    // keyboard picks them up. The render path reads none of these: tuned visuals
    // are baked in KeyboardTheme, and only additive tools remain (haptic feel, the
    // comparison background, the measurement probe).
    private let prefs = KeyboardPreferences()
    private let hapticSwitch = UISwitch()
    private let intensitySlider = UISlider()
    private let sharpnessSlider = UISlider()
    private let intensityValueLabel = UILabel()
    private let sharpnessValueLabel = UILabel()
    private let backgroundControl = UISegmentedControl(items: ["Gradient", "Solid"])
    private let presentationProbeSwitch = UISwitch()
    private let pinnedPresentationControl = UISegmentedControl(items: ["Auto", "Banded", "Band-less"])
    private lazy var sizingLogButton: UIButton = {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = "Sizing log"
        configuration.image = UIImage(systemName: "list.bullet.rectangle")
        configuration.imagePadding = 6
        return UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            let controller = SizingLogViewController()
            if let navigationController {
                navigationController.pushViewController(controller, animated: true)
            } else {
                present(UINavigationController(rootViewController: controller), animated: true)
            }
        })
    }()
    private lazy var controlsPanel = makeControlsPanel()

    override func viewDidLoad() {
        super.viewDidLoad()
        // A sizing experiment persisted across installs on a real phone and
        // enlarged the everyday ribbon. Normal testing always uses Auto; the
        // deliberately distorting controls require an explicit launch argument.
        if !allowsSizingExperiments, prefs.debugPinnedPresentation != 0 {
            prefs.debugPinnedPresentation = 0
            KeyboardPreferences.postKeyTintChanged()
        }
        buildLabel.accessibilityIdentifier = "keyboard-host-geometry"
        geometryRecorder.onKeyboardHeightChange = { [weak self] height in
            self?.buildLabel.accessibilityValue = String(Double(height))
        }
        geometryRecorder.start(in: view)
        title = "Keyboard Test"
        view.backgroundColor = startsWithMeasureBackground
            ? UIColor(white: 0.5, alpha: 1)   // appearance-independent mid-gray
            : .systemGroupedBackground
        configureGradient()
        configureTextView()
        configureBuildLabel()
        configureControls()
        layoutContent()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestLandscapeIfAsked()
        print("OBADH-INPUT-MODES \(UITextInputMode.activeInputModes.map { $0.primaryLanguage ?? "nil" })")
        textView.becomeFirstResponder()
    }

    /// `--landscape` rotates the harness for the parity captures. `simctl` has no
    /// rotation primitive and the alternatives all need the Simulator window
    /// (menu scripting or the mouse), which does not survive running several
    /// simulators at once — this is pure in-process API, so N devices can be
    /// captured in parallel.
    private func requestLandscapeIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("--landscape"),
              let scene = view.window?.windowScene else { return }
        (navigationController as? OrientationPinningNavigationController)?.pinned = .landscapeRight
        setNeedsUpdateOfSupportedInterfaceOrientations()
        navigationController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(
            .iOS(interfaceOrientations: .landscapeRight)
        ) { error in
            print("landscape request failed: \(error)")
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        ProcessInfo.processInfo.arguments.contains("--landscape")
            ? .landscapeRight
            : super.supportedInterfaceOrientations
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradientLayer.frame = view.bounds
    }

    // MARK: Pieces

    private func configureGradient() {
        gradientLayer.colors = [
            UIColor.systemPurple.cgColor,
            UIColor.systemPink.cgColor,
            UIColor.systemOrange.cgColor,
            UIColor.systemTeal.cgColor,
            UIColor.systemBlue.cgColor
        ]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        gradientLayer.isHidden = !startsWithGradient
        view.layer.insertSublayer(gradientLayer, at: 0)
    }

    private func configureTextView() {
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .secondarySystemGroupedBackground
        textView.textColor = .label
        textView.tintColor = .systemBlue
        textView.font = .systemFont(ofSize: 24)
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.layer.cornerCurve = .continuous
        textView.layer.cornerRadius = 16
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .yes
        textView.spellCheckingType = .yes
        textView.keyboardType = ProcessInfo.processInfo.arguments.contains("--keyboard-default")
            ? .default : .alphabet
        // `--seed=<text>` prefills the field. The native keyboard's prediction row
        // is only populated when there is context, and `simctl` has no tap
        // primitive, so this is the only way to capture native predictions as a
        // reference for our own strip.
        let seedPrefix = "--seed="
        textView.text = ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix(seedPrefix) }
            .map { String($0.dropFirst(seedPrefix.count)) } ?? ""
        // `--no-shortcuts` empties the iPad shortcuts bar's button groups, which is
        // what a host app does when it does not want one. Our strip has to look
        // right both with the system bar above it and without, and this is how that
        // second case gets measured rather than assumed.
        if ProcessInfo.processInfo.arguments.contains("--no-shortcuts") {
            textView.inputAssistantItem.leadingBarButtonGroups = []
            textView.inputAssistantItem.trailingBarButtonGroups = []
        }
        textView.accessibilityLabel = "Obadh keyboard test field"
        if let accessoryHeight {
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: accessoryHeight))
            bar.items = [UIBarButtonItem(title: "accessory", style: .plain, target: nil, action: nil)]
            textView.inputAccessoryView = bar
        }
    }

    private func configureBuildLabel() {
        buildLabel.translatesAutoresizingMaskIntoConstraints = false
        buildLabel.text = "Obadh \(AppBuildInfo.summary)"
        buildLabel.textColor = .tertiaryLabel
        buildLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        buildLabel.numberOfLines = 0
        buildLabel.textAlignment = .center
    }

    private func configureControls() {
        hapticSwitch.isOn = prefs.debugHapticOverrideEnabled
        hapticSwitch.addTarget(self, action: #selector(hapticOverrideChanged), for: .valueChanged)

        for slider in [intensitySlider, sharpnessSlider] {
            slider.minimumValue = 0
            slider.maximumValue = 1
        }
        intensitySlider.value = Float(prefs.debugHapticIntensity)
        intensitySlider.addTarget(self, action: #selector(intensityChanged), for: .valueChanged)
        sharpnessSlider.value = Float(prefs.debugHapticSharpness)
        sharpnessSlider.addTarget(self, action: #selector(sharpnessChanged), for: .valueChanged)

        for label in [intensityValueLabel, sharpnessValueLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
            label.textColor = .secondaryLabel
        }

        backgroundControl.selectedSegmentIndex = startsWithGradient ? 0 : 1
        backgroundControl.addTarget(self, action: #selector(backgroundChanged), for: .valueChanged)

        presentationProbeSwitch.isOn = prefs.debugPresentationProbeEnabled
        presentationProbeSwitch.addTarget(self, action: #selector(presentationProbeChanged), for: .valueChanged)

        pinnedPresentationControl.selectedSegmentIndex = prefs.debugPinnedPresentation
        pinnedPresentationControl.addTarget(self, action: #selector(pinnedPresentationChanged), for: .valueChanged)

        updateHapticValueLabels()
    }

    // MARK: Panel

    /// The scrollable settings panel: insetGrouped-style cards with symbol headers,
    /// hairline-separated rows, and footnotes, so nothing clips above the keyboard.
    private func makeControlsPanel() -> UIView {
        let haptics = sectionCard(
            symbol: "waveform",
            title: "Haptics",
            rows: [
                switchRow("Custom haptics", hapticSwitch),
                sliderRow("Intensity", intensitySlider, intensityValueLabel),
                sliderRow("Sharpness", sharpnessSlider, sharpnessValueLabel)
            ],
            footer: "Overrides the shipped key tick while enabled. Values apply per keystroke."
        )
        let background = sectionCard(
            symbol: "paintpalette",
            title: "Background",
            rows: [paddedRow(backgroundControl)],
            footer: "Gradient shows the key material's translucency. Solid matches a plain app."
        )
        var diagnosticRows: [UIView] = [switchRow("Probe overlay", presentationProbeSwitch)]
        if allowsSizingExperiments {
            diagnosticRows.append(paddedRow(pinnedPresentationControl))
        }
        diagnosticRows.append(paddedRow(sizingLogButton))
        let diagnostics = sectionCard(
            symbol: "ruler",
            title: "Diagnostics",
            rows: diagnosticRows,
            footer: allowsSizingExperiments
                ? "Experimental sizing: Banded/Band-less can make the ribbon too short or too tall. Use Auto for normal testing. Launching Obadh normally restores Auto."
                : "Probe shows keyboard measurements. Sizing log records requested and actual ribbon heights. Normal testing uses automatic presentation sizing."
        )

        let note = UILabel()
        note.text = "Tap the globe key if Obadh is not selected. Hardware key presses stay disabled here to avoid an iOS 26 Simulator input-mode crash."
        note.font = .preferredFont(forTextStyle: .caption2)
        note.textColor = .tertiaryLabel
        note.numberOfLines = 0
        let noteWrap = UIStackView(arrangedSubviews: [note])
        noteWrap.isLayoutMarginsRelativeArrangement = true
        noteWrap.layoutMargins = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)

        let content = UIStackView(arrangedSubviews: [haptics, background, diagnostics, noteWrap])
        content.axis = .vertical
        content.spacing = 20
        content.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = true
        scroll.alwaysBounceVertical = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        return scroll
    }

    private func sectionCard(symbol: String, title: String, rows: [UIView], footer: String? = nil) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = .secondaryLabel
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let header = UILabel()
        header.text = title.uppercased()
        header.font = .preferredFont(forTextStyle: .footnote)
        header.textColor = .secondaryLabel

        let headerRow = UIStackView(arrangedSubviews: [icon, header])
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 6
        headerRow.isLayoutMarginsRelativeArrangement = true
        headerRow.layoutMargins = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 0)

        var innerViews: [UIView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                innerViews.append(hairline())
            }
            innerViews.append(row)
        }
        let inner = UIStackView(arrangedSubviews: innerViews)
        inner.axis = .vertical
        inner.spacing = 10
        inner.translatesAutoresizingMaskIntoConstraints = false

        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16)
        ])

        var stack: [UIView] = [headerRow, card]
        if let footer {
            let footnote = UILabel()
            footnote.text = footer
            footnote.font = .preferredFont(forTextStyle: .caption2)
            footnote.textColor = .tertiaryLabel
            footnote.numberOfLines = 0
            let wrap = UIStackView(arrangedSubviews: [footnote])
            wrap.isLayoutMarginsRelativeArrangement = true
            wrap.layoutMargins = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
            stack.append(wrap)
        }
        let section = UIStackView(arrangedSubviews: stack)
        section.axis = .vertical
        section.spacing = 7
        return section
    }

    private func switchRow(_ title: String, _ control: UISwitch) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .body)
        let row = UIStackView(arrangedSubviews: [label, UIView(), control])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        return row
    }

    private func sliderRow(_ title: String, _ slider: UISlider, _ valueLabel: UILabel) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .body)
        let top = UIStackView(arrangedSubviews: [label, UIView(), valueLabel])
        top.axis = .horizontal
        top.alignment = .firstBaseline
        let row = UIStackView(arrangedSubviews: [top, slider])
        row.axis = .vertical
        row.spacing = 4
        return row
    }

    private func paddedRow(_ view: UIView) -> UIView {
        let row = UIStackView(arrangedSubviews: [view])
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        return row
    }

    private func hairline() -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        return line
    }

    private func updateHapticValueLabels() {
        intensityValueLabel.text = String(format: "%.2f", intensitySlider.value)
        sharpnessValueLabel.text = String(format: "%.2f", sharpnessSlider.value)
    }

    // MARK: Actions

    @objc private func hapticOverrideChanged() {
        prefs.debugHapticOverrideEnabled = hapticSwitch.isOn
    }

    @objc private func intensityChanged() {
        prefs.debugHapticIntensity = Double(intensitySlider.value)
        updateHapticValueLabels()
    }

    @objc private func sharpnessChanged() {
        prefs.debugHapticSharpness = Double(sharpnessSlider.value)
        updateHapticValueLabels()
    }

    @objc private func backgroundChanged() {
        gradientLayer.isHidden = backgroundControl.selectedSegmentIndex != 0
    }

    @objc private func presentationProbeChanged() {
        prefs.debugPresentationProbeEnabled = presentationProbeSwitch.isOn
        KeyboardPreferences.postKeyTintChanged()
    }

    /// Takes effect on the keyboard's next presentation (the class is chosen in
    /// viewWillAppear), so switch keyboards away and back after changing it.
    @objc private func pinnedPresentationChanged() {
        prefs.debugPinnedPresentation = pinnedPresentationControl.selectedSegmentIndex
        KeyboardPreferences.postKeyTintChanged()
    }

    // MARK: Layout

    private func layoutContent() {
        view.addSubview(controlsPanel)
        view.addSubview(buildLabel)
        view.addSubview(textView)

        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            controlsPanel.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            controlsPanel.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            controlsPanel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),

            buildLabel.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            buildLabel.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            buildLabel.topAnchor.constraint(equalTo: controlsPanel.bottomAnchor, constant: 10),

            textView.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            textView.topAnchor.constraint(equalTo: buildLabel.bottomAnchor, constant: 10),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
            // Fixed (not >=) so the scrollable panel above gets a determined height
            // instead of being collapsed to zero by a growing text field.
            textView.heightAnchor.constraint(equalToConstant: 92)
        ])
    }
}
/// An explicit public-API selector for diagnostic captures. Simulator preference
/// writes can be accepted on disk while the keyboard daemon keeps its cached mode.
private final class KeyboardProbeTextView: UITextView {
    override var textInputMode: UITextInputMode? {
        let prefix = "--input-language="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return super.textInputMode
        }
        let language = String(argument.dropFirst(prefix.count))
        return UITextInputMode.activeInputModes.first { $0.primaryLanguage == language } ?? super.textInputMode
    }
}
#endif
