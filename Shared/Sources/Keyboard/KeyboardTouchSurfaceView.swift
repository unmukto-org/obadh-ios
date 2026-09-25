import UIKit

@MainActor
protocol KeyboardTouchSurfaceViewDelegate: AnyObject {
    func keyboardTouchSurface(_ view: KeyboardTouchSurfaceView, didBegin key: KeyboardKey)
    func keyboardTouchSurface(_ view: KeyboardTouchSurfaceView, didMoveTo key: KeyboardKey)
    /// 0...1 of the way through a downward flick on `key`. Drives the animation
    /// that lifts the secondary glyph into the primary's place as the finger
    /// travels, which is the whole of what makes the gesture feel native — iPadOS
    /// does it in a private layer no extension can reach.
    func keyboardTouchSurface(
        _ view: KeyboardTouchSurfaceView,
        didUpdateFlickProgress progress: CGFloat,
        on key: KeyboardKey
    )
    /// `flickedDown` is the iPad secondary-glyph gesture: the touch was dragged
    /// downward far enough before lifting, without leaving the key.
    func keyboardTouchSurface(
        _ view: KeyboardTouchSurfaceView,
        didEnd key: KeyboardKey?,
        flickedDown: Bool
    )
    func keyboardTouchSurfaceDidCancel(_ view: KeyboardTouchSurfaceView)
}

class KeyboardTouchSurfaceView: UIView {
    weak var delegate: KeyboardTouchSurfaceViewDelegate?
    /// Downward travel that turns a tap into a secondary-glyph insert. Zero
    /// disables the gesture entirely, which is what iPhone uses — no iPhone key
    /// has a secondary, so a flick there would be a mystery keystroke.
    var flickThreshold: CGFloat = 0
    private final class Contact {
        let touch: UITouch
        let beganLocation: CGPoint
        let beganKey: KeyboardKey
        var location: CGPoint
        var region: KeyboardTouchResolvedRegion?
        var ended = false
        var announced = false

        init(touch: UITouch, location: CGPoint, region: KeyboardTouchResolvedRegion) {
            self.touch = touch
            beganLocation = location
            beganKey = region.key
            self.location = location
            self.region = region
        }
    }

    // Serialize commits by touch-down order. A second thumb may lift before the
    // first: retain its final position, but never insert ahead of the first key.
    // Delegate callbacks remain serial because delete repeat, shift and preview
    // currently have one active owner. No unfinished contact is committed early.
    private var contacts: [Contact] = []

    var keyRows: [[KeyboardTouchKeyRegion]] = [] {
        didSet {
            for contact in contacts where !contact.ended {
                contact.region = resolve(contact.location)
            }
        }
    }

    /// Touches with y above this (the suggestion bar) are passed through so the
    /// suggestion bar beneath receives them. Below it, the surface resolves keys.
    /// Lets the surface be full-bleed (uniform, no rectangle) while only owning
    /// the key area.
    var keyAreaTop: CGFloat = 0

