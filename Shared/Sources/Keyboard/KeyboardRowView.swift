import UIKit

final class KeyboardRowView: UIView {
    var metrics = KeyboardTheme.defaultMetrics {
        didSet {
            setNeedsLayout()
        }
    }

    private var row: KeyboardRow?
    private(set) var keyButtons: [KeyboardKeyButton] = []

    func configure(row: KeyboardRow, buttons: [KeyboardKeyButton], metrics: KeyboardMetrics) {
        keyButtons.forEach { $0.removeFromSuperview() }
        self.row = row
        self.keyButtons = buttons
        self.metrics = metrics

        for button in buttons {
            button.isUserInteractionEnabled = true
            addSubview(button)
        }
        setNeedsLayout()
    }

    func keyRegions(in coordinateSpace: UIView) -> [KeyboardTouchKeyRegion] {
        keyButtons.map { button in
            KeyboardTouchKeyRegion(
                key: button.key,
                visualFrame: convert(button.frame, to: coordinateSpace)
            )
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let row else { return }

        let contentBounds = bounds.inset(by: UIEdgeInsets(
            top: 0,
            left: metrics.keyboardInsets.left,
            bottom: 0,
            right: metrics.keyboardInsets.right
        ))
        let frames = KeyboardLayoutGeometry.keyFrames(
            for: row,
            availableWidth: contentBounds.width,
            keySpacing: Double(metrics.keySpacing)
        )
        guard frames.count == keyButtons.count else { return }

        let scale = window?.screen.scale ?? UIScreen.main.scale
        for (index, frame) in frames.enumerated() {
            let minX = align(contentBounds.minX + CGFloat(frame.x), scale: scale)
            let maxX = align(contentBounds.minX + CGFloat(frame.x + frame.width), scale: scale)
            let visualFrame = CGRect(
                x: minX,
                y: 0,
                width: max(0, maxX - minX),
                height: bounds.height
            )
            keyButtons[index].frame = visualFrame
        }
    }

    private func align(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }
}
