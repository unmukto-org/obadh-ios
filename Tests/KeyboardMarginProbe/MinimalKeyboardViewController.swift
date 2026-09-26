import UIKit
import os

// Simulator-only control: no Obadh engine, theme, ribbon or touch routing.
// Generated independently by scripts/parity/generate-margin-probe.py.
final class KeyboardViewController: UIInputViewController {
    private var heightConstraint: NSLayoutConstraint?
    private let log = Logger(subsystem: "org.unmukto.obadh.marginprobe", category: "geometry")

    #if PROBE_KEYBOARD || PROBE_DEFAULT || PROBE_SYSTEM_SIZING || PROBE_PULSE || PROBE_INTRINSIC || PROBE_FITTING
    override func loadView() {
        #if PROBE_KEYBOARD
        inputView = UIInputView(frame: .zero, inputViewStyle: .keyboard)
        #elseif PROBE_INTRINSIC || PROBE_FITTING
        inputView = ProbeInputView(frame: .zero, inputViewStyle: .default)
        #else
        inputView = UIInputView(frame: .zero, inputViewStyle: .default)
        #endif
    }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        #if PROBE_INPUT_MODE
        NotificationCenter.default.addObserver(self, selector: #selector(inputModeChanged(_:)),
            name: UITextInputMode.currentInputModeDidChangeNotification, object: nil)
        recordInputMode("load")
        #endif
        configureProbe()
    }

    #if PROBE_INPUT_MODE
    private func recordInputMode(_ phase: String, notificationMode: UITextInputMode? = nil) {
        log.notice("MARGIN-MODE phase=\(phase, privacy: .public) document=\(self.textDocumentProxy.documentInputMode?.primaryLanguage ?? "nil", privacy: .public) responder=\(self.textInputMode?.primaryLanguage ?? "nil", privacy: .public) notification=\(notificationMode?.primaryLanguage ?? "nil", privacy: .public)")
    }

    @objc private func inputModeChanged(_ notification: Notification) {
        recordInputMode("notification", notificationMode: notification.object as? UITextInputMode)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        recordInputMode("willAppear")
    }

    override func viewWillDisappear(_ animated: Bool) {
        recordInputMode("willDisappear")
        super.viewWillDisappear(animated)
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        recordInputMode("textDidChange")
    }
    #endif

    private func configureProbe() {
        #if PROBE_PREFERRED || PROBE_PREFERRED_ONLY
        preferredContentSize = CGSize(width: UIScreen.main.bounds.width, height: 180)
        #endif
        #if PROBE_SYSTEM_SIZING || PROBE_SYSTEM_DEFAULT
        inputView?.allowsSelfSizing = false
        #else
        inputView?.allowsSelfSizing = true
        #endif
        view.backgroundColor = .systemPink
        #if !PROBE_INTRINSIC && !PROBE_SYSTEM_DEFAULT && !PROBE_FITTING && !PROBE_PREFERRED_ONLY
        let height = view.heightAnchor.constraint(equalToConstant: 180)
        #if PROBE_REQUIRED
        height.priority = .required
        #else
        height.priority = UILayoutPriority(999)
        #endif
        height.isActive = true
        heightConstraint = height
        #endif

        let key = UIButton(type: .system)
        key.setTitle("a", for: .normal)
        key.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(key)
        NSLayoutConstraint.activate([
            key.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            key.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            key.widthAnchor.constraint(equalToConstant: 44),
            key.heightAnchor.constraint(equalToConstant: 44)
        ])
        key.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.insertText("a")
        }, for: .touchUpInside)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if PROBE_TRAIT_REFRESH
        let proxy = textDocumentProxy
        let acceptsSetter = proxy.responds(to: #selector(setter: UITextInputTraits.keyboardType))
        log.notice("MARGIN-TRAIT keyboardTypeSetter=\(acceptsSetter)")
        if acceptsSetter, let original = proxy.keyboardType, let object = proxy as? NSObject {
            // Swift does not expose the optional ObjC protocol setter here.
            // Dispatch only the public property, after checking its setter.
            object.setValue(original.rawValue, forKey: "keyboardType")
        }
        #endif
        #if PROBE_CONTEXT_REFRESH
        // Isolated host only: determine whether a selection update causes the
        // remote container to rebuild. This is not a production workaround.
        textDocumentProxy.adjustTextPosition(byCharacterOffset: 0)
        #endif
        #if PROBE_GEOMETRY_REFRESH
        setNeedsUpdateOfSupportedInterfaceOrientations()
        if let scene = view.window?.windowScene {
            let current = scene.interfaceOrientation
            let mask: UIInterfaceOrientationMask = current == .landscapeLeft ? .landscapeLeft
                : current == .landscapeRight ? .landscapeRight
                : current == .portraitUpsideDown ? .portraitUpsideDown : .portrait
            log.notice("MARGIN-GEOMETRY request orientation=\(current.rawValue)")
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] error in
                self?.log.notice("MARGIN-GEOMETRY rejected=\(error.localizedDescription, privacy: .public)")
            }
        } else {
            log.notice("MARGIN-GEOMETRY no window scene")
        }
        #endif
        #if PROBE_INPUT_MODE
        recordInputMode("didAppear")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.recordInputMode("settled")
        }
        #endif
        #if PROBE_RECREATE
        let replacement = UIInputView(frame: view.bounds, inputViewStyle: .keyboard)
        inputView = replacement
        configureProbe()
        #endif
        #if PROBE_LANGUAGE
        primaryLanguage = "bn-BD"
        #endif
        #if PROBE_DICTATION_REFRESH
        // Documented setter: true temporarily disables the system dictation
        // key; false restores it. Tests whether rebuilding the system dock also
        // invalidates the stale top inset, while preserving the text responder.
        hasDictationKey = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.hasDictationKey = false
        }
        #endif
        #if PROBE_DICTATION_FALSE
        hasDictationKey = false
        #endif
        #if PROBE_LANGUAGE_REFRESH
        primaryLanguage = "en-US"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.primaryLanguage = "bn-BD"
        }
        #endif
        #if PROBE_PREFERRED || PROBE_PREFERRED_ONLY
        preferredContentSize = CGSize(width: view.bounds.width, height: 180)
        #endif
        #if PROBE_PULSE
        heightConstraint?.constant = 197
        view.setNeedsUpdateConstraints()
        view.layoutIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.heightConstraint?.constant = 180
            self?.view.setNeedsUpdateConstraints()
            self?.view.layoutIfNeeded()
        }
        #endif
        #if PROBE_OBSERVE || PROBE_DICTATION_REFRESH || PROBE_DICTATION_FALSE
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let window = self.view.window else { return }
            let guide = self.view.keyboardLayoutGuide.layoutFrame
            let converted = UIAccessibility.convertToScreenCoordinates(self.view.bounds, in: self.view)
            let button = self.view.subviews.compactMap { $0 as? UIButton }.first
            self.log.notice("MARGIN-OBSERVE root=\(NSCoder.string(for: self.view.bounds), privacy: .public) guide=\(NSCoder.string(for: guide), privacy: .public) ax=\(NSCoder.string(for: self.view.accessibilityFrame), privacy: .public) axConverted=\(NSCoder.string(for: converted), privacy: .public) buttonAX=\(NSCoder.string(for: button?.accessibilityFrame ?? .zero), privacy: .public) window=\(NSCoder.string(for: window.frame), privacy: .public) language=\(self.primaryLanguage ?? "nil", privacy: .public) dictation=\(self.hasDictationKey) switch=\(self.needsInputModeSwitchKey)")
        }
        #endif
    }
}

#if PROBE_INTRINSIC || PROBE_FITTING
private final class ProbeInputView: UIInputView {
    #if PROBE_FITTING
    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        CGSize(width: targetSize.width, height: 180)
    }
    override func systemLayoutSizeFitting(_ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority) -> CGSize {
        CGSize(width: targetSize.width, height: 180)
    }
    #endif
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 180)
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: 180)
    }
}
#endif
