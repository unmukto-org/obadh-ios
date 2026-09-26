import XCTest
import UIKit

@MainActor
final class KeyboardKeyAppearanceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KeyboardGlassStyle.current = .translucent
        KeyboardTheme.legacyPresentation = false
    }

    func testDetachedKeysUseSuppliedAppearanceForFillAndText() throws {
        for style in [UIUserInterfaceStyle.dark, .light] {
            for key in [KeyboardKey.character("a"), .space, .backspace] {
                let button = KeyboardKeyButton(key: key)
                // Row construction styles keys before adding them to the dark
                // keyboard. Their own traits can still be light at this point.
                button.traitOverrides.userInterfaceStyle = style == .dark ? .light : .dark
                let traits = UITraitCollection(userInterfaceStyle: style)
                button.updateAppearance(shifted: false, traitCollection: traits,
                                        metrics: KeyboardTheme.defaultMetrics)
                XCTAssertEqual(try XCTUnwrap(button.backgroundColor).cgColor.alpha,
                               KeyboardTheme.glassKeyTint(for: traits, highlighted: false).cgColor.alpha,
                               accuracy: 0.001, "Fill must use the same supplied appearance as text")
                XCTAssertEqual(button.titleColor(for: .normal), KeyboardTheme.textColor(for: traits))
            }
        }
    }

    func testFillTracksInheritedStyleWithoutWaitingForControllerRefresh() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let parent = host.view!
        parent.traitOverrides.userInterfaceStyle = .light
        let button = KeyboardKeyButton(key: .character("a"))
        parent.addSubview(button)
        parent.layoutIfNeeded()
        button.updateAppearance(shifted: false, traitCollection: parent.traitCollection,
                                metrics: KeyboardTheme.defaultMetrics)
        parent.traitOverrides.userInterfaceStyle = .dark
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        XCTAssertEqual(button.traitCollection.userInterfaceStyle, .dark)
        XCTAssertEqual(try XCTUnwrap(button.backgroundColor).cgColor.alpha, 0.16, accuracy: 0.001)
        button.isHighlighted = true
        XCTAssertEqual(try XCTUnwrap(button.backgroundColor).cgColor.alpha, 0.37, accuracy: 0.001)
        button.isHighlighted = false
        parent.traitOverrides.userInterfaceStyle = .light
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        XCTAssertEqual(try XCTUnwrap(button.backgroundColor).cgColor.alpha, 0.87, accuracy: 0.001)
    }

    func testDarkKeyboardRowRebuildUsesDarkFillImmediately() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        window.overrideUserInterfaceStyle = .dark
        let controller = KeyboardViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
            window.isHidden = true
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        XCTAssertEqual(controller.traitCollection.userInterfaceStyle, .dark)
        for mode in ["numbers", "letters"] {
            controller.handleDebugCommand("mode", argument: mode)
            let buttons = try XCTUnwrap(Mirror(reflecting: controller).children
                .first { $0.label == "keyButtons" }?.value as? [KeyboardKeyButton])
            XCTAssertFalse(buttons.isEmpty)
            for button in buttons {
                XCTAssertEqual(try XCTUnwrap(button.backgroundColor).cgColor.alpha, 0.16,
                               accuracy: 0.001, "New \(mode) key \(button.key) must already have the correct fill")
            }
        }
    }
}
