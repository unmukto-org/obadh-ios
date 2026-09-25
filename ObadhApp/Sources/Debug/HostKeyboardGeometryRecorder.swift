#if DEBUG
import UIKit
import os

/// Measures the system-owned container from the host side. Extension-local bounds
/// cannot establish whether UIKit added a band outside the extension's window.
/// Records geometry only, and is used solely by the debug keyboard harnesses.
@MainActor
final class HostKeyboardGeometryRecorder: NSObject {
    private let log = Logger(subsystem: "org.unmukto.obadh.keyboard", category: "host-geometry")
    private weak var hostView: UIView?
    private var lastKeyboardFrame: CGRect = .zero
    var onKeyboardHeightChange: ((CGFloat) -> Void)?

    func start(in view: UIView) {
        hostView = view
        NotificationCenter.default.removeObserver(self)
        for name in [UIResponder.keyboardWillChangeFrameNotification,
                     UIResponder.keyboardDidChangeFrameNotification,
                     UIApplication.willEnterForegroundNotification,
                     UIApplication.didBecomeActiveNotification,
                     UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(record(_:)), name: name, object: nil)
        }
    }

    @objc private func record(_ notification: Notification) {
        guard let view = hostView, let window = view.window else { return }
        if let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
            lastKeyboardFrame = frame
            onKeyboardHeightChange?(frame.height)
        }
        // Notification frames are in screen coordinates; use the window's screen,
        // not UIScreen.main, so rotation and external screens are interpreted correctly.
        let inWindow = window.convert(lastKeyboardFrame, from: window.screen.coordinateSpace)
        let intersection = window.bounds.intersection(inWindow)
        let overlap = intersection.isNull ? 0 : intersection.height
        let guide = view.keyboardLayoutGuide.layoutFrame
        log.notice("OBADH-HOST event=\(notification.name.rawValue, privacy: .public) os=\(UIDevice.current.systemVersion, privacy: .public) frame=\(NSCoder.string(for: self.lastKeyboardFrame), privacy: .public) overlap=\(overlap) guide=\(NSCoder.string(for: guide), privacy: .public) safeBottom=\(view.safeAreaInsets.bottom)")
    }
}
#endif
