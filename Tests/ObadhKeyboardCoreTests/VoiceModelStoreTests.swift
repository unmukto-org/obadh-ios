import CryptoKit
import Foundation
import XCTest
@testable import ObadhKeyboardCore

final class VoiceModelStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-models-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func model(files: [(String, Data)]) -> VoiceModelDescriptor {
        VoiceModelDescriptor(
            id: "test-model", role: .streaming, runtime: .sherpaOnnxTransducer,
            displayName: "Test", summary: "", languages: ["bn"],
            baseURL: URL(string: "https://example.org/rev/")!,
            files: files.map { VoiceModelFile(path: $0.0, size: Int64($0.1.count), sha256: sha($0.1)) },
            minimumMemoryGiB: 2, license: "Apache-2.0", attribution: "",
            options: [:], isDefault: true
        )
    }

    private func download(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }

    func testInstallsOnlyWhenEveryFileIsVerified() throws {
        let a = Data("encoder".utf8), b = Data("tokens".utf8)
        let model = model(files: [("am/encoder.onnx", a), ("lang/tokens.txt", b)])
        let store = VoiceModelStore(root: root)

        try store.stage(downloadedFile: download(a), as: model.files[0], of: model)
        XCTAssertFalse(try store.finalizeIfComplete(model))
        XCTAssertFalse(store.isInstalled(model))

        try store.stage(downloadedFile: download(b), as: model.files[1], of: model)
        XCTAssertTrue(try store.finalizeIfComplete(model))
        XCTAssertTrue(store.isInstalled(model))
        XCTAssertEqual(try Data(contentsOf: store.fileURL("lang/tokens.txt", of: model)), b)
    }

    func testChecksumMismatchIsRejectedAndDeleted() throws {
        let model = model(files: [("x.bin", Data("good".utf8))])
        let store = VoiceModelStore(root: root)
        let bad = try download(Data("evil".utf8))
        XCTAssertThrowsError(try store.stage(downloadedFile: bad, as: model.files[0], of: model)) {
            XCTAssertEqual($0 as? VoiceModelStoreError, .checksumMismatch("x.bin"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))
        XCTAssertFalse(store.isStaged(model.files[0], of: model))
    }

    func testChangedCatalogEntryInvalidatesInstall() throws {
        let data = Data("v1".utf8)
        let v1 = model(files: [("x.bin", data)])
        let store = VoiceModelStore(root: root)
        try store.stage(downloadedFile: download(data), as: v1.files[0], of: v1)
        XCTAssertTrue(try store.finalizeIfComplete(v1))
        let v2 = model(files: [("x.bin", Data("v2".utf8))])
        XCTAssertFalse(store.isInstalled(v2))
    }

    /// The shipped catalog must pass the same structural checks the app relies on.
    func testShippedCatalogIsValid() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ObadhApp/Resources/VoiceModelCatalog.json")
        let catalog = try VoiceModelCatalog.load(from: url)
        XCTAssertEqual(catalog.validationErrors(), [])
        XCTAssertNotNil(catalog.defaultModel(for: .streaming, deviceMemoryGiB: 4))
    }
}
