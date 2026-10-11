import XCTest
import UIKit

/// iOS creates a keyboard controller for every presentation, and on a return from
/// another app often a spare one that is loaded but never shown. Every one of them
/// must be freed, or the extension grows by a full keyboard per app switch until
/// iOS stops loading it and falls back to the system keyboard.
@MainActor
final class KeyboardControllerReleaseTests: XCTestCase {
    private func firstKey(in view: UIView) -> KeyboardKeyButton? {
        if let key = view as? KeyboardKeyButton { return key }
        for child in view.subviews {
            if let key = firstKey(in: child) { return key }
        }
        return nil
    }

    private func present(_ controller: KeyboardViewController) {
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 440, height: 253)
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        controller.view.layoutIfNeeded()
    }

    private func hide(_ controller: KeyboardViewController) {
        controller.beginAppearanceTransition(false, animated: false)
        controller.endAppearanceTransition()
    }

    func testRetainedNeverPresentedControllerShedsViewsAndCanLaterAppear() async throws {
        // Deliberately keep the orphan alive, as the device's view-service
        // operator does. The simulator's ordinary release test cannot model it.
        let orphan = KeyboardViewController()
        orphan.loadViewIfNeeded()
        let root = orphan.view!
        root.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        root.layoutIfNeeded()
        weak var originalKey = firstKey(in: root)
        XCTAssertNotNil(originalKey)
        let visible = KeyboardViewController()
        present(visible)
        XCTAssertTrue(orphan.isContentSuspended)
        XCTAssertFalse(visible.isContentSuspended)
        XCTAssertNil(firstKey(in: root))

        // Late layout, traits, text callbacks and repeated warnings must not
        // silently reconstruct the orphan's content.
        root.frame.size.width = 430
        orphan.viewDidLayoutSubviews()
        orphan.textWillChange(nil)
        orphan.textDidChange(nil)
        orphan.selectionDidChange(nil)
        orphan.didReceiveMemoryWarning()
        await drain()
        XCTAssertNil(originalKey)
        XCTAssertNil(firstKey(in: root))
        XCTAssertTrue(orphan.isContentSuspended)

        hide(visible)
        present(orphan)
        XCTAssertTrue(orphan.view === root, "Keep UIKit's root and sizing contract")
        XCTAssertFalse(orphan.isContentSuspended)
        XCTAssertNotNil(firstKey(in: root), "A later presentation must rebuild working keys")
        hide(orphan)
        present(orphan)
        XCTAssertNotNil(firstKey(in: root), "Repeated shed/restore must also work")
        hide(orphan)
    }

    func testLateSpareIsShedButDisappearingControllerKeepsContentUntilTransitionEnds() {
        let outgoing = KeyboardViewController()
        present(outgoing)
        let spare = KeyboardViewController()
        spare.loadViewIfNeeded()
        XCTAssertTrue(spare.isContentSuspended)

        outgoing.beginAppearanceTransition(false, animated: true)
        let incoming = KeyboardViewController()
        present(incoming)
        XCTAssertFalse(outgoing.isContentSuspended, "Do not blank an outgoing animation")
        incoming.didReceiveMemoryWarning()
        XCTAssertFalse(incoming.isContentSuspended, "Never shed a presented keyboard")
        outgoing.endAppearanceTransition()
        XCTAssertTrue(outgoing.isContentSuspended)
        hide(incoming)
    }

    private func drain() async {
        // Let queued main-actor work (suggestion queries, deferred layout) finish.
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func testControllerLoadedButNeverShownIsFreed() async {
        weak var weakController: KeyboardViewController?
        do {
            let controller = KeyboardViewController()
            weakController = controller
            controller.loadViewIfNeeded()
            controller.view.frame = CGRect(x: 0, y: 0, width: 440, height: 253)
            controller.view.layoutIfNeeded()
        }
        await drain()
        XCTAssertNil(weakController, "A keyboard iOS loaded but never showed must be freed")
    }

    func testControllerShownThenHiddenIsFreed() async {
        weak var weakController: KeyboardViewController?
        do {
            let controller = KeyboardViewController()
            weakController = controller
            controller.loadViewIfNeeded()
            controller.view.frame = CGRect(x: 0, y: 0, width: 440, height: 253)
            controller.beginAppearanceTransition(true, animated: false)
            controller.endAppearanceTransition()
            controller.view.layoutIfNeeded()
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
        }
        await drain()
        XCTAssertNil(weakController, "A keyboard that was shown and hidden must be freed")
    }
}
