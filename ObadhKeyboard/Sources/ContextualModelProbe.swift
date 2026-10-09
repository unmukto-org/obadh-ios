#if DEBUG
import CoreML
import Darwin
import Foundation
import os

/// Opt-in diagnostics using exported corpus fixtures, never document text.
/// Kept outside the typing path and compiled out of release builds.
actor ContextualModelProbe {
    static let shared = ContextualModelProbe()
    private let log = Logger(subsystem: "org.unmukto.obadh.keyboard", category: "model-probe")
    private var residentModel: MLModel?

    private struct Fixtures: Decodable {
        let version: Int
        let vocabularySize: Int
        let contexts: [[Int]]
        let candidates: [[Int]]
        let checkpointSHA256: String
        let retrievalSHA256: String
    }

    private struct SubwordFixtures: Decodable {
        let version: Int
        let kind: String
        let sequenceLength: Int
        let vocabSize: Int
        let tokens: [[[Int]]]
        let lastIndices: [[Int]]
        let checkpointSHA256: String
        enum CodingKeys: String, CodingKey {
            case version, kind, tokens
            case sequenceLength = "sequence_length", vocabSize = "vocab_size"
            case lastIndices = "last_indices", checkpointSHA256 = "checkpoint_sha256"
        }
    }

    func run(directory: URL, mode: String) {
        if mode == "unload" {
            residentModel = nil
            log.notice("OBADH-MODEL unloaded footprintBytes=\(Self.footprint())")
            return
        }
        guard mode == "cpu" || mode == "all" else { return }
        do {
            residentModel = nil
            let root = directory.appendingPathComponent("model-probe", isDirectory: true)
            let fixtureURL = root.appendingPathComponent("fixtures.json")
            let size = try fixtureURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard (1...8_388_608).contains(size) else { throw ProbeError.invalidFixtures }
            let fixtureData = try Data(contentsOf: fixtureURL)
            struct Header: Decodable { let version: Int; let kind: String? }
            let header = try JSONDecoder().decode(Header.self, from: fixtureData)
            guard header.version == 1 else { throw ProbeError.invalidFixtures }
            let contexts: [[Int]], auxiliary: [[Int]], vocabularySize: Int
            let checkpointSHA256: String, retrievalSHA256: String, kind: String
            if header.kind == "subword-prefix" {
                let fixtures = try JSONDecoder().decode(SubwordFixtures.self, from: fixtureData)
                guard (1...1024).contains(fixtures.sequenceLength),
                      fixtures.tokens.allSatisfy({ $0.count == 1 && $0[0].count == fixtures.sequenceLength }),
                      fixtures.lastIndices.allSatisfy({ $0.count == 1 && (0..<fixtures.sequenceLength).contains($0[0]) }) else {
                    throw ProbeError.invalidFixtures
                }
                contexts = fixtures.tokens.map { $0[0] }; auxiliary = fixtures.lastIndices
                vocabularySize = fixtures.vocabSize; checkpointSHA256 = fixtures.checkpointSHA256
                retrievalSHA256 = "not-applicable"; kind = "subword-prefix"
            } else if header.kind == nil {
                let fixtures = try JSONDecoder().decode(Fixtures.self, from: fixtureData)
                contexts = fixtures.contexts; auxiliary = fixtures.candidates
                vocabularySize = fixtures.vocabularySize; checkpointSHA256 = fixtures.checkpointSHA256
                retrievalSHA256 = fixtures.retrievalSHA256; kind = "word-candidates"
            } else { throw ProbeError.invalidFixtures }
            guard (1...4096).contains(contexts.count), contexts.count == auxiliary.count,
                  (1...1_000_000).contains(vocabularySize) else { throw ProbeError.invalidFixtures }
            let before = Self.footprint()
            let configuration = MLModelConfiguration()
            configuration.computeUnits = mode == "cpu" ? .cpuOnly : .all
            let started = ContinuousClock.now
            let model = try MLModel(contentsOf: root.appendingPathComponent("model.mlmodelc"), configuration: configuration)
            let loadMS = Self.milliseconds(started.duration(to: .now))
            let afterLoad = Self.footprint()
            var durations: [Double] = []
            for index in contexts.indices {
                let context = try Self.array(contexts[index], vocabularySize: vocabularySize)
                let second: MLMultiArray
                let features: MLDictionaryFeatureProvider
                if kind == "subword-prefix" {
                    second = try MLMultiArray(shape: [1], dataType: .int32)
                    second[0] = NSNumber(value: auxiliary[index][0])
                    features = try MLDictionaryFeatureProvider(dictionary: ["tokens": context, "last_index": second])
                } else {
                    second = try Self.array(auxiliary[index], vocabularySize: vocabularySize)
                    features = try MLDictionaryFeatureProvider(dictionary: ["contexts": context, "candidate_ids": second])
                }
                let elapsed = try autoreleasepool {
                    let start = ContinuousClock.now
                    let output = try model.prediction(from: features)
                    let ms = Self.milliseconds(start.duration(to: .now))
                    guard let scores = output.featureValue(for: kind == "subword-prefix" ? "logits" : "scores")?.multiArrayValue,
                          scores.count == (kind == "subword-prefix" ? vocabularySize : second.count) else { throw ProbeError.invalidOutput }
                    for item in 0..<scores.count where !scores[item].doubleValue.isFinite {
                        throw ProbeError.invalidOutput
                    }
                    return ms
                }
                durations.append(elapsed)
            }
            residentModel = model
            let afterInference = Self.footprint()
            let first = durations.removeFirst()
            let ordered = durations.sorted()
            func percentile(_ p: Double) -> Double {
                ordered.isEmpty ? 0 : ordered[Int(Double(ordered.count - 1) * p)]
            }
            #if targetEnvironment(simulator)
            let environment = "simulator; no A13 latency, ANE, jetsam, or memory-limit claim"
            #else
            let environment = "physical device; identify hardware alongside this report"
            #endif
            let result: [String: Any] = [
                "version": 1, "environment": environment, "computeUnits": mode,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "fixtureCheckpointSHA256": checkpointSHA256, "fixtureKind": kind,
                "fixtureRetrievalSHA256": retrievalSHA256,
                "cases": contexts.count, "modelLoadMS": loadMS,
                "firstPredictionMS": first, "warmP50MS": percentile(0.5),
                "warmP95MS": percentile(0.95), "warmP99MS": percentile(0.99),
                "footprintBeforeBytes": before, "footprintAfterLoadBytes": afterLoad,
                "footprintAfterInferenceBytes": afterInference,
                "modelRetained": true, "inputPreparationIncludedInLatency": false,
                "scope": "actual debug keyboard process plus fixture inference; not production typing latency"
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: root.appendingPathComponent("report-\(mode).json"), options: .atomic)
            log.notice("OBADH-MODEL completed mode=\(mode, privacy: .public) cases=\(contexts.count) footprintBytes=\(afterInference) warmP95MS=\(percentile(0.95))")
        } catch {
            residentModel = nil
            log.error("OBADH-MODEL failed: \(String(describing: error), privacy: .public)")
        }
    }

    private enum ProbeError: Error { case invalidFixtures, invalidOutput }
    private static func array(_ values: [Int], vocabularySize: Int) throws -> MLMultiArray {
        guard (1...1024).contains(values.count), values.allSatisfy({ (0..<vocabularySize).contains($0) }) else {
            throw ProbeError.invalidFixtures
        }
        let result = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
        for (index, value) in values.enumerated() { result[index] = NSNumber(value: value) }
        return result
    }
    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
#endif
