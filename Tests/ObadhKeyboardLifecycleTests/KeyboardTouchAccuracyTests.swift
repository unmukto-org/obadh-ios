import UIKit
import XCTest

/// Controlled traces through the production UIView. These are routing regression
/// tests, not measurements of human typing accuracy or UIKit's event delivery.
@MainActor
final class KeyboardTouchAccuracyTests: XCTestCase {
    private final class Finger: UITouch {
        var point: CGPoint
        let beganAt: TimeInterval
        init(x: CGFloat, time: TimeInterval) {
            point = CGPoint(x: x, y: 25)
            beganAt = time
            super.init()
        }
        override func location(in view: UIView?) -> CGPoint { point }
        override var timestamp: TimeInterval { beganAt }
    }

    private final class Recorder: KeyboardTouchSurfaceViewDelegate {
        var keys: [KeyboardKey] = []
        var beginnings: [KeyboardKey] = []
        var flicks: [Bool] = []
        var onCommit: (() -> Void)?
        func keyboardTouchSurface(_ view: KeyboardTouchSurfaceView, didBegin key: KeyboardKey) {
            beginnings.append(key)
        }
        func keyboardTouchSurface(_ view: KeyboardTouchSurfaceView, didMoveTo key: KeyboardKey) {}
        func keyboardTouchSurface(_ view: KeyboardTouchSurfaceView, didUpdateFlickProgress progress: CGFloat, on key: KeyboardKey) {}
        func keyboardTouchSurface(_ view: KeyboardTouchSurfaceView, didEnd key: KeyboardKey?, flickedDown: Bool) {
            if let key { keys.append(key) }
            flicks.append(flickedDown)
            onCommit?()
        }
        func keyboardTouchSurfaceDidCancel(_ view: KeyboardTouchSurfaceView) {}
    }

    private func surface(_ recorder: Recorder) -> KeyboardTouchSurfaceView {
        let view = KeyboardTouchSurfaceView(frame: CGRect(x: 0, y: 0, width: 150, height: 100))
        view.delegate = recorder
        view.keyRows = [[
            .init(key: .character("a"), visualFrame: CGRect(x: 0, y: 0, width: 50, height: 50)),
            .init(key: .character("b"), visualFrame: CGRect(x: 50, y: 0, width: 50, height: 50)),
            .init(key: .backspace, visualFrame: CGRect(x: 100, y: 0, width: 50, height: 50))
        ]]
        return view
    }

    func testAcceptsMultipleFingers() {
        XCTAssertTrue(surface(Recorder()).isMultipleTouchEnabled)
    }

    func testOverlappingThumbsDoNotDropSecondLetter() {
        let recorder = Recorder(), view = surface(recorder)
        let a = Finger(x: 25, time: 1), b = Finger(x: 75, time: 1.03)
        view.touchesBegan([a], with: nil)
        view.touchesBegan([b], with: nil)
        view.touchesEnded([a], with: nil)
        view.touchesEnded([b], with: nil)
        XCTAssertEqual(recorder.keys, [.character("a"), .character("b")])
    }

    func testReverseReleaseOrderPreservesTouchDownOrder() {
        let recorder = Recorder(), view = surface(recorder)
        let a = Finger(x: 25, time: 1), b = Finger(x: 75, time: 1.03)
        view.touchesBegan([a], with: nil)
        view.touchesBegan([b], with: nil)
        view.touchesEnded([b], with: nil)
        XCTAssertTrue(recorder.keys.isEmpty, "Do not guess or commit an unfinished gesture")
        view.touchesEnded([a], with: nil)
        XCTAssertEqual(recorder.keys, [.character("a"), .character("b")])
    }

    func testSequentialTypingAndLiftOffRetargetingRemainAvailable() {
        let recorder = Recorder(), view = surface(recorder)
        let a = Finger(x: 25, time: 1)
        view.touchesBegan([a], with: nil)
        a.point.x = 75
        view.touchesMoved([a], with: nil)
        view.touchesEnded([a], with: nil)
        let b = Finger(x: 25, time: 2)
        view.touchesBegan([b], with: nil)
        view.touchesEnded([b], with: nil)
        view.touchesEnded([b], with: nil)
        XCTAssertEqual(recorder.keys, [.character("b"), .character("a")])
    }

    func testBatchBeginsAndEndsUseTimestampsNotSetIterationOrder() {
        let recorder = Recorder(), view = surface(recorder)
        let a = Finger(x: 25, time: 2), b = Finger(x: 75, time: 1)
        view.touchesBegan([a, b], with: nil)
        view.touchesEnded([a, b], with: nil)
        XCTAssertEqual(recorder.keys, [.character("b"), .character("a")])
    }

