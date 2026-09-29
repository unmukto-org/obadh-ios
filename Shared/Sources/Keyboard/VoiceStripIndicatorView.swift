import UIKit

/// Voice typing's only presence in the suggestion strip: a short message when the
/// user has something to fix (Full Access, the download, the microphone). The
/// dictation itself happens on the app's voice screen, so the keyboard draws no
/// dictation UI, and deliberately loads no Metal or SwiftUI: a keyboard extension
/// has a small memory ceiling, and an unused voice renderer here once pushed the
/// keyboard past it.
final class VoiceStripIndicatorView: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .staticText

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 52),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Aligns the message with the strip's content line.
    func setContentOffset(_ offset: CGFloat) {
        label.transform = CGAffineTransform(translationX: 0, y: offset)
    }

    /// `textColor` is the strip's own candidate colour.
    func setPhase(_ phase: VoicePanelPhase, textColor: UIColor) {
        label.textColor = textColor
        if case .problem(let message) = phase {
            label.text = message
            accessibilityLabel = message
        } else {
            label.text = nil
            accessibilityLabel = nil
        }
    }
}
