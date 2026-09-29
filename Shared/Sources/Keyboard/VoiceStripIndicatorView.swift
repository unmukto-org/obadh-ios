import UIKit

/// Voice typing in the suggestion strip: the shared `VoiceGlowView`, plus a short
/// status line when there is something to say (opening the app, finishing, a
/// problem). The keys below are untouched.
final class VoiceStripIndicatorView: UIView {
    var levelSource: (() -> VoiceLevelFrame)? {
        get { glow.levelSource }
        set { glow.levelSource = newValue }
    }

    private let glow = VoiceGlowView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = [.button, .updatesFrequently]

        glow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glow)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        label.alpha = 0
        addSubview(label)

        NSLayoutConstraint.activate([
            glow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            glow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            glow.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            glow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `textColor` is the strip's own candidate colour, so status text matches it.
    func setPhase(_ phase: VoicePanelPhase, textColor: UIColor) {
        label.textColor = textColor
        let text: String?
        switch phase {
        case .connecting:
            glow.setMode(.waiting)
            text = "অবাধ খুলছে…"
        case .ready, .listening:
            glow.setMode(.live)
            text = nil
        case .finishing:
            glow.setMode(.finishing)
            text = nil
        case .problem(let message):
            glow.setMode(.hidden)
            text = message
        }
        label.text = text
        accessibilityLabel = text ?? (phase == .finishing ? "Finishing" : "Listening. Tap to finish.")
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.label.alpha = text == nil ? 0 : 1
        }
    }
}
