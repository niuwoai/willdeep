//
//  AgentLocalModelSupport.swift
//  WillDeep
//
//  Local OpenAI-compatible model settings, routing helpers, and model
//  package downloads for lightweight auxiliary tasks.
//

import Foundation
import Combine

struct AgentLocalModelSettings: Codable, Equatable {
    static let defaultBaseURL = "http://127.0.0.1:11434/v1"
    static let defaultVisionModelID = "qwen3.5-4b-vl-q4_k_m"
    static let defaultSummaryModelID = "qwen3.5-4b-q4_k_m"
    static let defaultModelID = defaultSummaryModelID
    static let defaultComposerDisplayName = "Local Chat (Ollama)"
    static let composerProviderEntryID = UUID(uuidString: "9C9B8A64-4F84-4D9C-8F4F-4C7C6F63616C")!

    var enabled: Bool
    var baseURL: String
    var visionModel: String
    var summaryModel: String
    var preferForImageUnderstanding: Bool
    var preferForTitles: Bool
    var preferForContextSummaries: Bool
    var exposeAsComposerModel: Bool
    var composerDisplayName: String

    static let `default` = AgentLocalModelSettings(
        enabled: false,
        baseURL: defaultBaseURL,
        visionModel: defaultVisionModelID,
        summaryModel: defaultSummaryModelID,
        preferForImageUnderstanding: true,
        preferForTitles: true,
        preferForContextSummaries: false,
        exposeAsComposerModel: false,
        composerDisplayName: defaultComposerDisplayName
    )

    init(
        enabled: Bool,
        baseURL: String,
        visionModel: String,
        summaryModel: String,
        preferForImageUnderstanding: Bool,
        preferForTitles: Bool,
        preferForContextSummaries: Bool,
        exposeAsComposerModel: Bool,
        composerDisplayName: String
    ) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.visionModel = visionModel
        self.summaryModel = summaryModel
        self.preferForImageUnderstanding = preferForImageUnderstanding
        self.preferForTitles = preferForTitles
        self.preferForContextSummaries = preferForContextSummaries
        self.exposeAsComposerModel = exposeAsComposerModel
        self.composerDisplayName = composerDisplayName
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case baseURL
        case visionModel
        case summaryModel
        case preferForImageUnderstanding
        case preferForSummaries
        case preferForTitles
        case preferForContextSummaries
        case exposeAsComposerModel
        case composerDisplayName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.default
        let legacyPreferForSummaries = try c.decodeIfPresent(Bool.self, forKey: .preferForSummaries)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        self.baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? defaults.baseURL
        self.visionModel = try c.decodeIfPresent(String.self, forKey: .visionModel) ?? defaults.visionModel
        self.summaryModel = try c.decodeIfPresent(String.self, forKey: .summaryModel) ?? defaults.summaryModel
        self.preferForImageUnderstanding = try c.decodeIfPresent(Bool.self, forKey: .preferForImageUnderstanding)
            ?? defaults.preferForImageUnderstanding
        self.preferForTitles = try c.decodeIfPresent(Bool.self, forKey: .preferForTitles)
            ?? legacyPreferForSummaries
            ?? defaults.preferForTitles
        self.preferForContextSummaries = try c.decodeIfPresent(Bool.self, forKey: .preferForContextSummaries)
            ?? defaults.preferForContextSummaries
        self.exposeAsComposerModel = try c.decodeIfPresent(Bool.self, forKey: .exposeAsComposerModel)
            ?? defaults.exposeAsComposerModel
        self.composerDisplayName = try c.decodeIfPresent(String.self, forKey: .composerDisplayName)
            ?? defaults.composerDisplayName
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(visionModel, forKey: .visionModel)
        try c.encode(summaryModel, forKey: .summaryModel)
        try c.encode(preferForImageUnderstanding, forKey: .preferForImageUnderstanding)
        try c.encode(preferForTitles, forKey: .preferForTitles)
        try c.encode(preferForContextSummaries, forKey: .preferForContextSummaries)
        try c.encode(exposeAsComposerModel, forKey: .exposeAsComposerModel)
        try c.encode(composerDisplayName, forKey: .composerDisplayName)
    }

    var normalized: AgentLocalModelSettings {
        var result = self
        result.baseURL = result.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        result.visionModel = result.visionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        result.summaryModel = result.summaryModel.trimmingCharacters(in: .whitespacesAndNewlines)
        result.composerDisplayName = result.composerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.baseURL.isEmpty {
            result.baseURL = Self.defaultBaseURL
        }
        if result.visionModel.isEmpty || result.visionModel == Self.defaultSummaryModelID {
            result.visionModel = Self.defaultVisionModelID
        }
        if result.summaryModel.isEmpty {
            result.summaryModel = Self.defaultSummaryModelID
        }
        if result.composerDisplayName.isEmpty {
            result.composerDisplayName = Self.defaultComposerDisplayName
        }
        return result
    }

    func configuration(model: String) -> AgentConfiguration {
        AgentConfiguration(
            providerID: AgentProviderPreset.ollamaID,
            baseURL: normalized.baseURL,
            model: model,
            flashModel: model,
            proModel: model,
            routingMode: .flash,
            imageDescription: .default,
            apiKey: ""
        ).normalized
    }
}

