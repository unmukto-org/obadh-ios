import UIKit

// Independent public-API host. Contains no keyboard extension, shared preference
// writes, private API inspection, or access to other apps' editors.
@main
final class HostAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Probe", sessionRole: session.role)
        configuration.delegateClass = HostSceneDelegate.self
        return configuration
    }
}

final class HostSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = HostViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

final class HostViewController: UIViewController {
    private let editor = UITextView()
    private let heightLabel = UILabel()
    private let resultLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.5, alpha: 1)
        let title = UILabel()
        title.text = "Keyboard height probe"
        title.font = .preferredFont(forTextStyle: .title2)
        heightLabel.accessibilityIdentifier = "probe-host-height"
        resultLabel.accessibilityIdentifier = "probe-reload-result"
        resultLabel.text = "No reload yet"
        resultLabel.numberOfLines = 0
        let reload = UIButton(type: .system)
        reload.setTitle("Reload input views", for: .normal)
        reload.addAction(UIAction { [weak self] _ in self?.reloadEditor() }, for: .touchUpInside)
        let represent = UIButton(type: .system)
        represent.setTitle("Re-present keyboard", for: .normal)
        represent.addAction(UIAction { [weak self] _ in self?.reloadEditor(represent: true) }, for: .touchUpInside)
        let select = UIButton(type: .system)
        select.setTitle("Select test word", for: .normal)
        select.addAction(UIAction { [weak self] _ in
            self?.editor.selectedRange = NSRange(location: 0, length: 5)
        }, for: .touchUpInside)
        let controls = UIStackView(arrangedSubviews: [title, heightLabel, reload, represent, select, resultLabel])
        controls.axis = .vertical
        controls.spacing = 12
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        editor.text = "hello "
        editor.font = .systemFont(ofSize: 24)
        editor.backgroundColor = .secondarySystemBackground
        editor.autocapitalizationType = .none
        editor.keyboardType = .default
        editor.accessibilityIdentifier = "probe-editor"
        editor.translatesAutoresizingMaskIntoConstraints = false
        let accessory = UIToolbar(frame: CGRect(x: 0, y: 0, width: 440, height: 44))
        accessory.items = [UIBarButtonItem(title: "Test accessory", style: .plain, target: nil, action: nil)]
        editor.inputAccessoryView = accessory
        view.addSubview(editor)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            editor.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 16),
            editor.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            editor.heightAnchor.constraint(equalToConstant: 110)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        editor.becomeFirstResponder()
    }

    @objc private func keyboardChanged(_ notification: Notification) {
        guard let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let height = value.cgRectValue.height
        heightLabel.text = "Keyboard frame: \(height) pt"
        heightLabel.accessibilityValue = String(Double(height))
        print("DEVICE-HOST height=\(height)")
    }

    private func reloadEditor(represent: Bool = false) {
        resultLabel.text = "Reloading…"
        resultLabel.accessibilityValue = "pending"
        let originalText = editor.text
        let originalSelection = editor.selectedRange
        let originalLanguage = editor.textInputMode?.primaryLanguage
        if represent {
            UIView.performWithoutAnimation {
                editor.resignFirstResponder()
                editor.becomeFirstResponder()
            }
        } else {
            editor.reloadInputViews()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let textOK = self.editor.text == originalText
            let selectionOK = self.editor.selectedRange == originalSelection
            let modeOK = self.editor.textInputMode?.primaryLanguage == originalLanguage
            let status = "text=\(textOK) selection=\(selectionOK) focus=\(self.editor.isFirstResponder) mode=\(modeOK)"
            self.resultLabel.text = status
            self.resultLabel.accessibilityValue = status
            print("DEVICE-HOST reload \(status)")
        }
    }
}
