import UIKit

// Used ONLY by scripts/parity/generate-margin-probe.py's separate project.
// Deliberately no Obadh engine, theme, suggestions, sizing classifier or touch
// surface. Keeps the controller name from the extension's existing Info.plist.
final class KeyboardViewController: UIInputViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        inputView?.allowsSelfSizing = true
        view.backgroundColor = .systemPink
        let height = view.heightAnchor.constraint(equalToConstant: 180)
        height.priority = UILayoutPriority(999)
        height.isActive = true

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
}
