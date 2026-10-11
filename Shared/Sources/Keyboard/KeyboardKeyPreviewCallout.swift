import UIKit

final class KeyboardKeyPreviewCallout: UIView {
    private let shapeLayer = CAShapeLayer()
    private let label = UILabel()
    private var metrics = KeyboardTheme.defaultMetrics

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(text: String, metrics: KeyboardMetrics, traitCollection: UITraitCollection, themePalette: KeyboardThemePalette? = nil) {
        self.metrics = metrics
        label.text = text
        label.font = .systemFont(ofSize: metrics.keyPreviewFontSize, weight: .regular)
        label.textColor = themePalette?.ink.uiColor ?? KeyboardTheme.textColor(for: traitCollection)
        shapeLayer.fillColor = (themePalette?.opaqueKey.uiColor ?? KeyboardTheme.keyPreviewColor(for: traitCollection)).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = metrics.keyPreviewShadowOpacity
        layer.shadowRadius = metrics.keyPreviewShadowRadius
        layer.shadowOffset = metrics.keyPreviewShadowOffset
        setNeedsLayout()
    }

    static func preferredSize(for keyBounds: CGRect, metrics: KeyboardMetrics) -> CGSize {
        let width = max(metrics.keyPreviewMinimumWidth, keyBounds.width + metrics.keyPreviewHorizontalOutset)
        return CGSize(width: width, height: metrics.keyPreviewHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shapeLayer.frame = bounds
        shapeLayer.path = path(in: bounds).cgPath

        let stemHeight = metrics.keyPreviewStemHeight
        label.frame = CGRect(
            x: 0,
            y: 1,
            width: bounds.width,
            height: max(0, bounds.height - stemHeight - 3)
        )
    }

    private func configure() {
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false

        layer.masksToBounds = false
        layer.insertSublayer(shapeLayer, at: 0)

        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.72
        addSubview(label)
    }

    private func path(in rect: CGRect) -> UIBezierPath {
        let stemHeight = metrics.keyPreviewStemHeight
        let cornerRadius = metrics.keyPreviewCornerRadius
        let bodyRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: max(0, rect.height - stemHeight)
        )

        let path = UIBezierPath(
            roundedRect: bodyRect,
            cornerRadius: cornerRadius
        )

        // The native key preview is a plain rounded rectangle (verified on iOS 27
        // device screenshots); the stem only renders if a metrics variant asks.
        guard stemHeight > 0 else { return path }

        let stemWidth = min(metrics.keyPreviewStemWidth, rect.width * 0.42)
        let stemTopInset: CGFloat = min(8, bodyRect.width * 0.12)
        let centerX = rect.midX
        let stemTopY = bodyRect.maxY - 1
        let stemBottomY = rect.maxY

        path.move(to: CGPoint(x: centerX - stemWidth / 2, y: stemTopY))
        path.addCurve(
            to: CGPoint(x: centerX, y: stemBottomY),
            controlPoint1: CGPoint(x: centerX - stemWidth / 2 + stemTopInset, y: stemTopY),
            controlPoint2: CGPoint(x: centerX - stemWidth / 4, y: stemBottomY)
        )
        path.addCurve(
            to: CGPoint(x: centerX + stemWidth / 2, y: stemTopY),
            controlPoint1: CGPoint(x: centerX + stemWidth / 4, y: stemBottomY),
            controlPoint2: CGPoint(x: centerX + stemWidth / 2 - stemTopInset, y: stemTopY)
        )
        path.close()

        return path
    }
}
