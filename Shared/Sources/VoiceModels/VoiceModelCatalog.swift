import Foundation

/// What a model does in the two-pass pipeline.
enum VoiceModelRole: String, Codable, Sendable, CaseIterable {
    /// Small streaming recognizer: draft text while the user speaks.
    case streaming
    /// Larger model that re-transcribes each finished phrase.
    case refiner
}

/// Which engine loads the files. A new runtime is a code change; a new model for an
/// existing runtime is only a catalog entry.
enum VoiceModelRuntime: String, Codable, Sendable {
    /// sherpa-onnx online transducer (Zipformer2): encoder / decoder / joiner / tokens.
    case sherpaOnnxTransducer = "sherpa-onnx-transducer"
    /// sherpa-onnx offline NeMo CTC model (Conformer / FastConformer): model + tokens.
    /// Non-autoregressive, so a phrase costs one encoder pass.
    case sherpaOnnxNemoCTC = "sherpa-onnx-nemo-ctc"
}

struct VoiceModelFile: Codable, Hashable, Sendable {
    /// Path relative to both the source base URL and the install directory.
    let path: String
    let size: Int64
    let sha256: String
}

struct VoiceModelDescriptor: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let role: VoiceModelRole
    let runtime: VoiceModelRuntime
    let displayName: String
    let summary: String
    /// BCP 47 language tags the model transcribes.
    let languages: [String]
    /// Files are fetched from `baseURL` + `path`. The URL pins an immutable
    /// revision so a catalog entry always means the same bytes.
    let baseURL: URL
    let files: [VoiceModelFile]
    /// The smallest device RAM the model is offered on, in GiB.
    let minimumMemoryGiB: Double
    let license: String
    let attribution: String
    /// Runtime-specific settings (file roles for sherpa-onnx, the language for
    /// Whisper). Kept as strings so the catalog stays declarative.
    let options: [String: String]
    /// The model a fresh install picks for its role.
    let isDefault: Bool

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    func url(for file: VoiceModelFile) -> URL {
        file.path.split(separator: "/").reduce(baseURL) { $0.appendingPathComponent(String($1)) }
    }

    func option(_ key: String) -> String? { options[key] }
}

struct VoiceModelCatalog: Codable, Sendable {
    let version: Int
    let models: [VoiceModelDescriptor]

    func models(for role: VoiceModelRole) -> [VoiceModelDescriptor] {
        models.filter { $0.role == role }
    }

    func model(id: String) -> VoiceModelDescriptor? {
        models.first { $0.id == id }
    }

    /// The models this device can run, by physical memory.
    func models(for role: VoiceModelRole, deviceMemoryGiB: Double) -> [VoiceModelDescriptor] {
        models(for: role).filter { deviceMemoryGiB + 0.25 >= $0.minimumMemoryGiB }
    }

    func defaultModel(for role: VoiceModelRole, deviceMemoryGiB: Double) -> VoiceModelDescriptor? {
        let eligible = models(for: role, deviceMemoryGiB: deviceMemoryGiB)
        return eligible.first(where: \.isDefault) ?? eligible.first
    }

    static func load(from url: URL) throws -> VoiceModelCatalog {
        try JSONDecoder().decode(VoiceModelCatalog.self, from: Data(contentsOf: url))
    }

    /// Structural checks a catalog must pass before the app trusts it. Run by the
    /// unit tests against the shipped file, so a bad entry fails CI, not a phone.
    func validationErrors() -> [String] {
        var errors: [String] = []
        var seen = Set<String>()
        for model in models {
            if !seen.insert(model.id).inserted { errors.append("\(model.id): duplicate id") }
            if model.files.isEmpty { errors.append("\(model.id): no files") }
            if model.baseURL.scheme != "https" { errors.append("\(model.id): base URL must be https") }
            for file in model.files {
                if file.path.hasPrefix("/") || file.path.contains("..") {
                    errors.append("\(model.id): unsafe path \(file.path)")
                }
                if file.sha256.count != 64 || file.sha256.contains(where: { !$0.isHexDigit }) {
                    errors.append("\(model.id): bad sha256 for \(file.path)")
                }
                if file.size <= 0 { errors.append("\(model.id): bad size for \(file.path)") }
            }
            switch model.runtime {
            case .sherpaOnnxTransducer:
                for key in ["encoder", "decoder", "joiner", "tokens"] {
                    guard let path = model.option(key) else {
                        errors.append("\(model.id): missing option \(key)")
                        continue
                    }
                    if !model.files.contains(where: { $0.path == path }) {
                        errors.append("\(model.id): option \(key) names a file not in the list")
                    }
                }
            case .sherpaOnnxNemoCTC:
                for key in ["model", "tokens"] {
                    guard let path = model.option(key) else {
                        errors.append("\(model.id): missing option \(key)")
                        continue
                    }
                    if !model.files.contains(where: { $0.path == path }) {
                        errors.append("\(model.id): option \(key) names a file not in the list")
                    }
                }
            }
            if model.role == .streaming, model.runtime != .sherpaOnnxTransducer {
                errors.append("\(model.id): streaming role needs a streaming runtime")
            }
        }
        for role in VoiceModelRole.allCases where models(for: role).filter(\.isDefault).count > 1 {
            errors.append("\(role.rawValue): more than one default")
        }
        return errors
    }
}
