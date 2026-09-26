import AudioToolbox
import UIKit

// Separate research app. These undocumented numeric IDs are intentionally absent
// from Obadh's shipping targets. No copied Apple assets or audio session overrides.
@main
final class SoundProbeApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = SoundProbeController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class SoundProbeController: UIViewController {
    private let field = UITextField()

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "Keyboard sound comparison"
        title.font = .preferredFont(forTextStyle: .title2)
        title.numberOfLines = 0
        let instructions = UILabel()
        instructions.text = """
        Choose Apple English below as the reference. Compare letters, space and delete with the four buttons above it.

        1. Listen with Silent Mode off and system Keyboard Feedback → Sound on.
        2. Turn Silent Mode on: test all four buttons.
        3. Turn Silent Mode off, but system Keyboard Feedback → Sound off: test again.

        Report which buttons still sound in each case. This separate app leaves Obadh unchanged. Nothing is recorded.
        """
        instructions.font = .preferredFont(forTextStyle: .subheadline)
        instructions.numberOfLines = 0
        field.borderStyle = .roundedRect
        field.placeholder = "Tap here, then choose Apple English"
        field.autocorrectionType = .no
        field.inputAccessoryView = SoundComparisonAccessory(frame: CGRect(x: 0, y: 0, width: 440, height: 74), inputViewStyle: .keyboard)
        let stack = UIStackView(arrangedSubviews: [title, instructions, field])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            field.heightAnchor.constraint(equalToConstant: 44)
        ])
    }
}

final class SoundComparisonAccessory: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }

    override init(frame: CGRect, inputViewStyle: UIInputView.Style) {
        super.init(frame: frame, inputViewStyle: inputViewStyle)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let cases: [(String, SystemSoundID?)] = [("UIKit\nclick", nil), ("Letter\n1104", 1104), ("Delete\n1155", 1155), ("Space\n1156", 1156)]
        for (label, id) in cases {
            let button = UIButton(type: .system)
            button.setTitle(label, for: .normal)
            button.titleLabel?.numberOfLines = 2
            button.titleLabel?.textAlignment = .center
            button.backgroundColor = .secondarySystemBackground
            button.layer.cornerRadius = 8
            button.addAction(UIAction { _ in
                if let id {
                    AudioServicesPlaySystemSound(id)
                } else {
                    UIDevice.current.playInputClick()
                }
            }, for: .touchDown)
            stack.addArrangedSubview(button)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
