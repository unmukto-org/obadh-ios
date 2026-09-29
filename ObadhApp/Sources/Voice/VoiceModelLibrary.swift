import Foundation
import os

/// The app's view of voice models: what the catalog offers this device, what is
/// installed, what is active per role, and downloads in flight.
@MainActor
final class VoiceModelLibrary: ObservableObject {
    static let shared = VoiceModelLibrary()

    enum InstallState: Equatable {
        case notInstalled
        case downloading(progress: Double)
        case installed
        case failed(String)
    }

    @Published private(set) var states: [String: InstallState] = [:]
    @Published private(set) var activeStreamingID: String?
    @Published private(set) var activeRefinerID: String?

    let catalog: VoiceModelCatalog
    let store = VoiceModelStore.appDefault()
    let deviceMemoryGiB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

    private let preferences = VoicePreferences()
    private let log = Logger(subsystem: "org.unmukto.obadh", category: "voice-models")
    lazy var downloader = VoiceModelDownloader(store: store) { [weak self] event in
        Task { @MainActor in self?.handle(event) }
    }

    private init() {
        let url = Bundle.main.url(forResource: "VoiceModelCatalog", withExtension: "json")
        if let url, let loaded = try? VoiceModelCatalog.load(from: url) {
            catalog = loaded
        } else {
            // A missing catalog silently meant "no models, nothing to download" once;
            // say so loudly instead.
            Logger(subsystem: "org.unmukto.obadh", category: "voice-models")
                .fault("OBADH-VOICE model catalog missing or unreadable in the app bundle")
            catalog = VoiceModelCatalog(version: 0, models: [])
        }
        store.removeOrphans(keeping: catalog)
        refreshStates()
        activeStreamingID = resolvedActive(.streaming)
        activeRefinerID = resolvedActive(.refiner)
        downloader.reattach(catalog: catalog)
    }

    func models(for role: VoiceModelRole) -> [VoiceModelDescriptor] {
        catalog.models(for: role, deviceMemoryGiB: deviceMemoryGiB)
    }

    func state(of model: VoiceModelDescriptor) -> InstallState {
        states[model.id] ?? .notInstalled
    }

    var isReadyToDictate: Bool {
        activeStreamingConfiguration() != nil
    }

    /// Bytes still to download for the default set (streaming + refiner).
    var defaultSetDownloadBytes: Int64 {
        VoiceModelRole.allCases.compactMap { catalog.defaultModel(for: $0, deviceMemoryGiB: deviceMemoryGiB) }
            .filter { !store.isInstalled($0) }
            .reduce(0) { $0 + $1.totalBytes }
    }

    /// The whole download as one thing, which is how the user sees it.
    enum SetStatus: Equatable {
        case notInstalled(bytes: Int64)
        case downloading(progress: Double)
        case installed(bytes: Int64)
        case failed
    }

    var defaultSet: [VoiceModelDescriptor] {
        VoiceModelRole.allCases.compactMap { catalog.defaultModel(for: $0, deviceMemoryGiB: deviceMemoryGiB) }
    }

    var defaultSetStatus: SetStatus {
        let set = defaultSet
        let total = set.reduce(Int64(0)) { $0 + $1.totalBytes }
        if set.allSatisfy({ state(of: $0) == .installed }) { return .installed(bytes: total) }
        var done: Double = 0
        var downloading = false
        var failed = false
        for model in set {
            switch state(of: model) {
            case .installed: done += Double(model.totalBytes)
            case .downloading(let fraction): downloading = true; done += fraction * Double(model.totalBytes)
            case .failed: failed = true
            case .notInstalled: break
            }
        }
        if downloading { return .downloading(progress: done / Double(max(total, 1))) }
        if failed { return .failed }
        return .notInstalled(bytes: defaultSetDownloadBytes)
    }

    func removeDefaultSet() {
        for model in defaultSet { remove(model) }
    }

    func downloadDefaultSet() {
        for role in VoiceModelRole.allCases {
            guard let model = catalog.defaultModel(for: role, deviceMemoryGiB: deviceMemoryGiB),
                  !store.isInstalled(model) else { continue }
            download(model)
        }
    }

    func download(_ model: VoiceModelDescriptor) {
        states[model.id] = .downloading(progress: Double(store.stagedBytes(for: model)) / Double(max(model.totalBytes, 1)))
        downloader.download(model)
    }

    func cancelDownload(_ model: VoiceModelDescriptor) {
        downloader.cancel(model)
        states[model.id] = .notInstalled
    }

