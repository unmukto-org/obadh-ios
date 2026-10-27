import XCTest
import UIKit

/// The production controller, production engine, and public proxy contract.
/// Host actions are recorded separately from text insertion, as in UITextField.
@MainActor
final class KeyboardFieldContextTests: XCTestCase {
    private func make(_ proxy: FieldDocumentProxy = .init()) -> FieldKeyboardController {
        let controller = FieldKeyboardController(proxy: proxy)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 414, height: 253)
        controller.view.layoutIfNeeded()
        addTeardownBlock { @MainActor in controller.textWillChange(nil) }
        return controller
    }

    private func stored<T>(_ name: String, _ controller: KeyboardViewController, as: T.Type = T.self) throws -> T {
        var mirror: Mirror? = Mirror(reflecting: controller)
        while let current = mirror {
            if let value = current.children.first(where: { $0.label == name || $0.label == "$__lazy_storage_$_" + name })?.value as? T {
                return value
            }
            mirror = current.superclassMirror
        }
        throw NSError(domain: "Missing test state: \(name)", code: 1)
    }

    private func type(_ text: String, _ controller: KeyboardViewController) {
        controller.handleDebugCommand("tap", argument: text.map(String.init).joined(separator: ","))
    }

    private func typeEmoticon(_ text: String, _ controller: KeyboardViewController) {
        for key in text {
            if key.isLetter { type(String(key), controller) }
            else { controller.handleDebugCommand("sym", argument: String(key)) }
        }
    }

    private func backspace(_ controller: KeyboardViewController) {
        let surface = KeyboardTouchSurfaceView()
        controller.keyboardTouchSurface(surface, didBegin: .backspace)
        controller.keyboardTouchSurfaceDidCancel(surface)
    }

    func testEveryCanonicalFaceReplacesAtSpaceInBanglaAndLatinProse() {
        let proxy = FieldDocumentProxy()
        let controller = make(proxy)
        for kind: UIKeyboardType in [.default, .asciiCapable] {
            proxy.keyboardType = kind
            for (alias, emoji) in EmoticonRules.aliases.sorted(by: { $0.key < $1.key }) {
                controller.textWillChange(nil)
                proxy.text = ""
                proxy.cursor = 0
                proxy.documentIdentifier = UUID()
                controller.textDidChange(nil)
                typeEmoticon(alias, controller)
                XCTAssertEqual(proxy.text, alias, "Keep the typed alias until a boundary: \(alias)")
                controller.handleDebugCommand("tap", argument: "space")
                XCTAssertEqual(proxy.text, emoji + " ", "\(kind): \(alias)")
            }
        }
    }

    func testFaceWaitsForLongestAliasAndBackspaceRestoresLiteralWithoutRepeating() {
        let proxy = FieldDocumentProxy()
        let controller = make(proxy)
        typeEmoticon(":-", controller)
        XCTAssertEqual(proxy.text, ":-")
        typeEmoticon(")", controller)
        XCTAssertEqual(proxy.text, ":-)")
        controller.handleDebugCommand("tap", argument: "space")
        XCTAssertEqual(proxy.text, "😃 ")
        backspace(controller)
        XCTAssertEqual(proxy.text, ":-)")
        controller.handleDebugCommand("tap", argument: "space")
        XCTAssertEqual(proxy.text, ":-) ")
    }

    func testBothSmileSpellingsShowEmojiAndQuotedLiteralBeforeAnyBoundary() throws {
        for kind: UIKeyboardType in [.default, .asciiCapable] {
            for alias in [":)", ":-)"] {
                let proxy = FieldDocumentProxy()
                proxy.keyboardType = kind
                let controller = make(proxy)
                typeEmoticon(alias, controller)
                XCTAssertEqual(proxy.text, alias)
                let bar: SuggestionBarView = try stored("suggestionBar", controller)
                let suggestions: [KeyboardSuggestion] = try stored("suggestions", barController: bar)
                XCTAssertEqual(suggestions.map(\.text), ["😃", alias])
                let quote: String = try stored("quotedText", barController: bar)
                XCTAssertEqual(quote, alias)
                func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
                let controls = descendants(bar).compactMap { $0 as? UIControl }
                XCTAssertTrue(controls.contains { $0.accessibilityLabel == "😃" })
                XCTAssertTrue(controls.contains { $0.accessibilityLabel == alias })
            }
        }
    }

    private func stored<T>(_ name: String, barController bar: SuggestionBarView) throws -> T {
        try XCTUnwrap(Mirror(reflecting: bar).children.first { $0.label == name }?.value as? T)
    }

    func testFaceReplacesBeforeReturnAndSentencePunctuation() {
        let proxy = FieldDocumentProxy()
        let controller = make(proxy)
        typeEmoticon(":D", controller)
        controller.handleDebugCommand("tap", argument: "return")
        XCTAssertEqual(proxy.text, "😄\n")
        typeEmoticon(":)", controller)
        controller.handleDebugCommand("sym", argument: "!")
        XCTAssertEqual(proxy.text, "😄\n😃!")
        backspace(controller)
        XCTAssertEqual(proxy.text, "😄\n:)")
        controller.handleDebugCommand("tap", argument: "space")
        typeEmoticon(":-)", controller)
        controller.handleDebugCommand("sym", argument: ".")
        XCTAssertEqual(proxy.text, "😄\n:) 😃.")
        backspace(controller)
        XCTAssertEqual(proxy.text, "😄\n:) :-)")
    }

    func testFaceDoesNotReplaceInAddressCodeOrUncorrectedFields() {
        for kind: UIKeyboardType in [.emailAddress, .URL, .asciiCapable] {
            let proxy = FieldDocumentProxy()
            proxy.keyboardType = kind
            if kind == .asciiCapable { proxy.textContentType = .oneTimeCode }
            let controller = make(proxy)
            typeEmoticon(":)", controller)
            controller.handleDebugCommand("tap", argument: "space")
            XCTAssertEqual(proxy.text, ":) ")
        }
        let proxy = FieldDocumentProxy()
        proxy.autocorrectionType = .no
        let controller = make(proxy)
        typeEmoticon(":)", controller)
        controller.handleDebugCommand("tap", argument: "space")
        XCTAssertEqual(proxy.text, ":) ")
    }

    func testFaceNeverMatchesInsideAWordURLOrUnfinishedAlias() {
        let proxy = FieldDocumentProxy()
        proxy.keyboardType = .asciiCapable
        let controller = make(proxy)
        for input in ["hi:)", "http://a", "://", ":Dabc", ":):)"] {
            controller.textWillChange(nil)
            proxy.text = ""
            proxy.cursor = 0
            controller.textDidChange(nil)
            typeEmoticon(input, controller)
            controller.handleDebugCommand("tap", argument: "space")
            XCTAssertEqual(proxy.text, input + " ", input)
        }
    }

    func testFaceDoesNotDisturbBisargaNumeralsOrSmartOpeningQuote() {
        let proxy = FieldDocumentProxy()
        let controller = make(proxy)
        type("du", controller)
        controller.handleDebugCommand("sym", argument: ":")
        type("kho", controller)
        controller.handleDebugCommand("tap", argument: "space")
        XCTAssertEqual(proxy.text, "দুঃখ ")
        for symbol in ["০", ":", "৪", "৫"] { controller.handleDebugCommand("sym", argument: symbol) }
        XCTAssertEqual(proxy.text, "দুঃখ ০:৪৫")
        controller.handleDebugCommand("tap", argument: "space")
        typeEmoticon("<৩", controller)
        controller.handleDebugCommand("tap", argument: "space")
        XCTAssertEqual(proxy.text, "দুঃখ ০:৪৫ ❤️ ")
        controller.handleDebugCommand("sym", argument: "'")
        XCTAssertEqual(proxy.text, "দুঃখ ০:৪৫ ❤️ ‘")
        type("ami", controller)
        controller.handleDebugCommand("tap", argument: "space")
        XCTAssertEqual(proxy.text, "দুঃখ ০:৪৫ ❤️ ‘আমি ")
    }

    func testPendingFaceAndUndoAreDiscardedAcrossFieldChangesAndHostEdits() {
        let proxy = FieldDocumentProxy()
        let controller = make(proxy)
        typeEmoticon(":)", controller)
        let email = FieldDocumentProxy()
        email.keyboardType = .emailAddress
        controller.proxy = email
        controller.textDidChange(nil)
        controller.handleDebugCommand("tap", argument: "space")
        XCTAssertEqual(proxy.text, ":)")
        XCTAssertEqual(email.text, " ")
        controller.proxy = proxy
        controller.textDidChange(nil)
        controller.handleDebugCommand("tap", argument: "space")
        typeEmoticon(":)", controller)
        controller.handleDebugCommand("tap", argument: "space")
        XCTAssertEqual(proxy.text, ":) 😃 ")
        proxy.text = "host changed this"
        proxy.cursor = proxy.text.unicodeScalars.count
        backspace(controller)
        XCTAssertEqual(proxy.text, "host changed thi", "Never restore a face into unrelated host text")
    }

    func testQuotedFaceCanBeKeptAndRemovedBeforeCommit() throws {
        let proxy = FieldDocumentProxy()
        let controller = make(proxy)
        typeEmoticon(":)", controller)
        let composer: KeyboardComposer = try stored("composer", controller)
        let bar: SuggestionBarView = try stored("suggestionBar", controller)
        controller.suggestionBar(bar, didSelect: try XCTUnwrap(composer.activeSuggestions.last))
        XCTAssertEqual(proxy.text, ":) ")
        typeEmoticon(":D", controller)
        backspace(controller)
        XCTAssertEqual(proxy.text, ":) :")
        controller.handleDebugCommand("tap", argument: "space")
        XCTAssertEqual(proxy.text, ":) : ")
    }

    func testEmailIsLiteralAcrossLettersDigitsAndPunctuation() throws {
        let proxy = FieldDocumentProxy()
        proxy.keyboardType = .emailAddress
        let controller = make(proxy)
        type("name", controller)
        controller.handleDebugCommand("sym", argument: "@")
        type("example", controller)
        controller.handleDebugCommand("sym", argument: ".")
        type("com", controller)
        XCTAssertEqual(proxy.text, "name@example.com")
        XCTAssertTrue(proxy.operations.allSatisfy { if case .insert = $0 { true } else { false } })
        let composer: KeyboardComposer = try stored("composer", controller)
        XCTAssertFalse(composer.hasActiveInput)
        let buttons: [KeyboardKeyButton] = try stored("keyButtons", controller)
        XCTAssertTrue(buttons.contains { $0.key == .symbol(.literal("@")) })
        XCTAssertTrue(buttons.contains { $0.key == .symbol(.literal(".")) })
        XCTAssertFalse(buttons.contains { $0.key == .emoji })
    }

    func testURLKeepsSyntaxAndDigitPageLiteral() throws {
        let proxy = FieldDocumentProxy()
        proxy.keyboardType = .URL
        let controller = make(proxy)
        type("https", controller)
        for symbol in [":", "/", "/"] { controller.handleDebugCommand("sym", argument: symbol) }
        type("example", controller)
        controller.handleDebugCommand("sym", argument: ".com")
        controller.handleDebugCommand("sym", argument: "/")
        type("a", controller)
        for symbol in ["-", "-", ".", ".", ".", "'"] { controller.handleDebugCommand("sym", argument: symbol) }
        XCTAssertEqual(proxy.text, "https://example.com/a--...'")
        controller.handleDebugCommand("mode", argument: "numbers")
        let buttons: [KeyboardKeyButton] = try stored("keyButtons", controller)
        let one = try XCTUnwrap(buttons.first { $0.key == .symbol(.literal("1")) })
        XCTAssertTrue(one.accessibilityActivate())
        XCTAssertTrue(proxy.text.hasSuffix("1"))
    }

    func testReturnCommitsBanglaThenSendsAStandaloneHostAction() throws {
        let proxy = FieldDocumentProxy()
        proxy.returnKeyType = .send
        let controller = make(proxy)
        type("bus", controller)
        let buttons: [KeyboardKeyButton] = try stored("keyButtons", controller)
        let key = try XCTUnwrap(buttons.first { $0.key == .returnKey })
        XCTAssertEqual(key.accessibilityLabel, "Send")
        XCTAssertTrue(key.accessibilityActivate())
        XCTAssertEqual(proxy.submitted, ["বাস"])
        XCTAssertEqual(proxy.operations.last, .returnAction)
        XCTAssertFalse(proxy.text.contains("\n"))
    }

    func testReturnDisabledUntilAnyTextExistsIncludingTextAfterCursor() throws {
        let proxy = FieldDocumentProxy()
        proxy.keyboardType = .asciiCapable
        proxy.returnKeyType = .search
        proxy.enablesReturnKeyAutomatically = true
        let controller = make(proxy)
        var buttons: [KeyboardKeyButton] = try stored("keyButtons", controller)
        var key = try XCTUnwrap(buttons.first { $0.key == .returnKey })
        XCTAssertFalse(key.isEnabled)
        controller.handleDebugCommand("tap", argument: "return")
        XCTAssertTrue(proxy.operations.isEmpty)
        proxy.text = "some text"
        proxy.cursor = 0
        controller.selectionDidChange(nil)
        buttons = try stored("keyButtons", controller)
        key = try XCTUnwrap(buttons.first { $0.key == .returnKey })
        XCTAssertTrue(key.isEnabled)
        XCTAssertTrue(key.accessibilityActivate())
        XCTAssertEqual(proxy.submitted, ["some text"])
    }

    func testFocusChangeKeepsPreviousWordAndCannotRewriteTheNewField() throws {
        let old = FieldDocumentProxy()
        let controller = make(old)
        type("ban", controller)
        let original = old.text
        XCTAssertFalse(original.isEmpty)
        let foreign = FieldDocumentProxy()
        foreign.keyboardType = .emailAddress
        foreign.text = "kept@"
        foreign.cursor = foreign.text.unicodeScalars.count
        controller.proxy = foreign
        controller.textDidChange(nil) // Only the after callback, as some hosts deliver.
        XCTAssertEqual(old.text, original)
        XCTAssertEqual(foreign.text, "kept@")
        XCTAssertTrue(foreign.operations.isEmpty)
        type("example", controller)
        XCTAssertEqual(foreign.text, "kept@example")
        XCTAssertEqual(old.text, original)
        let composer: KeyboardComposer = try stored("composer", controller)
        XCTAssertFalse(composer.hasActiveInput)
    }

    func testSilentFocusChangeDiscardsOldContactAndResetsSameTypeComposition() throws {
        let old = FieldDocumentProxy()
        let controller = make(old)
        type("ban", controller)
        let foreign = FieldDocumentProxy()
        foreign.text = "অন্য "
        foreign.cursor = foreign.text.unicodeScalars.count
        controller.proxy = foreign // No callback from this host.
        controller.handleDebugCommand("tap", argument: "a")
        XCTAssertEqual(foreign.text, "অন্য ", "The queued old contact is cancelled")
        controller.handleDebugCommand("tap", argument: "a")
        XCTAssertEqual(foreign.text, "অন্য আ")
    }

    func testFreshFingerAfterSilentFocusChangeKeepsItsFirstLetter() throws {
        let old = FieldDocumentProxy()
        let controller = make(old)
        type("ban", controller)
        let previous = old.text
        let foreign = FieldDocumentProxy()
        foreign.text = "অন্য "
        foreign.cursor = foreign.text.unicodeScalars.count
        controller.proxy = foreign
        let surface: KeyboardTouchSurfaceView = try stored("keyboardTouchSurface", controller)
        surface.prepareForNewContacts?() // Same hook as touchesBegan, before resolution.
        controller.keyboardTouchSurface(surface, didBegin: .character("a"))
        controller.keyboardTouchSurface(surface, didEnd: .character("a"), flickedDown: false)
        XCTAssertEqual(foreign.text, "অন্য আ")
        XCTAssertEqual(old.text, previous)
    }

    func testFieldChangeCancelsOutstandingSuggestions() async throws {
        let controller = make()
        type("computer", controller)
        let generation: Int = try stored("suggestionGeneration", controller)
        let foreign = FieldDocumentProxy()
        foreign.keyboardType = .numberPad
        controller.proxy = foreign
        controller.textDidChange(nil)
        let nextGeneration: Int = try stored("suggestionGeneration", controller)
        XCTAssertGreaterThan(nextGeneration, generation)
        try await Task.sleep(for: .milliseconds(100))
        let bar: SuggestionBarView = try stored("suggestionBar", controller)
        let suggestions = Mirror(reflecting: bar).children.first { $0.label == "suggestions" }?.value as? [KeyboardSuggestion]
        XCTAssertEqual(suggestions, [])
        XCTAssertTrue(foreign.operations.isEmpty)
    }

    func testVoiceEditRechecksRealControllerDestinationBeforeWriting() {
        let old = FieldDocumentProxy()
        let controller = make(old)
        let foreign = FieldDocumentProxy()
        foreign.text = "untouched"
        foreign.cursor = foreign.text.unicodeScalars.count
        controller.proxy = foreign
        XCTAssertFalse(controller.voicePerformTextUpdate(in: old.documentIdentifier) {
            XCTFail("A stale voice destination must not be edited")
        })
        XCTAssertEqual(foreign.text, "untouched")
        XCTAssertTrue(foreign.operations.isEmpty)
        XCTAssertTrue(controller.voicePerformTextUpdate(in: foreign.documentIdentifier) {
            foreign.insertText(" বাংলা")
        })
        XCTAssertEqual(foreign.text, "untouched বাংলা")
        foreign.textContentType = .oneTimeCode // Same document, changed permission.
        XCTAssertFalse(controller.voicePerformTextUpdate(in: foreign.documentIdentifier) {
            XCTFail("Credential hints must be reread at the edit boundary")
        })
        XCTAssertEqual(foreign.text, "untouched বাংলা")
    }

    func testFieldChangeStopsHeldDeleteBeforeItCanReachAnotherField() throws {
        let controller = make()
        type("bangla", controller)
        let surface: KeyboardTouchSurfaceView = try stored("keyboardTouchSurface", controller)
        controller.keyboardTouchSurface(surface, didBegin: .backspace)
        let repeater: BackspaceRepeatController = try stored("backspaceRepeater", controller)
        XCTAssertTrue(repeater.isActive)
        let foreign = FieldDocumentProxy()
        foreign.text = "untouched"
        foreign.cursor = foreign.text.unicodeScalars.count
        controller.proxy = foreign
        controller.textDidChange(nil)
        XCTAssertFalse(repeater.isActive)
        XCTAssertEqual(foreign.text, "untouched")
        XCTAssertTrue(foreign.operations.isEmpty)
    }

    func testSuggestionSpacingOptOutCommitsOnlyTheExplicitlyChosenWord() {
        let proxy = FieldDocumentProxy()
        proxy.smartInsertDeleteType = .no
        let controller = make(proxy)
        type("ban", controller)
        controller.suggestionBar(SuggestionBarView(), didSelect: .init(text: "বাংলা", source: .autocorrect))
        XCTAssertEqual(proxy.text, "বাংলা")
    }

    func testHostCorrectionOptOutPreventsEvenRapidExactLoanwordCommit() {
        let proxy = FieldDocumentProxy()
        proxy.autocorrectionType = .no
        let controller = make(proxy)
        type("bus", controller)
        let literal = proxy.text
        controller.handleDebugCommand("tap", argument: "space")
        XCTAssertEqual(proxy.text, literal + " ")
        XCTAssertNotEqual(literal, "বাস")
    }

    func testHostSmartPunctuationOptOutPreservesStraightQuotesAndDashes() {
        let proxy = FieldDocumentProxy()
        proxy.smartQuotesType = .no
        proxy.smartDashesType = .no
        let controller = make(proxy)
        for symbol in ["'", "-", "-", "\""] { controller.handleDebugCommand("sym", argument: symbol) }
        XCTAssertEqual(proxy.text, "'--\"")
    }

    func testNumericPadCannotInsertLettersSpaceOrEmojiAndCanDelete() throws {
        for kind in [UIKeyboardType.numberPad, .asciiCapableNumberPad, .decimalPad] {
            let proxy = FieldDocumentProxy()
            proxy.keyboardType = kind
            let controller = make(proxy)
            type("abc", controller)
            controller.handleDebugCommand("tap", argument: "space")
            XCTAssertTrue(proxy.text.isEmpty)
            let buttons: [KeyboardKeyButton] = try stored("keyButtons", controller)
            for digit in ["1", "2", "0"] {
                let key = try XCTUnwrap(buttons.first { $0.key == .symbol(.literal(digit)) })
                XCTAssertTrue(key.accessibilityActivate())
            }
            XCTAssertEqual(proxy.text, "120")
            let key = try XCTUnwrap(buttons.first { $0.key == .backspace })
            XCTAssertTrue(key.accessibilityActivate())
            XCTAssertEqual(proxy.text, "12")
        }
    }

    func testExplicitAppearanceAndSemanticHintsFromDefaultFields() throws {
        let proxy = FieldDocumentProxy()
        proxy.textContentType = .emailAddress
        proxy.keyboardAppearance = .dark
        let controller = make(proxy)
        XCTAssertEqual(controller.overrideUserInterfaceStyle, .dark)
        type("email", controller)
        XCTAssertEqual(proxy.text, "email")
        proxy.textContentType = .oneTimeCode
        controller.textDidChange(nil)
        let policy: KeyboardFieldPolicy = try stored("fieldPolicy", controller)
        XCTAssertFalse(policy.allowsLearning)
        XCTAssertFalse(policy.allowsSuggestions)
        XCTAssertFalse(policy.allowsVoice)
    }

    func testBanglaIgnoresHostCapitalizationButLatinRespectsItAndManualShift() throws {
        let bangla = FieldDocumentProxy()
        bangla.autocapitalizationType = .allCharacters
        let controller = make(bangla)
        type("a", controller)
        let composer: KeyboardComposer = try stored("composer", controller)
        XCTAssertEqual(composer.romanBuffer, "a")
        let latin = FieldDocumentProxy()
        latin.keyboardType = .asciiCapable
        latin.autocapitalizationType = .sentences
        controller.proxy = latin
        controller.textDidChange(nil)
        type("hello", controller)
        XCTAssertEqual(latin.text, "Hello")
        controller.handleDebugCommand("sym", argument: ".")
        controller.handleDebugCommand("tap", argument: "space")
        let buttons: [KeyboardKeyButton] = try stored("keyButtons", controller)
        let shift = try XCTUnwrap(buttons.first { $0.key == .shift })
        XCTAssertTrue(shift.accessibilityActivate()) // Explicitly decline automatic uppercase.
        type("a", controller)
        XCTAssertEqual(latin.text, "Hello. a")
    }

    func testEmptyLatinEditorCapitalizesWithNilContextButDoesNotGuessWithheldText() throws {
        let proxy = FieldDocumentProxy()
        proxy.keyboardType = .asciiCapable
        proxy.autocapitalizationType = .sentences
        proxy.exposesContext = false
        let controller = make(proxy)
        type("h", controller)
        XCTAssertEqual(proxy.text, "H")
        proxy.text = "already"
        proxy.cursor = proxy.text.unicodeScalars.count
        controller.textDidChange(nil)
        type("a", controller)
        XCTAssertEqual(proxy.text, "alreadya")
    }

    func testEmojiSearchUsesItsOwnLayoutAndReturnsToFieldLayout() throws {
        let proxy = FieldDocumentProxy()
        proxy.keyboardType = .twitter
        let controller = make(proxy)
        var buttons: [KeyboardKeyButton] = try stored("keyButtons", controller)
        XCTAssertTrue(try XCTUnwrap(buttons.first { $0.key == .emoji }).accessibilityActivate())
        let panel = EmojiPanelView()
        controller.emojiPanelViewDidRequestSearch(panel)
        XCTAssertFalse(controller.keyboardTouchSurfaceShouldBeginCursorDrag(KeyboardTouchSurfaceView()))
        buttons = try stored("keyButtons", controller)
        XCTAssertFalse(buttons.contains { $0.key == .symbol(.literal("@")) })
        controller.handleDebugCommand("tap", argument: "return")
        controller.emojiPanelViewDidRequestKeyboard(panel)
        buttons = try stored("keyButtons", controller)
        XCTAssertTrue(buttons.contains { $0.key == .symbol(.literal("@")) })
        XCTAssertTrue(proxy.text.isEmpty)
    }

    func testSpacebarCursorDragMovesCaretWithoutTypingSpace() {
        let proxy = FieldDocumentProxy()
        proxy.keyboardType = .asciiCapable
        proxy.text = "abcd"
        proxy.cursor = 4
        let controller = make(proxy)
        let surface = KeyboardTouchSurfaceView()

        controller.keyboardTouchSurface(surface, didEnd: .shift, flickedDown: false)
        controller.keyboardTouchSurface(surface, didBegin: .space)
        controller.keyboardTouchSurfaceDidBeginCursorDrag(surface)
        controller.keyboardTouchSurface(surface, didDragCursorBy: CGPoint(x: -25, y: 0))
        controller.keyboardTouchSurfaceDidEndCursorDrag(surface)

        XCTAssertEqual(proxy.cursor, 2)
        XCTAssertEqual(proxy.text, "abcd")
        type("x", controller)
        XCTAssertEqual(proxy.text, "abxcd")
    }

    func testCursorDragCrossesWholeBanglaConjunctAndEmoji() {
        for cluster in ["ক্ষ", "👩🏽‍💻"] {
            let proxy = FieldDocumentProxy()
            proxy.keyboardType = .asciiCapable
            proxy.text = cluster + "x"
            proxy.cursor = proxy.text.unicodeScalars.count
            let controller = make(proxy)
            let surface = KeyboardTouchSurfaceView()

            controller.keyboardTouchSurface(surface, didBegin: .space)
            controller.keyboardTouchSurfaceDidBeginCursorDrag(surface)
            controller.keyboardTouchSurface(surface, didDragCursorBy: CGPoint(x: -10, y: 0))
            controller.keyboardTouchSurface(surface, didDragCursorBy: CGPoint(x: -10, y: 0))
            controller.keyboardTouchSurfaceDidEndCursorDrag(surface)

            XCTAssertEqual(proxy.adjustedOffsets, [-1, -cluster.utf16.count])
            XCTAssertEqual(proxy.cursor, 0)
            type("q", controller)
            XCTAssertEqual(proxy.text, "q" + cluster + "x")
        }
    }

    func testDelayedHostCallbacksDoNotCancelActiveCursorDrag() {
        let proxy = FieldDocumentProxy()
        proxy.keyboardType = .asciiCapable
        proxy.text = "abcd"
        proxy.cursor = 4
        let controller = make(proxy)
        let surface = KeyboardTouchSurfaceView()
        controller.keyboardTouchSurface(surface, didBegin: .space)
        controller.keyboardTouchSurfaceDidBeginCursorDrag(surface)
        controller.keyboardTouchSurface(surface, didDragCursorBy: CGPoint(x: -10, y: 0))
        controller.selectionWillChange(nil)
        controller.selectionDidChange(nil)
        controller.textWillChange(nil)
        controller.textDidChange(nil)
        controller.keyboardTouchSurface(surface, didDragCursorBy: CGPoint(x: -10, y: 0))
        controller.keyboardTouchSurfaceDidEndCursorDrag(surface)
        XCTAssertEqual(proxy.cursor, 2)
        XCTAssertEqual(proxy.adjustedOffsets, [-1, -1])
    }
}

