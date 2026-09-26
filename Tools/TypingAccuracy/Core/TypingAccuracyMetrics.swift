import Foundation

struct AccuracyTouchSample: Codable {
    let contact: Int
    let phase: String
    let time: Double // UITouch timestamp, seconds since boot
    let x: Double
    let y: Double
    let radius: Double
}

struct AccuracyKeyFrame: Codable {
    let row: Int
    let key: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct AccuracyCommit: Codable {
    let key: String
    let time: Double // system uptime, comparable to UITouch.timestamp
}

struct AccuracyTrial: Codable {
    let id: Int
    let variant: String
    let posture: String
    let prompt: String
    let entered: String
    let startedAt: Double
    let endedAt: Double
    let actions: Int
    let backspaces: Int
    let invalidReason: String?
    let surfaceWidth: Double
    let surfaceHeight: Double
    let frames: [AccuracyKeyFrame]
    let samples: [AccuracyTouchSample]
    let commits: [AccuracyCommit]
}

struct AccuracySession: Codable {
    let schemaVersion: Int
    let sessionID: String
    let provenance: String
    let sourceRevision: String
    let osVersion: String
    let deviceModel: String
    let createdAt: String
    let trialOrder: [String]
    var trials: [AccuracyTrial]
}

struct AccuracyScore: Codable {
    let edits: Int
    let referenceUnits: Int
    let enteredUnits: Int
    let cer: Double?
    let msd: Double?
    let graphemesPerMinute: Double?
    let actionsPerReferenceGrapheme: Double?
    let backspacesPer100ReferenceGraphemes: Double?

    init(reference: String, entered: String, seconds: Double, actions: Int, backspaces: Int) {
        // Canonical normalization only. Roman case and Bangla joiners matter.
        let expected = Array(reference.precomposedStringWithCanonicalMapping)
        let actual = Array(entered.precomposedStringWithCanonicalMapping)
        edits = Self.distance(expected, actual)
        referenceUnits = expected.count
        enteredUnits = actual.count
        cer = expected.isEmpty ? nil : Double(edits) / Double(expected.count)
        let denominator = max(expected.count, actual.count)
        msd = denominator == 0 ? nil : Double(edits) / Double(denominator)
        graphemesPerMinute = seconds > 0 ? Double(actual.count) * 60 / seconds : nil
        actionsPerReferenceGrapheme = expected.isEmpty ? nil : Double(actions) / Double(expected.count)
        backspacesPer100ReferenceGraphemes = expected.isEmpty ? nil : Double(backspaces) * 100 / Double(expected.count)
    }

    static func distance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1]
            for (j, y) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}

public enum TypingAccuracyReport {
    public static func generate(from data: Data) throws -> Data {
        let session = try JSONDecoder().decode(AccuracySession.self, from: data)
        guard session.schemaVersion == 1 else { throw ReportError.unsupportedSchema }
        struct TrialScore: Encodable {
            let id: Int
            let variant: String
            let posture: String
            let invalidReason: String?
            let score: AccuracyScore?
        }
        struct Report: Encodable {
            let sessionID: String
            let provenance: String
            let units = "NFC extended grapheme clusters; CER denominator is reference length; MSD denominator is max length"
            let scope = "Prompted Roman motor task. No claim about Bangla semantic accuracy, extension IPC, or population-level gains."
            let trials: [TrialScore]
            let pairs: [Pair]
        }
        struct Pair: Encodable {
            let posture: String
            let prompt: String
            let baselineTrial: Int
            let candidateTrial: Int
            let cerChange: Double
            let speedChangeGraphemesPerMinute: Double
            let backspaceChange: Int
        }
        let valid = session.trials.filter { $0.invalidReason == nil && $0.endedAt > $0.startedAt && !$0.prompt.isEmpty }
        var pairs: [Pair] = []
        for candidate in valid where candidate.variant == "ordered-rollover" {
            let controls = valid.filter { $0.variant == "baseline-112" && $0.posture == candidate.posture && $0.prompt == candidate.prompt }
            let candidates = valid.filter { $0.variant == candidate.variant && $0.posture == candidate.posture && $0.prompt == candidate.prompt }
            guard controls.count == 1, candidates.count == 1, let baseline = controls.first else { continue }
            func score(_ trial: AccuracyTrial) -> AccuracyScore {
                AccuracyScore(reference: trial.prompt, entered: trial.entered, seconds: trial.endedAt - trial.startedAt,
                              actions: trial.actions, backspaces: trial.backspaces)
            }
            let a = score(baseline), b = score(candidate)
            pairs.append(Pair(posture: candidate.posture, prompt: candidate.prompt,
                              baselineTrial: baseline.id, candidateTrial: candidate.id,
                              cerChange: b.cer! - a.cer!,
                              speedChangeGraphemesPerMinute: b.graphemesPerMinute! - a.graphemesPerMinute!,
                              backspaceChange: candidate.backspaces - baseline.backspaces))
        }
        let report = Report(sessionID: session.sessionID, provenance: session.provenance, trials: session.trials.map {
            let duration = $0.endedAt - $0.startedAt
            let invalid = $0.invalidReason ?? (duration <= 0 ? "invalid timing" : nil)
            return TrialScore(id: $0.id, variant: $0.variant, posture: $0.posture,
                              invalidReason: invalid,
                              score: invalid == nil ? AccuracyScore(reference: $0.prompt, entered: $0.entered,
                                  seconds: duration, actions: $0.actions, backspaces: $0.backspaces) : nil)
        }, pairs: pairs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    private enum ReportError: Error { case unsupportedSchema }
}
