import Foundation
import XCTest

/// Diagnostic snapshot of the shipped engine/model artifact. This does not
/// implement or establish an improvement in spatial suggestion ranking.
@MainActor
final class KeyboardSpatialSuggestionTests: XCTestCase {
    func testInspectPilotWordsAgainstShippedEngine() throws {
        let engine = ObadhBridgeClient.shared
        let configuration = engine.configureModels(in: Bundle(for: Self.self))
        XCTAssertTrue(configuration.autocorrectAvailable)
        struct Probe: Codable {
            let roman: String
            let baseline: String
            let frequency: UInt64
            let suggestions: [String]
        }
        let words = ["bikale", "bikele", "bimale", "bijele", "nodir", "nidir", "hobe", "hobr", "acho", "achi",
                     "ami", "banglay", "likhi", "tumi", "kemon", "aj", "pare", "dekha"]
        let probes = words.map { word in
            let baseline = engine.transliterate(word)
            return Probe(roman: word, baseline: baseline, frequency: engine.wordFrequency(baseline),
                         suggestions: engine.compositionSuggestions(for: word, limit: 4))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Keep the report in the test result; a device runner cannot write into
        // the source checkout, and a fresh checkout has no pilot output folder.
        let attachment = XCTAttachment(data: try encoder.encode(probes), uniformTypeIdentifier: "public.json")
        attachment.name = "engine-probe.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
