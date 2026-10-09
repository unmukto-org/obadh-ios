#if DEBUG
import UIKit

/// Real first responders for field-trait qualification. No trait injection into
/// the extension: these hints cross the actual iOS keyboard-service boundary.
final class KeyboardFieldTestViewController: UIViewController, UITextFieldDelegate {
    private let status = UILabel()
    private var fields: [UITextField] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Input fields"
        view.backgroundColor = .systemBackground
        status.text = "Ready"
        status.accessibilityIdentifier = "field-action-status"
        status.font = .preferredFont(forTextStyle: .caption1)
        status.numberOfLines = 2
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scenarios: [(String, UIKeyboardType, UITextContentType?, UIReturnKeyType)] = [
            ("prose", .default, nil, .send),
            ("email", .emailAddress, .emailAddress, .next),
            ("url", .URL, .URL, .go),
            ("number", .asciiCapableNumberPad, nil, .default),
            ("decimal", .decimalPad, nil, .default),
            ("search", .webSearch, nil, .search),
            ("code", .asciiCapable, .oneTimeCode, .done),
            ("latin", .asciiCapable, nil, .done),
            ("uncorrected", .default, nil, .send)
        ]
        for (name, keyboard, content, action) in scenarios {
            let field = UITextField()
            field.borderStyle = .roundedRect
            field.placeholder = name.capitalized
            field.accessibilityIdentifier = "field-" + name
            field.keyboardType = keyboard
            field.textContentType = content
            field.returnKeyType = action
            field.autocapitalizationType = name == "latin" ? .sentences : .none
            field.autocorrectionType = name == "uncorrected" ? .no : .default
            field.smartQuotesType = .default
            field.smartDashesType = .default
            field.enablesReturnKeyAutomatically = name == "search"
            field.delegate = self
            field.heightAnchor.constraint(equalToConstant: 34).isActive = true
            fields.append(field)
            stack.addArrangedSubview(field)
        }
        stack.addArrangedSubview(status)
        let multiline = UITextView()
        multiline.accessibilityIdentifier = "field-multiline"
        multiline.accessibilityLabel = "Multiline"
        multiline.font = .systemFont(ofSize: 17)
        multiline.backgroundColor = .secondarySystemBackground
        multiline.autocapitalizationType = .none
        multiline.heightAnchor.constraint(equalToConstant: 42).isActive = true
        stack.addArrangedSubview(multiline)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        fields.first?.becomeFirstResponder()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        print("OBADH-FIELD-HOST native Return callback")
        status.text = "\(textField.accessibilityIdentifier ?? "field"): \(textField.text ?? "")"
        return false // Submission is recorded without dismissing the test keyboard.
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        if string == " " || string.contains(where: \.isNewline) {
            print("OBADH-FIELD-HOST separator scalars: \(string.unicodeScalars.map(\.value))")
        }
        return true
    }
}
#endif