    func testCancellingFirstFingerStillAllowsSecondFinger() {
        let recorder = Recorder(), view = surface(recorder)
        let a = Finger(x: 25, time: 1), b = Finger(x: 75, time: 2)
        view.touchesBegan([a], with: nil)
        view.touchesBegan([b], with: nil)
        view.touchesEnded([b], with: nil)
        view.touchesCancelled([a], with: nil)
        view.touchesEnded([a], with: nil)
        XCTAssertEqual(recorder.keys, [.character("b")])
    }

    func testCancellingSecondFingerDoesNotCancelFirst() {
        let recorder = Recorder(), view = surface(recorder)
        let a = Finger(x: 25, time: 1), b = Finger(x: 75, time: 2)
        view.touchesBegan([a], with: nil)
        view.touchesBegan([b], with: nil)
        view.touchesCancelled([b], with: nil)
        view.touchesEnded([a, b], with: nil)
        XCTAssertEqual(recorder.keys, [.character("a")])
    }

    func testLayoutReplacementInvalidatesQueuedFingersEvenInsideCommitCallback() {
        let recorder = Recorder(), view = surface(recorder)
        let a = Finger(x: 25, time: 1), b = Finger(x: 75, time: 2)
        recorder.onCommit = { view.cancelTracking() }
        view.touchesBegan([a], with: nil)
        view.touchesBegan([b], with: nil)
        view.touchesEnded([b], with: nil)
        view.touchesEnded([a], with: nil)
        view.touchesEnded([b], with: nil)
        XCTAssertEqual(recorder.keys, [.character("a")])
    }

    func testQueuedBackspaceDoesNotStartDeletingBeforeEarlierLetterCommits() {
        let recorder = Recorder(), view = surface(recorder)
        let a = Finger(x: 25, time: 1), delete = Finger(x: 125, time: 2)
        view.touchesBegan([a], with: nil)
        view.touchesBegan([delete], with: nil)
        XCTAssertEqual(recorder.beginnings, [.character("a")])
        view.touchesEnded([delete], with: nil)
        view.touchesEnded([a], with: nil)
        XCTAssertEqual(recorder.keys, [.character("a"), .backspace])
        XCTAssertEqual(recorder.beginnings, [.character("a"), .backspace])
    }

    func testQueuedIPadFlickKeepsItsOwnStartKeyAndDisplacement() {
        let recorder = Recorder(), view = surface(recorder)
        view.flickThreshold = 10
        let a = Finger(x: 25, time: 1), b = Finger(x: 75, time: 2)
        view.touchesBegan([a], with: nil)
        view.touchesBegan([b], with: nil)
        b.point = CGPoint(x: 25, y: 60)
        view.touchesMoved([b], with: nil)
        view.touchesEnded([b], with: nil)
        view.touchesEnded([a], with: nil)
        XCTAssertEqual(recorder.keys, [.character("a"), .character("b")])
        XCTAssertEqual(recorder.flicks, [false, true])
    }

    func testDismissalDropsAllContactsAndAllowsFreshTyping() {
        let recorder = Recorder(), view = surface(recorder)
        let a = Finger(x: 25, time: 1), b = Finger(x: 75, time: 2)
        view.touchesBegan([a], with: nil)
        view.touchesBegan([b], with: nil)
        view.cancelTracking()
        view.touchesEnded([a, b], with: nil)
        XCTAssertTrue(recorder.keys.isEmpty)
        let fresh = Finger(x: 75, time: 3)
        view.touchesBegan([fresh], with: nil)
        view.touchesEnded([fresh], with: nil)
        XCTAssertEqual(recorder.keys, [.character("b")])
    }

    func testOverlappingLettersReachRealComposerInOrder() throws {
        try checkControllerOverlap(first: .character("a"), expected: "ab")
    }

    func testOpeningEmojiPanelDoesNotCommitQueuedLetterIntoHiddenKeyboard() throws {
        try checkControllerOverlap(first: .emoji, expected: "")
    }

    private func checkControllerOverlap(first: KeyboardKey, expected: String) throws {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 440, height: 253)
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        controller.view.layoutIfNeeded()
        defer {
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
        }
        let children = Mirror(reflecting: controller).children
        let view = try XCTUnwrap(children.first { $0.label == "keyboardTouchSurface" }?.value as? KeyboardTouchSurfaceView)
        let composer = try XCTUnwrap(children.first { $0.label == "composer" || $0.label == "$__lazy_storage_$_composer" }?.value as? KeyboardComposer)
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 50)
        view.keyRows = [[
            .init(key: first, visualFrame: CGRect(x: 0, y: 0, width: 50, height: 50)),
            .init(key: .character("b"), visualFrame: CGRect(x: 50, y: 0, width: 50, height: 50))
        ]]
        let a = Finger(x: 25, time: 1), b = Finger(x: 75, time: 2)
        view.touchesBegan([a], with: nil)
        view.touchesBegan([b], with: nil)
        view.touchesEnded([b], with: nil)
        view.touchesEnded([a], with: nil)
        XCTAssertEqual(composer.romanBuffer, expected)
    }
}