    private weak var activeTouch: UITouch?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Set iteration is not chronological. Exact timestamp ties have no
        // observable intended order; position provides a reproducible tie break.
        let ordered = touches.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            let a = lhs.location(in: self), b = rhs.location(in: self)
            return a.x != b.x ? a.x < b.x : a.y < b.y
        }
        for touch in ordered where !contacts.contains(where: { $0.touch === touch }) {
            let point = touch.location(in: self)
            guard let region = resolve(point) else { continue }
            contacts.append(Contact(touch: touch, location: point, region: region))
        }
        drainContacts()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for contact in contacts where !contact.ended && touches.contains(contact.touch) {
            let previousKey = contact.region?.key
            update(contact)
            guard contact === contacts.first, contact.announced else { continue }
            reportFlick(contact)
            guard contact === contacts.first else { return }
            if let region = contact.region, region.key != previousKey {
                delegate?.keyboardTouchSurface(self, didMoveTo: region.key)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for contact in contacts where !contact.ended && touches.contains(contact.touch) {
            update(contact)
            contact.ended = true
        }
        drainContacts()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let first = contacts.first
        contacts.removeAll { touches.contains($0.touch) }
        if let first, touches.contains(first.touch) {
            activeTouch = nil
            resetFlick(first)
            delegate?.keyboardTouchSurfaceDidCancel(self)
        }
        drainContacts()
    }

    /// Row replacement and dismissal invalidate every contact, including queued
    /// second-thumb releases. Later events from those fingers cannot type.
    func cancelTracking() {
        let first = contacts.first
        contacts.removeAll()
        activeTouch = nil
        if let first { resetFlick(first) }
        delegate?.keyboardTouchSurfaceDidCancel(self)
    }

    private func update(_ contact: Contact) {
        contact.location = contact.touch.location(in: self)
        contact.region = resolve(contact.location) ?? contact.region
    }

    private func reportFlick(_ contact: Contact) {
        guard flickThreshold > 0 else { return }
        delegate?.keyboardTouchSurface(
            self,
            didUpdateFlickProgress: max(0, min(1, (contact.location.y - contact.beganLocation.y) / flickThreshold)),
            on: contact.beganKey
        )
    }

    private func resetFlick(_ contact: Contact) {
        guard flickThreshold > 0 else { return }
        delegate?.keyboardTouchSurface(self, didUpdateFlickProgress: 0, on: contact.beganKey)
    }

    private func drainContacts() {
        while let contact = contacts.first {
            if !contact.announced {
                contact.announced = true
                activeTouch = contact.touch
                delegate?.keyboardTouchSurface(self, didBegin: contact.region?.key ?? contact.beganKey)
                // A delegate may replace the layout or dismiss the keyboard.
                guard contact === contacts.first else { return }
            }
            guard contact.ended else { return }
            let flicked = flickThreshold > 0
                && contact.location.y - contact.beganLocation.y >= flickThreshold
            contacts.removeFirst()
            activeTouch = nil
            resetFlick(contact)
            delegate?.keyboardTouchSurface(
                self,
                didEnd: flicked ? contact.beganKey : contact.region?.key,
                flickedDown: flicked
            )
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, !keyRows.isEmpty else {
            return false
        }
        return point.y >= keyAreaTop && bounds.contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, !keyRows.isEmpty else {
            return nil
        }
        return (point.y >= keyAreaTop && bounds.contains(point)) ? self : nil
    }

    private func configure() {
        // CRITICAL: a custom keyboard EXTENSION drops touches over regions where
        // the touch-receiving view renders fully transparent (verified on-device
        // + on-sim; the system keyboard is exempt because it isn't an extension).
        // A visual-effect glass backdrop behind does NOT count — only a plain,
        // non-transparent background on THIS view makes the inter-key gaps
        // touchable. ~1/255 alpha: the system registers the color so touches
        // land, but it is genuinely imperceptible (0.02 was ~5x too high and
        // read as a tint). Do NOT set to `.clear`.
        // Ref: https://developer.apple.com/forums/thread/702798
        //
        // The tint must follow the appearance. White at 0.004 over a DARK keyboard
        // lifts it by 0.004 * 255 = 1.02, i.e. exactly one unit per channel — the
        // key area measured [23,23,24] against [22,22,23] everywhere else on a real
        // iPad, a visible seam between the keys and the strip above them. Black at
        // the same alpha over dark takes it to 21.91, which rounds back to 22 and is
        // genuinely invisible; light mode keeps white, where +0.13 of 223 is equally
        // invisible. Either way the view still has a non-nil backgroundColor, which
        // is the whole reason for doing this.
        backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.black.withAlphaComponent(0.004)
                : UIColor.white.withAlphaComponent(0.004)
        }
        isOpaque = false
        isUserInteractionEnabled = true
        isMultipleTouchEnabled = true
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityViewIsModal = false
    }

    private func resolve(_ point: CGPoint) -> KeyboardTouchResolvedRegion? {
        KeyboardTouchResolver.resolve(
            point: point,
            rows: keyRows,
            bounds: bounds
        )
    }
}
