import Foundation
import XCTest
@testable import ObadhKeyboardCore

final class KeyboardInstallStateTests: XCTestCase {
    private var sharedSuite: String!
    private var sharedDefaults: UserDefaults!
    private var enabledKeyboards: [String] = []

    private let obadh = KeyboardInstallStateReader.keyboardBundleIdentifier

    override func setUp() {
        super.setUp()
        sharedSuite = "KeyboardInstallStateTests.shared.\(UUID().uuidString)"
        sharedDefaults = UserDefaults(suiteName: sharedSuite)
        sharedDefaults.removePersistentDomain(forName: sharedSuite)
        enabledKeyboards = []
    }

    override func tearDown() {
        sharedDefaults.removePersistentDomain(forName: sharedSuite)
        sharedDefaults = nil
        enabledKeyboards = []
        super.tearDown()
    }

    private func read() -> KeyboardInstallState {
        KeyboardInstallStateReader(
            enabledKeyboardIdentifiers: { [enabledKeyboards] in enabledKeyboards },
            sharedDefaults: sharedDefaults
        ).read()
    }

    private func setEnabledKeyboards(_ values: [String]) {
        enabledKeyboards = values
    }

    /// The shape iOS actually writes, captured from a live device's global domain.
    func testDetectsObadhAmongSystemKeyboards() {
        setEnabledKeyboards([
            "en_US@sw=QWERTY;hw=Automatic",
            obadh,
            "emoji@sw=Emoji",
            "bn-Translit@sw=QWERTY-Bengali;hw=Automatic"
        ])

        XCTAssertTrue(read().isKeyboardInstalled)
    }

    func testAbsentFromKeyboardListReadsAsNotInstalled() {
        setEnabledKeyboards(["en_US@sw=QWERTY;hw=Automatic", "emoji@sw=Emoji"])

        XCTAssertFalse(read().isKeyboardInstalled)
    }

    /// An empty/absent list must read as "not installed", not crash or report installed.
    func testMissingKeyboardListReadsAsNotInstalled() {
        XCTAssertFalse(read().isKeyboardInstalled)
    }

    /// Guards against a substring match reporting a different vendor's keyboard.
    func testDoesNotMatchAnUnrelatedKeyboardSharingOurPrefix() {
        setEnabledKeyboards(["\(obadh).evil", "com.example.obadh.keyboard"])

        XCTAssertFalse(read().isKeyboardInstalled)
    }

    /// iOS may append a suffix to the bare identifier; both shapes must match.
    func testMatchesSuffixedIdentifier() {
        setEnabledKeyboards(["\(obadh)@sw=QWERTY"])

        XCTAssertTrue(read().isKeyboardInstalled)
    }

    /// The stamp can only exist if the extension reached the shared container, which
    /// requires Full Access. Presence is proof.
    func testFullAccessConfirmedOnlyWhenTheExtensionStampedTheSharedContainer() {
        XCTAssertFalse(read().isFullAccessConfirmed)

        KeyboardPreferences(defaults: sharedDefaults).fullAccessConfirmedAt = Date()

        XCTAssertTrue(read().isFullAccessConfirmed)
    }

    /// Install state and Full Access are independent signals.
    func testFullAccessIsIndependentOfInstallation() {
        KeyboardPreferences(defaults: sharedDefaults).fullAccessConfirmedAt = Date()

        let state = read()
        XCTAssertFalse(state.isKeyboardInstalled)
        XCTAssertTrue(state.isFullAccessConfirmed)
    }
}
