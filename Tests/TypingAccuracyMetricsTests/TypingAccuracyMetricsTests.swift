import Foundation
import XCTest
@testable import TypingAccuracyMetrics

final class TypingAccuracyMetricsTests: XCTestCase {
    func testInsertionsAreNotHiddenByClampingCER() {
        let score = AccuracyScore(reference: "a", entered: "abc", seconds: 2, actions: 3, backspaces: 0)
        XCTAssertEqual(score.edits, 2)
        XCTAssertEqual(score.cer, 2)
        XCTAssertEqual(score.msd!, 2.0 / 3, accuracy: 0.000001)
    }

    func testCaseSensitiveRomanAndCanonicalBangla() {
        XCTAssertEqual(AccuracyScore(reference: "T", entered: "t", seconds: 1, actions: 1, backspaces: 0).edits, 1)
        XCTAssertEqual(AccuracyScore(reference: "\u{09DC}", entered: "\u{09A1}\u{09BC}", seconds: 1, actions: 1, backspaces: 0).edits, 0)
        XCTAssertEqual(AccuracyScore.distance(Array("ab"), Array("ba")), 2)
    }

    func testEmptyReferenceAndInvalidTimingDoNotManufacturePerfectScores() {
        let score = AccuracyScore(reference: "", entered: "a", seconds: 0, actions: 1, backspaces: 0)
        XCTAssertNil(score.cer)
        XCTAssertNil(score.graphemesPerMinute)
        XCTAssertNil(score.actionsPerReferenceGrapheme)
    }

    func testCorrectionEffortRemainsVisibleWhenFinalTextIsPerfect() {
        let score = AccuracyScore(reference: "ab", entered: "ab", seconds: 4, actions: 4, backspaces: 1)
        XCTAssertEqual(score.edits, 0)
        XCTAssertEqual(score.actionsPerReferenceGrapheme, 2)
        XCTAssertEqual(score.backspacesPer100ReferenceGraphemes, 50)
        XCTAssertEqual(score.graphemesPerMinute, 30)
    }

    func testInvalidTrialsCannotEnterPairedComparison() throws {
        func trial(_ id: Int, _ variant: String, _ invalid: String?) -> AccuracyTrial {
            AccuracyTrial(id: id, variant: variant, posture: "two-thumbs", prompt: "ab", entered: "ab",
                          startedAt: 1, endedAt: 2, actions: 2, backspaces: 0, invalidReason: invalid,
                          surfaceWidth: 100, surfaceHeight: 100, frames: [], samples: [], commits: [])
        }
        let session = AccuracySession(schemaVersion: 1, sessionID: "synthetic-test", provenance: "synthetic-unit-test", sourceRevision: "test",
                                      osVersion: "test", deviceModel: "test", createdAt: "test", trialOrder: ["control", "candidate"],
                                      trials: [trial(0, "baseline-112", nil), trial(1, "ordered-rollover", "interrupted")])
        let result = try TypingAccuracyReport.generate(from: JSONEncoder().encode(session))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual((object["pairs"] as? [Any])?.count, 0)
    }

    func testPairedReportMatchesPostureAndPromptAndUsesCandidateMinusBaseline() throws {
        func trial(_ id: Int, _ variant: String, _ posture: String, _ entered: String) -> AccuracyTrial {
            AccuracyTrial(id: id, variant: variant, posture: posture, prompt: "ab", entered: entered,
                          startedAt: 1, endedAt: 3, actions: 2, backspaces: 0, invalidReason: nil,
                          surfaceWidth: 100, surfaceHeight: 100, frames: [], samples: [], commits: [])
        }
        let session = AccuracySession(schemaVersion: 1, sessionID: "synthetic-pairs", provenance: "synthetic-unit-test",
                                      sourceRevision: "test", osVersion: "test", deviceModel: "test", createdAt: "test", trialOrder: ["control", "candidate", "other posture"],
                                      trials: [trial(0, "baseline-112", "two-thumbs", "a"),
                                               trial(1, "ordered-rollover", "two-thumbs", "ab"),
                                               trial(2, "baseline-112", "one-thumb", "ab")])
        let result = try TypingAccuracyReport.generate(from: JSONEncoder().encode(session))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        let pairs = try XCTUnwrap(object["pairs"] as? [[String: Any]])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0]["cerChange"] as? Double, -0.5)
        XCTAssertEqual(pairs[0]["speedChangeGraphemesPerMinute"] as? Double, 30)
        XCTAssertEqual(pairs[0]["posture"] as? String, "two-thumbs")
    }

    func testPartialExportReportsMissingRounds() throws {
        let trial = AccuracyTrial(id: 0, variant: "baseline-112", posture: "one-thumb", prompt: "ab", entered: "ab",
                                  startedAt: 1, endedAt: 2, actions: 2, backspaces: 0, invalidReason: nil,
                                  surfaceWidth: 100, surfaceHeight: 100, frames: [], samples: [], commits: [])
        let session = AccuracySession(schemaVersion: 1, sessionID: "partial", provenance: "synthetic-unit-test",
                                      sourceRevision: "test", osVersion: "test", deviceModel: "test", createdAt: "test",
                                      trialOrder: ["baseline", "candidate"], trials: [trial])
        let result = try TypingAccuracyReport.generate(from: JSONEncoder().encode(session))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        let coverage = try XCTUnwrap(object["coverage"] as? [String: Any])
        XCTAssertEqual(coverage["isComplete"] as? Bool, false)
        XCTAssertEqual(coverage["missingTrialIDs"] as? [Int], [1])
    }
}