@MainActor
private final class FieldKeyboardController: KeyboardViewController {
    var proxy: FieldDocumentProxy
    init(proxy: FieldDocumentProxy) { self.proxy = proxy; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Unused") }
    override var textDocumentProxy: any UITextDocumentProxy { proxy }
}

@MainActor
private final class FieldDocumentProxy: NSObject, UITextDocumentProxy {
    enum Operation: Equatable { case insert(String), delete, returnAction }
    var text = ""
    var cursor = 0
    var operations: [Operation] = []
    var submitted: [String] = []
    var adjustedOffsets: [Int] = []
    var documentIdentifier = UUID()
    var exposesContext = true
    var documentContextBeforeInput: String? { exposesContext ? String(text.unicodeScalars.prefix(cursor)) : nil }
    var documentContextAfterInput: String? { exposesContext ? String(text.unicodeScalars.dropFirst(cursor)) : nil }
    var selectedText: String? { nil }
    var documentInputMode: UITextInputMode? { nil }
    var hasText: Bool { !text.isEmpty }
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType! = nil
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .default
    var spellCheckingType: UITextSpellCheckingType = .default
    var smartQuotesType: UITextSmartQuotesType = .default
    var smartDashesType: UITextSmartDashesType = .default
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .default
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically = false
    var keyboardAppearance: UIKeyboardAppearance = .default
    var isSecureTextEntry = false
    func insertText(_ value: String) {
        if value == "\n" && returnKeyType != .default {
            submitted.append(text)
            operations.append(.returnAction)
            return
        }
        let before = String(text.unicodeScalars.prefix(cursor))
        let after = String(text.unicodeScalars.dropFirst(cursor))
        text = before + value + after
        cursor = before.unicodeScalars.count + value.unicodeScalars.count
        operations.append(.insert(value))
    }
    func deleteBackward() {
        guard cursor > 0 else { return }
        var before = String(text.unicodeScalars.prefix(cursor))
        let after = String(text.unicodeScalars.dropFirst(cursor))
        before.removeLast()
        text = before + after
        cursor = before.unicodeScalars.count
        operations.append(.delete)
    }
    func adjustTextPosition(byCharacterOffset offset: Int) {
        adjustedOffsets.append(offset)
        let current = String(text.unicodeScalars.prefix(cursor)).utf16.count
        let destination = min(text.utf16.count, max(0, current + offset))
        var utf16Position = 0
        cursor = 0
        for scalar in text.unicodeScalars {
            let next = utf16Position + String(scalar).utf16.count
            guard next <= destination else { break }
            utf16Position = next
            cursor += 1
        }
    }
    func setMarkedText(_ markedText: String, selectedRange: NSRange) { XCTFail("Fields must remain plain text") }
    func unmarkText() { XCTFail("Fields must remain plain text") }
}