enum AgentLocalAuxiliaryPurpose {
    case imageUnderstanding
    case title
    case contextSummary
}

nonisolated enum AgentLocalModelPrompting {
    static func prefersLocalLanguageInstruction(_ configuration: AgentConfiguration) -> Bool {
        if configuration.providerID == "ollama" {
            return true
        }
        guard let host = URL(string: configuration.baseURL)?.host?.lowercased() else {
            return false
        }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    static func applyLanguageInstruction(to systemPrompt: String, configuration: AgentConfiguration) -> String {
        guard prefersLocalLanguageInstruction(configuration) else {
            return systemPrompt
        }
        return """
        \(systemPrompt)

        LOCAL MODEL LANGUAGE PREFERENCE:
        - 请优先使用\(preferredResponseLanguageName())回答；如果用户最近明确使用了其他语言，则优先跟随用户语言。
        - 保留代码、命令、文件路径、API 名称、模型名和专有名词的原文。
        """
    }

    static func messagesWithLanguageInstruction(
        systemPrompt: String,
        userMessages: [AgentMessage],
        configuration: AgentConfiguration
    ) -> [AgentMessage] {
        let systemContent = applyLanguageInstruction(to: systemPrompt, configuration: configuration)
        return [AgentMessage(role: .system, content: systemContent)] + userMessages
    }

    private static func preferredResponseLanguageName() -> String {
        let identifier = Locale.preferredLanguages.first ?? Locale.current.identifier
        let lowercased = identifier.lowercased()
        if lowercased.hasPrefix("zh-hans") || lowercased == "zh" || lowercased.hasPrefix("zh-cn") || lowercased.hasPrefix("zh-sg") {
            return "简体中文"
        }
        if lowercased.hasPrefix("zh-hant") || lowercased.hasPrefix("zh-tw") || lowercased.hasPrefix("zh-hk") || lowercased.hasPrefix("zh-mo") {
            return "繁体中文"
        }
        if lowercased.hasPrefix("ja") { return "日语" }
        if lowercased.hasPrefix("ko") { return "韩语" }
        if lowercased.hasPrefix("fr") { return "法语" }
        if lowercased.hasPrefix("de") { return "德语" }
        if lowercased.hasPrefix("es") { return "西班牙语" }
        if lowercased.hasPrefix("pt") { return "葡萄牙语" }
        if lowercased.hasPrefix("ru") { return "俄语" }
        if lowercased.hasPrefix("en") { return "英语" }
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

struct AgentLocalModelPackageFile: Identifiable, Equatable, Sendable {
    let fileName: String
    let approximateBytes: Int64

    var id: String { fileName }
}

nonisolated struct AgentLocalModelFileMatch: Identifiable, Equatable, Sendable {
    enum Quality: Equatable, Sendable {
        case matched
        case close
        case mismatch
    }

    let fileName: String
    let path: String
    let bytes: Int64
    let expectedBytes: Int64
    let quality: Quality

    var id: String { path }

    init(file: AgentLocalModelPackageFile, path: String, bytes: Int64) {
        self.fileName = file.fileName
        self.path = path
        self.bytes = bytes
        self.expectedBytes = file.approximateBytes
        self.quality = Self.quality(bytes: bytes, expectedBytes: file.approximateBytes)
    }

    static func quality(bytes: Int64, expectedBytes: Int64) -> Quality {
        guard expectedBytes > 0, bytes > 0 else { return .mismatch }
        let delta = abs(Double(bytes - expectedBytes)) / Double(expectedBytes)
        if delta <= 0.12 { return .matched }
        if delta <= 0.35 { return .close }
        return .mismatch
    }
}

struct AgentLocalModelPackage: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let repositoryURL: URL
    let files: [AgentLocalModelPackageFile]

    var totalApproximateBytes: Int64 {
        files.reduce(0) { $0 + $1.approximateBytes }
    }

    nonisolated static let recommended = AgentLocalModelPackage(
        id: "qwen35-4b-claude-opus-distilled-vl-q4",
        displayName: "Qwen3.5 4B VL Q4_K_M",
        repositoryURL: URL(string: "https://www.modelscope.cn/models/Jackrong/Qwen3.5-4B-Claude-4.6-Opus-Reasoning-Distilled-GGUF")!,
        files: [
            AgentLocalModelPackageFile(
                fileName: "Qwen3.5-4B.Q4_K_M.gguf",
                approximateBytes: 2_500_000_000
            ),
            AgentLocalModelPackageFile(
                fileName: "mmproj-BF16.gguf",
                approximateBytes: 644_000_000
            )
        ]
    )

    func downloadURL(for file: AgentLocalModelPackageFile) -> URL {
        repositoryURL
            .appendingPathComponent("resolve")
            .appendingPathComponent("master")
            .appendingPathComponent(file.fileName)
    }
}

@MainActor
final class AgentLocalModelFileFinder: ObservableObject {
    static let shared = AgentLocalModelFileFinder()

    enum State: Equatable {
        case idle
        case searching
        case finished([AgentLocalModelFileMatch])
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle

    private init() {}

    func searchRecommendedPackage() async {
        if case .searching = state {
            return
        }
        state = .searching
        do {
            let matches = try await Self.search(package: .recommended)
            state = .finished(matches)
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    private nonisolated static func search(package: AgentLocalModelPackage) async throws -> [AgentLocalModelFileMatch] {
        try await Task.detached(priority: .utility) {
            let roots = searchRoots()
            var paths = Set<String>()
            for root in roots {
                for path in try runFind(root: root, files: package.files) {
                    paths.insert(path)
                }
            }
            return paths
                .compactMap { path -> AgentLocalModelFileMatch? in
                    guard let file = package.files.first(where: { $0.fileName == URL(fileURLWithPath: path).lastPathComponent }),
                          let bytes = fileSize(atPath: path) else {
                        return nil
                    }
                    return AgentLocalModelFileMatch(file: file, path: path, bytes: bytes)
                }
                .sorted { lhs, rhs in
                    if lhs.fileName != rhs.fileName {
                        return lhs.fileName < rhs.fileName
                    }
                    if lhs.quality != rhs.quality {
                        return qualityRank(lhs.quality) < qualityRank(rhs.quality)
                    }
                    return lhs.path < rhs.path
                }
        }.value
    }

    private nonisolated static func searchRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Sites"),
            home.appendingPathComponent("Models"),
            home.appendingPathComponent(".ollama"),
            home.appendingPathComponent("Library/Application Support/LM Studio"),
            home.appendingPathComponent("Library/Application Support/Ollama"),
            home.appendingPathComponent("Library/Application Support/WillDeep"),
            URL(fileURLWithPath: "/Volumes", isDirectory: true)
        ]
        var seen = Set<String>()
        return candidates.filter { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return false
            }
            return seen.insert(url.path).inserted
        }
    }

    private nonisolated static func runFind(root: URL, files: [AgentLocalModelPackageFile]) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        var arguments = [root.path, "-type", "f", "("]
        for file in files {
            arguments.append(contentsOf: ["-name", file.fileName, "-o"])
        }
        if arguments.last == "-o" {
            arguments.removeLast()
        }
        arguments.append(contentsOf: [")", "-print"])
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        try process.run()

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: .now() + 25) == .timedOut {
            process.terminate()
            process.waitUntilExit()
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text
            .split(separator: "\n")
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    private nonisolated static func fileSize(atPath path: String) -> Int64? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private nonisolated static func qualityRank(_ quality: AgentLocalModelFileMatch.Quality) -> Int {
        switch quality {
        case .matched: return 0
        case .close: return 1
        case .mismatch: return 2
        }
    }
}

nonisolated enum AgentLocalModelLocation {
    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("WillDeep")
            .appendingPathComponent("Agent")
            .appendingPathComponent("LocalModels")
    }

    static func packageDirectory(_ package: AgentLocalModelPackage = .recommended) -> URL {
        modelsDirectory.appendingPathComponent(package.id)
    }

    static func fileURL(_ file: AgentLocalModelPackageFile, in package: AgentLocalModelPackage = .recommended) -> URL {
        packageDirectory(package).appendingPathComponent(file.fileName)
    }

    static func isInstalled(_ package: AgentLocalModelPackage = .recommended) -> Bool {
        package.files.allSatisfy { FileManager.default.fileExists(atPath: fileURL($0, in: package).path) }
    }

    static func installedFileCount(_ package: AgentLocalModelPackage = .recommended) -> Int {
        package.files.filter { FileManager.default.fileExists(atPath: fileURL($0, in: package).path) }.count
    }
}

@MainActor
final class AgentLocalModelDownloader: ObservableObject {
    static let shared = AgentLocalModelDownloader()

    enum State: Equatable {
        case idle
        case downloading(
            fileName: String,
            fileIndex: Int,
            fileCount: Int,
            fileProgress: Double,
            overallProgress: Double,
            bytesReceived: Int64,
            totalBytes: Int64,
            speedBytesPerSec: Double
        )
        case finished
        case failed(message: String)
        case canceled
    }

    @Published private(set) var state: State = AgentLocalModelLocation.isInstalled() ? .finished : .idle

    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var observer: NSKeyValueObservation?
    private var lastProgressUpdate: (date: Date, bytes: Int64)?
    private var isCancelRequested = false

    private init() {}

    func downloadRecommendedPackage() async {
        if case .downloading = state {
            return
        }
        let package = AgentLocalModelPackage.recommended
        if AgentLocalModelLocation.isInstalled(package) {
            state = .finished
            return
        }
        isCancelRequested = false
        do {
            try FileManager.default.createDirectory(
                at: AgentLocalModelLocation.packageDirectory(package),
                withIntermediateDirectories: true
            )
            for (offset, file) in package.files.enumerated() {
                if isCancelRequested {
                    state = .canceled
                    return
                }
                if FileManager.default.fileExists(atPath: AgentLocalModelLocation.fileURL(file, in: package).path) {
                    continue
                }
                try await download(file: file, package: package, index: offset)
            }
            state = .finished
        } catch is CancellationError {
            state = .canceled
        } catch {
            if isCancelRequested || (error as? URLError)?.code == .cancelled {
                state = .canceled
            } else {
                state = .failed(message: error.localizedDescription)
            }
        }
    }

    func cancel() {
        isCancelRequested = true
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        observer?.invalidate()
        observer = nil
        state = AgentLocalModelLocation.isInstalled() ? .finished : .canceled
    }

    private func download(
        file: AgentLocalModelPackageFile,
        package: AgentLocalModelPackage,
        index: Int
    ) async throws {
        let destination = AgentLocalModelLocation.fileURL(file, in: package)
        let url = package.downloadURL(for: file)
        let fileCount = package.files.count
        let baseProgress = Double(index) / Double(max(fileCount, 1))
        state = .downloading(
            fileName: file.fileName,
            fileIndex: index + 1,
            fileCount: fileCount,
            fileProgress: 0,
            overallProgress: baseProgress,
            bytesReceived: 0,
            totalBytes: file.approximateBytes,
            speedBytesPerSec: 0
        )

        let session = URLSession(configuration: .default)
        self.session = session
        defer {
            observer?.invalidate()
            observer = nil
            task = nil
            session.invalidateAndCancel()
            self.session = nil
            lastProgressUpdate = nil
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = AgentLocalModelDownloadCompletion(continuation)
            let downloadTask = session.downloadTask(with: url) { [weak self] tempURL, _, error in
                let downloader = self
                Task { @MainActor in
                    guard let downloader else {
                        completion.resume(.failure(CancellationError()))
                        return
                    }
                    downloader.observer?.invalidate()
                    downloader.observer = nil
                    if let error {
                        completion.resume(.failure(error))
                        return
                    }
                    guard let tempURL else {
                        completion.resume(.failure(AgentLocalModelDownloadError.missingTemporaryFile))
                        return
                    }
                    do {
                        try FileManager.default.createDirectory(
                            at: destination.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: tempURL, to: destination)
                        completion.resume(.success(()))
                    } catch {
                        completion.resume(.failure(error))
                    }
                }
            }
            self.task = downloadTask
            observer = downloadTask.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                guard let self else { return }
                let received = progress.completedUnitCount
                let reportedTotal = progress.totalUnitCount > 0 ? progress.totalUnitCount : file.approximateBytes
                let fileProgress = max(0, min(1, progress.fractionCompleted.isFinite ? progress.fractionCompleted : 0))
                let overall = (Double(index) + fileProgress) / Double(max(fileCount, 1))
                Task { @MainActor in
                    let speed = self.computeSpeed(receivedNow: received)
                    self.state = .downloading(
                        fileName: file.fileName,
                        fileIndex: index + 1,
                        fileCount: fileCount,
                        fileProgress: fileProgress,
                        overallProgress: overall,
                        bytesReceived: received,
                        totalBytes: reportedTotal,
                        speedBytesPerSec: speed
                    )
                }
            }
            downloadTask.resume()
        }
    }

    private func computeSpeed(receivedNow: Int64) -> Double {
        let now = Date()
        defer { lastProgressUpdate = (now, receivedNow) }
        guard let last = lastProgressUpdate else { return 0 }
        let elapsed = now.timeIntervalSince(last.date)
        guard elapsed > 0.1 else { return 0 }
        return Double(receivedNow - last.bytes) / elapsed
    }
}

private final class AgentLocalModelDownloadCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

enum AgentLocalModelDownloadError: LocalizedError {
    case missingTemporaryFile

    var errorDescription: String? {
        switch self {
        case .missingTemporaryFile:
            return "Download finished but no temporary file was provided."
        }
    }
}

extension AppState {
    func localAuxiliaryConfiguration(for purpose: AgentLocalAuxiliaryPurpose) -> AgentConfiguration? {
        let settings = AgentSettingsStore.loadLocalModelSettings().normalized
        guard settings.enabled else { return nil }
        switch purpose {
        case .imageUnderstanding:
            guard settings.preferForImageUnderstanding else { return nil }
            return settings.configuration(model: settings.visionModel)
        case .title:
            guard settings.preferForTitles else { return nil }
            return settings.configuration(model: settings.summaryModel)
        case .contextSummary:
            guard settings.preferForContextSummaries else { return nil }
            return settings.configuration(model: settings.summaryModel)
        }
    }

    func imageDescriptionConfigurationCandidates(fallback: AgentConfiguration) -> [AgentConfiguration] {
        auxiliaryConfigurationCandidates(
            local: localAuxiliaryConfiguration(for: .imageUnderstanding),
            fallback: fallback
        )
    }

    func contextCompressionConfigurationCandidates() -> [AgentConfiguration] {
        auxiliaryConfigurationCandidates(
            local: localAuxiliaryConfiguration(for: .contextSummary),
            fallback: agentConfiguration.normalized.resolved(for: .compression)
        )
    }

    func titleSummaryConfigurationCandidates(remoteModelID: String) -> [AgentConfiguration] {
        var fallback = agentConfiguration.normalized
        fallback.model = remoteModelID
        fallback.flashModel = remoteModelID
        fallback.proModel = remoteModelID
        fallback.routingMode = .flash
        return auxiliaryConfigurationCandidates(
            local: localAuxiliaryConfiguration(for: .title),
            fallback: fallback
        )
    }

    private func auxiliaryConfigurationCandidates(
        local: AgentConfiguration?,
        fallback: AgentConfiguration
    ) -> [AgentConfiguration] {
        var candidates: [AgentConfiguration] = []
        if let local {
            candidates.append(local.normalized)
        }
        candidates.append(fallback.normalized)
        var seen = Set<String>()
        return candidates.filter { configuration in
            let usable = !configuration.requiresAPIKey || !configuration.apiKey.isEmpty
            guard usable else { return false }
            let key = [
                configuration.providerID,
                configuration.baseURL,
                configuration.model,
                configuration.providerKind.rawValue
            ].joined(separator: "\u{1F}")
            return seen.insert(key).inserted
        }
    }
}
