import XCTest
import UIKit

// Compile the actual controller and UIKit views into this test bundle. These
// exercise production lifecycle/delegate paths without depending on host IPC.
@MainActor
final class KeyboardLifecycleTests: XCTestCase {
    private func stored<T>(_ name: String, in object: Any, as: T.Type = T.self) throws -> T {
        try XCTUnwrap(Mirror(reflecting: object).children.first { $0.label == name || $0.label == "$__lazy_storage_$_" + name }?.value as? T)
    }

    private func makeController() -> KeyboardViewController {
        KeyboardTheme.legacyPresentation = false
        KeyboardTheme.debugFullZoneStrip = false
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 440, height: 253)
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        controller.viewDidLayoutSubviews()
        addTeardownBlock { @MainActor in
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
            let repeater: BackspaceRepeatController = try self.stored("backspaceRepeater", in: controller)
            repeater.end()
        }
        return controller
    }

    func testRepeatStillFiresAndStops() async throws {
        let repeater = BackspaceRepeatController(policy: BackspaceRepeatPolicy(
            initialDelay: 0, mediumRepeatStart: 1, fastRepeatStart: 2, fastestRepeatStart: 3))
        defer { repeater.end() }
        var calls = 0
        let repeated = expectation(description: "Held delete repeats")
        repeater.begin { _ in
            calls += 1
            if calls == 2 { repeated.fulfill() }
        }
        await fulfillment(of: [repeated], timeout: 1)
        repeater.end()
        let stoppedAt = calls
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(calls, stoppedAt)
    }

    func testRepeatTimerDoesNotRetainItsOwner() {
        weak var weakRepeater: BackspaceRepeatController?
        do {
            let repeater = BackspaceRepeatController()
            weakRepeater = repeater
            repeater.begin { _ in }
            XCTAssertTrue(repeater.isActive)
        }
        XCTAssertNil(weakRepeater, "Discarding a keyboard must not leak a repeating timer")
        weakRepeater?.end() // Clean up the failing baseline too.
    }

    func testDisappearingStopsHeldBackspace() throws {
        let controller = makeController()
        controller.handleDebugCommand("tap", argument: "a,b")
        let panel = EmojiPanelView()
        controller.emojiPanelViewDidBeginBackspace(panel)
        let repeater: BackspaceRepeatController = try stored("backspaceRepeater", in: controller)
        XCTAssertTrue(repeater.isActive)
        controller.beginAppearanceTransition(false, animated: false)
        controller.endAppearanceTransition()
        XCTAssertFalse(repeater.isActive, "A hidden keyboard must not keep deleting host text")
    }

    func testRowRebuildStopsHeldBackspace() throws {
        let controller = makeController()
        let surface: KeyboardTouchSurfaceView = try stored("keyboardTouchSurface", in: controller)
        controller.handleDebugCommand("tap", argument: "a,b")
        controller.keyboardTouchSurface(surface, didBegin: .backspace)
        let repeater: BackspaceRepeatController = try stored("backspaceRepeater", in: controller)
        XCTAssertTrue(repeater.isActive)
        controller.handleDebugCommand("mode", argument: "numbers")
        XCTAssertFalse(repeater.isActive, "Replacing the touched row must end its repeat timer")
    }

    func testContextResetInvalidatesAsyncSuggestionsAndClearsRibbon() throws {
        let controller = makeController()
        controller.handleDebugCommand("tap", argument: "a")
        let work: DispatchWorkItem = try stored("pendingSuggestionWork", in: controller)
        let bar: SuggestionBarView = try stored("suggestionBar", in: controller)
        bar.update(suggestions: [KeyboardSuggestion(text: "old context", source: .autosuggest)])
        let generation: Int = try stored("suggestionGeneration", in: controller)
        controller.textWillChange(nil)
        let nextGeneration: Int = try stored("suggestionGeneration", in: controller)
        let suggestions: [KeyboardSuggestion] = try stored("suggestions", in: bar)
        XCTAssertNotEqual(generation, nextGeneration, "Old async results must be rejected before textDidChange")
        XCTAssertTrue(suggestions.isEmpty, "Old choices must not remain tappable against a new document")
        XCTAssertTrue(work.isCancelled)
    }

    func testRibbonHeightDoesNotFollowTransientRootHeights() throws {
        let controller = makeController()
        let bar: SuggestionBarView = try stored("suggestionBar", in: controller)
        let height: NSLayoutConstraint = try stored("keyboardHeightConstraint", in: controller)
        let ask = height.constant
        controller.view.layoutIfNeeded()
        let strip = bar.bounds.height
        XCTAssertGreaterThan(strip, 0)
        // UIKit has been observed to offer fullscreen and intermediate heights.
        // Replaying them verifies our own ribbon geometry, not the host's band.
        for offeredHeight in [956.0, 452, 481, ask, 260, ask] {
            controller.view.bounds.size.height = offeredHeight
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            XCTAssertEqual(bar.bounds.height, strip, accuracy: 0.5)
            XCTAssertEqual(height.constant, ask, accuracy: 0.5)
        }
        controller.beginAppearanceTransition(false, animated: false)
        controller.endAppearanceTransition()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(bar.bounds.height, strip, accuracy: 0.5)
    }

    func testPhoneRowsStayAtTheBottomDuringTransientSizing() throws {
        let controller = makeController()
        let stack: UIStackView = try stored("keyboardStack", in: controller)
        controller.view.layoutIfNeeded()
        let normal = stack.convert(stack.bounds, to: controller.view)
        let bottomInset = controller.view.bounds.maxY - normal.maxY
        for height in [956.0, 452, 253] {
            controller.view.bounds.size.height = height
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            let frame = stack.convert(stack.bounds, to: controller.view)
            XCTAssertEqual(controller.view.bounds.maxY - frame.maxY, bottomInset, accuracy: 0.5,
                           "A temporary oversized root must not lift the keys hundreds of points")
        }
    }

    func testTouchEndingAfterRowsRebuildDoesNotType() throws {
        let controller = makeController()
        controller.view.layoutIfNeeded()
        let surface: KeyboardTouchSurfaceView = try stored("keyboardTouchSurface", in: controller)
        surface.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let region = KeyboardTouchKeyRegion(key: .character("a"), visualFrame: surface.bounds)
        surface.keyRows = [[region]]
        let touch = UITouch()
        surface.touchesBegan([touch], with: nil)
        let tracked: UITouch = try stored("activeTouch", in: surface)
        XCTAssertTrue(tracked === touch)
        controller.handleDebugCommand("mode", argument: "numbers")
        controller.handleDebugCommand("mode", argument: "letters")
        controller.view.layoutIfNeeded()
        surface.keyRows = [[region]]
        surface.touchesEnded([touch], with: nil)
        let composer: KeyboardComposer = try stored("composer", in: controller)
        XCTAssertEqual(composer.romanBuffer, "", "A cancelled touch must not commit a replacement key")
    }

    func testContextResetClearsCarriedEmoji() throws {
        let controller = makeController()
        controller.handleDebugCommand("tap", argument: "b,h,a,l,o,b,a,s,a,space")
        let before: [EmojiSuggestion] = try stored("carriedEmojis", in: controller)
        XCTAssertFalse(before.isEmpty)
        controller.selectionWillChange(nil)
        let after: [EmojiSuggestion] = try stored("carriedEmojis", in: controller)
        XCTAssertTrue(after.isEmpty)
    }

    func testAccessibleKeysActivateTypingAndDeleteOnce() throws {
        let controller = makeController()
        let buttons: [KeyboardKeyButton] = try stored("keyButtons", in: controller)
        let a = try XCTUnwrap(buttons.first { $0.key == .character("a") })
        let delete = try XCTUnwrap(buttons.first { $0.key == .backspace })
        XCTAssertTrue(a.isUserInteractionEnabled)
        XCTAssertTrue(a.accessibilityActivate(), "VoiceOver activation must reach the typing path")
        let composer: KeyboardComposer = try stored("composer", in: controller)
        XCTAssertEqual(composer.romanBuffer, "a")
        XCTAssertEqual(delete.accessibilityLabel, "Delete")
        XCTAssertTrue(delete.accessibilityActivate())
        XCTAssertEqual(composer.romanBuffer, "")
        let repeater: BackspaceRepeatController = try stored("backspaceRepeater", in: controller)
        XCTAssertFalse(repeater.isActive)
    }

    func testCapsLockSurvivesConsecutiveLetters() throws {
        let controller = makeController()
        let surface: KeyboardTouchSurfaceView = try stored("keyboardTouchSurface", in: controller)
        controller.keyboardTouchSurface(surface, didEnd: .capsLock, flickedDown: false)
        controller.handleDebugCommand("tap", argument: "a,b")
        let composer: KeyboardComposer = try stored("composer", in: controller)
        XCTAssertEqual(composer.romanBuffer, "AB")
        XCTAssertTrue(try stored("shifted", in: controller, as: Bool.self))
    }
}