    func remove(_ model: VoiceModelDescriptor) {
        downloader.cancel(model)
        store.remove(model)
        refreshStates()
        activate(role: model.role)
    }

    func setActive(_ model: VoiceModelDescriptor) {
        guard store.isInstalled(model) else { return }
        switch model.role {
        case .streaming:
            preferences.activeStreamingModelID = model.id
            activeStreamingID = model.id
        case .refiner:
            preferences.activeRefinerModelID = model.id
            activeRefinerID = model.id
        }
    }

    // MARK: Pipeline configuration

    func activeStreamingConfiguration() -> VoiceRecognitionPipeline.StreamingConfiguration? {
        guard let id = activeStreamingID, let model = catalog.model(id: id), store.isInstalled(model),
              model.runtime == .sherpaOnnxTransducer,
              let encoder = model.option("encoder"), let decoder = model.option("decoder"),
              let joiner = model.option("joiner"), let tokens = model.option("tokens") else { return nil }
        return .init(paths: .init(
            encoder: store.fileURL(encoder, of: model),
            decoder: store.fileURL(decoder, of: model),
            joiner: store.fileURL(joiner, of: model),
            tokens: store.fileURL(tokens, of: model),
            modelType: model.option("modelType") ?? ""
        ))
    }

    // MARK: Internals

    private func refreshStates() {
        for model in catalog.models {
            if store.isInstalled(model) {
                states[model.id] = .installed
            } else if case .downloading = states[model.id] {
                continue
            } else {
                states[model.id] = .notInstalled
            }
        }
    }

    /// The stored choice if it is still installed and offered; otherwise the first
    /// installed model for the role, preferring the catalog default.
    private func resolvedActive(_ role: VoiceModelRole) -> String? {
        let stored = role == .streaming ? preferences.activeStreamingModelID : preferences.activeRefinerModelID
        let offered = models(for: role)
        if let stored, let model = offered.first(where: { $0.id == stored }), store.isInstalled(model) {
            return stored
        }
        let installed = offered.filter { store.isInstalled($0) }
        return (installed.first(where: \.isDefault) ?? installed.first)?.id
    }

    private func activate(role: VoiceModelRole) {
        let id = resolvedActive(role)
        switch role {
        case .streaming:
            preferences.activeStreamingModelID = id
            activeStreamingID = id
        case .refiner:
            preferences.activeRefinerModelID = id
            activeRefinerID = id
        }
    }

    private func handle(_ event: VoiceModelDownloader.Event) {
        switch event {
        case .progress(let id, let fraction):
            states[id] = .downloading(progress: fraction)
        case .installed(let id):
            states[id] = .installed
            if let model = catalog.model(id: id) {
                if (model.role == .streaming ? activeStreamingID : activeRefinerID) == nil {
                    setActive(model)
                }
            }
            log.notice("OBADH-VOICE model installed: \(id, privacy: .public)")
        case .failed(let id, let message):
            states[id] = .failed(message)
        }
    }
}

