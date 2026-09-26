import XCTest

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
}
