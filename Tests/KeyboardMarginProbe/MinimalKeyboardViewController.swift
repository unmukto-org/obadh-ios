import UIKit

// Simulator-only control: no Obadh engine, theme, ribbon or touch routing.
// Generated independently by scripts/parity/generate-margin-probe.py.
final class KeyboardViewController: UIInputViewController {
    private var heightConstraint: NSLayoutConstraint?

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
        configureProbe()
    }

    private func configureProbe() {
        #if PROBE_SYSTEM_SIZING || PROBE_SYSTEM_DEFAULT
        inputView?.allowsSelfSizing = false
        #else
        inputView?.allowsSelfSizing = true
        #endif
        view.backgroundColor = .systemPink
        #if !PROBE_INTRINSIC && !PROBE_SYSTEM_DEFAULT && !PROBE_FITTING
        let height = view.heightAnchor.constraint(equalToConstant: 180)
        height.priority = UILayoutPriority(999)
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

    #if PROBE_RECREATE
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let replacement = UIInputView(frame: view.bounds, inputViewStyle: .keyboard)
        inputView = replacement
        configureProbe()
    }
    #endif

    #if PROBE_PULSE
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        heightConstraint?.constant = 197
        view.setNeedsUpdateConstraints()
        view.layoutIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.heightConstraint?.constant = 180
            self?.view.setNeedsUpdateConstraints()
            self?.view.layoutIfNeeded()
        }
    }
    #endif
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
