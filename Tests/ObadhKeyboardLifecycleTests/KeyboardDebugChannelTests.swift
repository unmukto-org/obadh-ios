import XCTest

@MainActor
final class KeyboardDebugChannelTests: XCTestCase {
    private final class Handler: KeyboardDebugCommandHandler {
        var canHandleDebugCommands = false
        var onCommand: (() -> Void)?
        func handleDebugCommand(_ command: String, argument: String?) { onCommand?() }
    }

    func testDetachedControllerDoesNotConsumeAnotherControllersCommand() async throws {
        let handler = Handler()
        let channel = KeyboardDebugChannel(handler: handler)
        let url = try XCTUnwrap(Mirror(reflecting: channel).children
            .first { $0.label == "commandURL" }?.value as? URL)
        channel.start()
        defer { channel.stop(); try? FileManager.default.removeItem(at: url) }
        let inactive = expectation(description: "Detached controller consumes no command")
        inactive.isInverted = true
        handler.onCommand = { inactive.fulfill() }
        try "probe:on".write(to: url, atomically: true, encoding: .utf8)
        await fulfillment(of: [inactive], timeout: 0.6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let active = expectation(description: "Visible controller receives the pending command")
        handler.onCommand = { active.fulfill() }
        handler.canHandleDebugCommands = true
        await fulfillment(of: [active], timeout: 1)
    }
}
