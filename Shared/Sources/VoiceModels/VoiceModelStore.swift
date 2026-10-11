import CryptoKit
import Foundation

/// Where installed models live and whether each is complete.
///
/// Layout, under the app's own Application Support (never the App Group: the
/// keyboard never loads a model, and the group container is shared storage):
///
///     VoiceModels/<model id>/<files…>        installed, verified
///     VoiceModels/<model id>/.installed.json  receipt, written last
///     VoiceModels/.staging/<model id>/…       in-flight download
///
/// A model counts as installed only when its receipt exists and matches the catalog
/// entry's file list, so a half-copied directory or an entry whose files changed in
/// a new catalog is never loaded.
struct VoiceModelStore: Sendable {
    struct Receipt: Codable, Equatable {
        let modelID: String
        let files: [VoiceModelFile]
        let installedAt: Date
    }

    let root: URL

    init(root: URL) {
        self.root = root
    }

    static func appDefault(fileManager: FileManager = .default) -> VoiceModelStore {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return VoiceModelStore(root: support.appendingPathComponent("VoiceModels", isDirectory: true))
    }

    func directory(for model: VoiceModelDescriptor) -> URL {
        root.appendingPathComponent(model.id, isDirectory: true)
    }

    func stagingDirectory(for model: VoiceModelDescriptor) -> URL {
        root.appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(model.id, isDirectory: true)
    }

    func fileURL(_ path: String, of model: VoiceModelDescriptor) -> URL {
        path.split(separator: "/").reduce(directory(for: model)) { $0.appendingPathComponent(String($1)) }
    }

    func stagedURL(_ path: String, of model: VoiceModelDescriptor) -> URL {
        path.split(separator: "/").reduce(stagingDirectory(for: model)) { $0.appendingPathComponent(String($1)) }
    }

    private func receiptURL(for model: VoiceModelDescriptor) -> URL {
        directory(for: model).appendingPathComponent(".installed.json")
    }

    func isInstalled(_ model: VoiceModelDescriptor) -> Bool {
        guard let data = try? Data(contentsOf: receiptURL(for: model)),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else {
            return false
        }
        return receipt.modelID == model.id && Set(receipt.files) == Set(model.files)
    }

    /// Bytes already staged for a model, for resuming progress after a relaunch.
    func stagedBytes(for model: VoiceModelDescriptor) -> Int64 {
        model.files.reduce(0) { total, file in
            let url = stagedURL(file.path, of: model)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return total + (size == file.size ? size : 0)
        }
    }

    /// Whether a staged file is present with the right size. The hash is checked
    /// when the file arrives, so size is enough here.
    func isStaged(_ file: VoiceModelFile, of model: VoiceModelDescriptor) -> Bool {
        let url = stagedURL(file.path, of: model)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return size == file.size
    }

    /// Moves a downloaded file into staging after verifying its hash. Throws, and
    /// deletes the download, on any mismatch.
    func stage(downloadedFile location: URL, as file: VoiceModelFile, of model: VoiceModelDescriptor,
               fileManager: FileManager = .default) throws {
        let digest = try Self.sha256(of: location)
        guard digest == file.sha256.lowercased() else {
            try? fileManager.removeItem(at: location)
            throw VoiceModelStoreError.checksumMismatch(file.path)
        }
        let destination = stagedURL(file.path, of: model)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: location, to: destination)
    }

    /// When every file is staged, swap the staging directory into place and write
    /// the receipt. The receipt is the commit point.
    func finalizeIfComplete(_ model: VoiceModelDescriptor, fileManager: FileManager = .default) throws -> Bool {
        guard model.files.allSatisfy({ isStaged($0, of: model) }) else { return false }
        let staging = stagingDirectory(for: model)
        let destination = directory(for: model)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.moveItem(at: staging, to: destination)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDestination = destination
        try? mutableDestination.setResourceValues(values)
        let receipt = Receipt(modelID: model.id, files: model.files, installedAt: Date())
        try JSONEncoder().encode(receipt).write(to: receiptURL(for: model), options: .atomic)
        return true
    }

    func remove(_ model: VoiceModelDescriptor, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directory(for: model))
        try? fileManager.removeItem(at: stagingDirectory(for: model))
    }

    /// Deletes directories no catalog entry claims (models dropped by an update).
    func removeOrphans(keeping catalog: VoiceModelCatalog, fileManager: FileManager = .default) {
        let known = Set(catalog.models.map(\.id))
        guard let entries = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        for entry in entries where !entry.hasPrefix(".") && !known.contains(entry) {
            try? fileManager.removeItem(at: root.appendingPathComponent(entry))
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum VoiceModelStoreError: Error, Equatable {
    case checksumMismatch(String)
}