/// Background URLSession downloads, one task per file, verified and staged by
/// `VoiceModelStore`. Background so a few hundred megabytes survive the user leaving
/// the app; the tasks are re-attached on the next launch.
///
/// Privacy: no cookies, no cache, no credentials, a fixed generic User-Agent, and
/// requests only to the catalog's pinned URLs. The request is the only thing sent.
final class VoiceModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case progress(id: String, fraction: Double)
        case installed(id: String)
        case failed(id: String, message: String)
    }

    static let sessionIdentifier = "org.unmukto.obadh.voice-models"

    private let store: VoiceModelStore
    private let emit: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var models: [String: VoiceModelDescriptor] = [:]
    private var written: [Int: Int64] = [:]   // task id → bytes written
    private var taskModel: [Int: String] = [:]
    private lazy var backgroundSession = makeSession(URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier))
    /// Used when the background transfer daemon refuses us (seen with unsigned builds,
    /// where it rejects the connection without ever calling back). Downloads then need
    /// the app open, which beats a progress bar that never moves.
    private lazy var foregroundSession = makeSession(.default)
    private var usesForegroundSession = false
    private var session: URLSession {
        lock.withLock { usesForegroundSession } ? foregroundSession : backgroundSession
    }

    private func makeSession(_ configuration: URLSessionConfiguration) -> URLSession {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "Obadh"]
        if configuration.identifier != nil {
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
        }
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Set by the app delegate when iOS relaunches us to finish background events.
    var backgroundCompletionHandler: (() -> Void)?

    init(store: VoiceModelStore, emit: @escaping @Sendable (Event) -> Void) {
        self.store = store
        self.emit = emit
    }

    func reattach(catalog: VoiceModelCatalog) {
        lock.withLock { for model in catalog.models { models[model.id] = model } }
        session.getAllTasks { [self] tasks in
            lock.withLock {
                for task in tasks {
                    guard let key = task.taskDescription, let id = key.split(separator: "|").first.map(String.init) else { continue }
                    taskModel[task.taskIdentifier] = id
                }
            }
        }
    }

    func download(_ model: VoiceModelDescriptor) {
        lock.withLock { models[model.id] = model }
        session.getAllTasks { [self] tasks in
            let running = Set(tasks.compactMap(\.taskDescription))
            for file in model.files where !store.isStaged(file, of: model) {
                let key = "\(model.id)|\(file.path)"
                guard !running.contains(key) else { continue }
                var request = URLRequest(url: model.url(for: file))
                request.setValue("Obadh", forHTTPHeaderField: "User-Agent")
                let task = session.downloadTask(with: request)
                task.taskDescription = key
                task.countOfBytesClientExpectsToReceive = file.size
                lock.withLock { taskModel[task.taskIdentifier] = model.id }
                task.resume()
            }
            finalizeIfComplete(model.id)
            verifyTasksExist(for: model)
        }
    }

    /// A background session the daemon rejected hands out tasks that never run and
    /// never fail. If none of ours are registered shortly after starting, switch to
    /// the foreground session and start again.
    private func verifyTasksExist(for model: VoiceModelDescriptor) {
        guard !lock.withLock({ usesForegroundSession }) else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
            backgroundSession.getAllTasks { [self] tasks in
                let ours = tasks.contains { $0.taskDescription?.hasPrefix(model.id + "|") == true }
                let pending = model.files.contains { !store.isStaged($0, of: model) }
                guard pending, !ours else { return }
                lock.withLock { usesForegroundSession = true }
                download(model)
            }
        }
    }

    func cancel(_ model: VoiceModelDescriptor) {
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription?.hasPrefix(model.id + "|") == true {
                task.cancel()
            }
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = modelID(for: downloadTask) else { return }
        let fraction: Double = lock.withLock {
            written[downloadTask.taskIdentifier] = totalBytesWritten
            guard let model = models[id] else { return 0 }
            let staged = model.files.filter { store.isStaged($0, of: model) }.reduce(Int64(0)) { $0 + $1.size }
            let inFlight = taskModel.filter { $0.value == id }.keys.reduce(Int64(0)) { $0 + (written[$1] ?? 0) }
            return min(1, Double(staged + inFlight) / Double(max(model.totalBytes, 1)))
        }
        emit(.progress(id: id, fraction: fraction))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let model = lock.withLock({ models[parts[0]] }),
              let file = model.files.first(where: { $0.path == parts[1] }) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            emit(.failed(id: model.id, message: "Server returned \(http.statusCode)"))
            return
        }
        do {
            // The system deletes `location` when this method returns, so stage now.
            try store.stage(downloadedFile: location, as: file, of: model)
        } catch VoiceModelStoreError.checksumMismatch {
            emit(.failed(id: model.id, message: "A downloaded file did not match its checksum"))
            return
        } catch {
            emit(.failed(id: model.id, message: error.localizedDescription))
            return
        }
        finalizeIfComplete(model.id)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock {
            written[task.taskIdentifier] = nil
            taskModel[task.taskIdentifier] = nil
        }
        guard let error, (error as NSError).code != NSURLErrorCancelled,
              let id = modelID(for: task) ?? task.taskDescription?.split(separator: "|").first.map(String.init) else { return }
        emit(.failed(id: id, message: error.localizedDescription))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [self] in
            backgroundCompletionHandler?()
            backgroundCompletionHandler = nil
        }
    }

    private func modelID(for task: URLSessionTask) -> String? {
        lock.withLock { taskModel[task.taskIdentifier] }
    }

    private func finalizeIfComplete(_ id: String) {
        guard let model = lock.withLock({ models[id] }) else { return }
        do {
            if try store.finalizeIfComplete(model) {
                emit(.installed(id: id))
            }
        } catch {
            emit(.failed(id: id, message: error.localizedDescription))
        }
    }
}
