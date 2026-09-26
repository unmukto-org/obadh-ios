import UIKit

// DEBUG-only measurement harness for scripts/measure-keyboard-geometry.py. It carries
// a text view to summon the keyboard, so it must not exist in Release.
#if DEBUG
final class KeyboardGeometryProbeViewController: UIViewController {
    private let geometryRecorder = HostKeyboardGeometryRecorder()
    private let textView: ProbeTextView

    init() {
        textView = ProbeTextView()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        geometryRecorder.start(in: view)
        view.backgroundColor = .systemBackground

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .systemBackground
        textView.textColor = .label
        textView.tintColor = .systemBlue
        textView.font = .systemFont(ofSize: 24)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .yes
        textView.spellCheckingType = .yes
        textView.keyboardType = .alphabet
        textView.text = ""
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard ProcessInfo.processInfo.arguments.contains("--probe-autofocus") else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            textView.becomeFirstResponder()
            textView.reloadInputViews()
        }
    }
}

private final class ProbeTextView: UITextView {
    init() {
        super.init(frame: .zero, textContainer: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
#endif
