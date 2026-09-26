import UIKit

// Standalone public-API reproduction. No Obadh modules, app groups or preferences.
final class KeyboardViewController: UIInputViewController {
    private let sizeLabel = UILabel()
    private let connectionLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        inputView?.allowsSelfSizing = true
        view.backgroundColor = .systemPink
        view.layer.borderWidth = 2
        view.layer.borderColor = UIColor.white.cgColor
        let height = view.heightAnchor.constraint(equalToConstant: 180)
        height.priority = UILayoutPriority(999)
        height.isActive = true

        sizeLabel.accessibilityIdentifier = "extension-height"
        sizeLabel.textAlignment = .center
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sizeLabel)
        connectionLabel.accessibilityIdentifier = "extension-connection"
        connectionLabel.font = .systemFont(ofSize: 12)
        connectionLabel.textAlignment = .center
        connectionLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(connectionLabel)
        let key = UIButton(type: .system)
        key.setTitle("Insert a", for: .normal)
        key.accessibilityValue = "untapped"
        key.addAction(UIAction { [weak self, weak key] _ in
            guard let self else {
                key?.accessibilityValue = "controller-missing"
                return
            }
            key?.accessibilityValue = "tapped"
            self.recordConnection("tap")
            self.textDocumentProxy.insertText("a")
        }, for: .touchUpInside)
        let next = UIButton(type: .system)
        next.setTitle("Next keyboard", for: .normal)
        next.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        let row = UIStackView(arrangedSubviews: [key, next])
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            sizeLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            sizeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sizeLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            connectionLabel.topAnchor.constraint(equalTo: sizeLabel.bottomAnchor, constant: 8),
            connectionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            connectionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            row.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        recordConnection("appeared")
    }

    private func recordConnection(_ phase: String) {
        let proxy = textDocumentProxy
        let before = proxy.documentContextBeforeInput?.count ?? -1
        let after = proxy.documentContextAfterInput?.count ?? -1
        connectionLabel.text = "\(phase): context lengths \(before), \(after)"
        connectionLabel.accessibilityValue = "phase=\(phase) before=\(before) after=\(after) hasText=\(proxy.hasText) document=\(proxy.documentIdentifier)"
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeLabel.text = "Extension content: \(view.bounds.height) pt"
        sizeLabel.accessibilityValue = String(Double(view.bounds.height))
    }
}
