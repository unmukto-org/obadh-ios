import XCTest
import UIKit

@MainActor
final class KeyboardLoanwordTests: XCTestCase {
    func testInspectBundledLoanwordCandidatesAndCurrentCommitPolicy() throws {
        let engine = ObadhBridgeClient.shared
        XCTAssertTrue(engine.configureModels(in: Bundle(for: Self.self)).autocorrectAvailable)
        var rows: [[String: Any]] = []
        for roman in ["computer", "office", "school", "phone", "mobile", "internet", "keyboard", "email", "bus", "bank", "coffee", "doctor", "manager", "taxi"] {
            let composer = KeyboardComposer(engine: engine)
            for key in roman { composer.append(String(key)) }
            let literal = composer.preview
            let frequency = engine.wordFrequency(literal)
            let candidates = engine.compositionSuggestions(for: roman, limit: composer.autocorrectFetchLimit)
            let detailed = engine.detailedCorrections(for: roman, limit: composer.autocorrectFetchLimit)
            XCTAssertTrue(detailed.contains { $0.source == DetailedCorrection.Source.englishLoanwordExact },
                          "The bundled dictionary should expose an exact loanword match for \(roman)")
            composer.mergeAutocorrectCandidates(candidates, generation: composer.generation)
            composer.resolveAutocorrectTarget(autoInsertEnabled: false, baselineFrequency: frequency,
                                              detailedCorrections: detailed, isProtectedWord: { _ in false })
            let defaultCommit = composer.commitText
            composer.resolveAutocorrectTarget(autoInsertEnabled: true, baselineFrequency: frequency,
                                              detailedCorrections: detailed, isProtectedWord: { _ in false })
            rows.append([
                "roman": roman, "literal": literal, "literalFrequency": frequency,
                "ribbon": composer.activeSuggestions.map(\.text),
                "spaceDefault": defaultCommit, "spaceAutoInsertOn": composer.commitText,
                "detailed": detailed.map { ["text": $0.text, "source": $0.source,
                    "editCost": $0.editCost, "repairCost": $0.romanRepairCost.map(Int.init) ?? -1,
                    "frequency": $0.frequency] as [String: Any] }
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "loanword-engine-and-ios-policy"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("LOANWORD-PROBE " + String(decoding: data, as: UTF8.self))
    }
    func testExactLoanwordDefaultsInEveryCaseAndWithEitherSetting() throws {
        let engine = ObadhBridgeClient.shared
        XCTAssertTrue(engine.configureModels(in: Bundle(for: Self.self)).autocorrectAvailable)
        let examples = ["computer": "কম্পিউটার", "office": "অফিস", "school": "স্কুল",
                        "phone": "ফোন", "mobile": "মোবাইল", "internet": "ইন্টারনেট",
                        "keyboard": "কিবোর্ড", "email": "ইমেইল", "bus": "বাস",
                        "bank": "ব্যাংক", "coffee": "কফি", "doctor": "ডাক্তার",
                        "manager": "ম্যানেজার", "taxi": "ট্যাক্সি"]
        for (roman, expected) in examples {
            let mixed = roman.enumerated().map { $0.offset.isMultiple(of: 2) ? String($0.element).uppercased() : String($0.element) }.joined()
            for input in [roman, roman.capitalized, roman.uppercased(), mixed] {
                for enabled in [false, true] {
                    let composer = KeyboardComposer(engine: engine)
                    composer.append(input)
                    let literal = composer.preview
                    let detailed = engine.detailedCorrections(for: composer.engineInput, limit: composer.autocorrectFetchLimit)
                    composer.mergeAutocorrectCandidates(detailed.map(\.text), generation: composer.generation)
                    composer.resolveAutocorrectTarget(autoInsertEnabled: enabled,
                        baselineFrequency: engine.wordFrequency(literal), detailedCorrections: detailed,
                        isProtectedWord: { _ in true })
                    XCTAssertEqual(composer.commitText, expected, input)
                    XCTAssertEqual(Array(composer.activeSuggestions.prefix(2)).map(\.text), [expected, literal], input)
                    XCTAssertEqual(composer.preview, literal, input)
                    XCTAssertEqual(composer.quotedLiteral(isOutOfVocabulary: false), literal, input)
                    XCTAssertEqual(composer.commitActiveInput(), expected, input)
                }
            }
        }
    }

    func testImmediateCommitBeforeAsyncResultsStillUsesExactLoanword() {
        let engine = ObadhBridgeClient.shared
        XCTAssertTrue(engine.configureModels(in: Bundle(for: Self.self)).autocorrectAvailable)
        var durations: [Double] = []
        for (input, expected) in [("computer", "কম্পিউটার"), ("OFFICE", "অফিস"), ("BuS", "বাস")] {
            let composer = KeyboardComposer(engine: engine)
            for key in input { composer.append(String(key)) }
            XCTAssertNil(composer.exactLoanwordTarget, "No async result has arrived")
            let start = CACurrentMediaTime()
            XCTAssertEqual(composer.commitActiveInput(), expected, input)
            durations.append((CACurrentMediaTime() - start) * 1_000)
            XCTAssertNil(composer.commitActiveInput(), "A word must only commit once")
        }
        print("LOANWORD-IMMEDIATE-COMMIT-MS \(durations)")
    }

    func testQuotedLiteralIsSecondSelectableRibbonEntry() throws {
        let engine = ObadhBridgeClient.shared
        XCTAssertTrue(engine.configureModels(in: Bundle(for: Self.self)).autocorrectAvailable)
        let composer = KeyboardComposer(engine: engine)
        composer.append("bus") // Its literal is itself a lexicon word.
        let detailed = engine.detailedCorrections(for: "bus", limit: 4)
        composer.mergeAutocorrectCandidates(detailed.map(\.text), generation: composer.generation)
        composer.resolveAutocorrectTarget(autoInsertEnabled: false, baselineFrequency: engine.wordFrequency(composer.preview),
            detailedCorrections: detailed, isProtectedWord: { _ in false })
        let bar = SuggestionBarView()
        let delegate = LoanwordSuggestionDelegate()
        bar.delegate = delegate
        bar.update(suggestions: composer.activeSuggestions, quotedText: composer.quotedLiteral(isOutOfVocabulary: false))
        func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let labels = descendants(bar).compactMap { ($0 as? UILabel)?.text }
        XCTAssertTrue(labels.contains("বাস"))
        XCTAssertTrue(labels.contains("“বুস”"))
        let literal = try XCTUnwrap(descendants(bar).first { $0.accessibilityLabel == "বুস" } as? UIControl)
        XCTAssertTrue(literal.isEnabled)
        XCTAssertEqual(composer.activeSuggestions[1].source, .deterministic)
        // This is a hostless test bundle (no UIApplication event dispatcher).
        // Invoke the control's registered action on its actual target.
        let action = try XCTUnwrap(literal.actions(forTarget: bar, forControlEvent: .touchUpInside)?.first)
        bar.perform(NSSelectorFromString(action), with: literal)
        XCTAssertEqual(delegate.selected, KeyboardSuggestion(text: "বুস", source: .deterministic))
    }

    func testControllerFetchesAndPresentsLoanwordWithAutoInsertOff() async throws {
        let engine = ObadhBridgeClient.shared
        XCTAssertTrue(engine.configureModels(in: Bundle(for: Self.self)).autocorrectAvailable)
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        func stored<T>(_ name: String, as type: T.Type) throws -> T {
            try XCTUnwrap(Mirror(reflecting: controller).children.first {
                $0.label == name || $0.label == "$__lazy_storage_$_" + name
            }?.value as? T)
        }
        let preferences = try stored("keyboardPreferences", as: KeyboardPreferences.self)
        let wasEnabled = preferences.autoInsertTopCorrection
        defer {
            preferences.autoInsertTopCorrection = wasEnabled
            controller.textWillChange(nil)
        }
        preferences.autoInsertTopCorrection = false
        controller.handleDebugCommand("tap", argument: "C,o,M,p,U,t,E,r")
        let composer = try stored("composer", as: KeyboardComposer.self)
        let deadline = CACurrentMediaTime() + 2
        while composer.exactLoanwordTarget == nil && CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(composer.commitText, "কম্পিউটার")
        let bar = try stored("suggestionBar", as: SuggestionBarView.self)
        let displayed = try XCTUnwrap(Mirror(reflecting: bar).children.first { $0.label == "suggestions" }?.value as? [KeyboardSuggestion])
        XCTAssertEqual(displayed.first?.text, "কম্পিউটার")
        XCTAssertEqual(displayed.dropFirst().first?.text, composer.preview)
        let quote = Mirror(reflecting: bar).children.first { $0.label == "quotedText" }?.value as? String
        XCTAssertEqual(quote, composer.preview)
    }

}

@MainActor
private final class LoanwordSuggestionDelegate: SuggestionBarViewDelegate {
    var selected: KeyboardSuggestion?
    func suggestionBar(_ suggestionBar: SuggestionBarView, didSelect suggestion: KeyboardSuggestion) { selected = suggestion }
    func suggestionBar(_ suggestionBar: SuggestionBarView, didSelectEmoji emoji: String) {}
    func suggestionBar(_ suggestionBar: SuggestionBarView, didPickEmojiVariant emoji: String, base: String) {}
    func suggestionBar(_ suggestionBar: SuggestionBarView, variantOptionsFor base: String) -> [EmojiItem] { [] }
    func suggestionBarDidTapMic(_ suggestionBar: SuggestionBarView) {}
}
