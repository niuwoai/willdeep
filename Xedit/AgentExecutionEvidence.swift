import Foundation
import Darwin

/// Local host observations. Model text is never the source of lifecycle,
/// request receipts, verification, or the frozen definition identity.
nonisolated struct AgentExecutionEvidenceEvent: Codable, Equatable, Sendable {
    var schema = "willdeep.agent-rsi.runtime-event.v1"
    var id = UUID()
    var recordedAt = Date()
    var recordedAtMicroseconds = Int(Date().timeIntervalSince1970 * 1_000_000)
    var processID = AgentExecutionTrace.processID
    var runID: UUID
    var rootRunID: UUID
    var sessionID: UUID?
    var turnID: UUID?
    var parentRunID: UUID?
    var recoveredFromRunID: UUID?
    var mode: String
    var kind: String
    var definition: AgentRevisionSnapshot?
    var provider: String?
    var model: String?
    var promptSHA256: String?
    var effectiveTools: [String]?
    var toolName: String?
    var toolSucceeded: Bool?
    var runtimeParameters: AgentRuntimeParameters?
    var maximumRounds: Int?
    var roundCount: Int?
    var terminationReason: String?
    var contextWindow: Int?
    var skillsSHA256: String?
    var executionDeadline: Date?
    var executionWrapUpOnly: Bool?
    var requestLedgerOwnerID: UUID?
    var runtimeVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    var adapter = "macos-native-worker.v1"
    var requestID: UUID?
    var providerRequestID: String?
    var usageTokens: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var status: String?
    var verifierCommandSHA256: String?
    var verifierPassed: Bool?
    var verifierAttempts: Int?
    var verifierInputSHA256: String?
    var verifierEvidenceSHA256: String?
    var experimentID: String?
    var trialID: String?
    var arm: String?
    var tasksetSHA256: String?
}

nonisolated struct AgentExecutionEvidenceStore: Sendable {
    let root: URL
    private static let lock = NSRecursiveLock()
    private nonisolated(unsafe) static var recoveredSessions: Set<String> = []

    static var local: Self {
        let testing = NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let base = testing ? FileManager.default.temporaryDirectory.appendingPathComponent("WillDeepEvidenceTests-\(ProcessInfo.processInfo.processIdentifier)")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WillDeep")
        return Self(root: base.appendingPathComponent("execution-evidence/v1"))
    }

    func append(_ event: AgentExecutionEvidenceEvent) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = root.appendingPathComponent(event.id.uuidString.lowercased() + ".json")
        guard !FileManager.default.fileExists(atPath: target.path) else { throw AgentAssetError.immutableVersion }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        guard data.count <= 512 * 1024 else { throw AgentAssetError.invalidJSON }
        let temporary = root.appendingPathComponent(".pending-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AgentAssetError.server }
        defer { _ = Darwin.unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
            guard Darwin.link(temporary.path, target.path) == 0 else { throw AgentAssetError.immutableVersion }
        }
        catch { try? handle.close(); throw error }
    }

    func events() throws -> [AgentExecutionEvidenceEvent] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .filter { $0.pathExtension == "json" }.map { url in
                let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw AgentAssetError.invalidJSON }
                return try decoder.decode(AgentExecutionEvidenceEvent.self, from: Data(contentsOf: url))
            }.sorted {
                $0.recordedAtMicroseconds == $1.recordedAtMicroseconds ? $0.id.uuidString < $1.id.uuidString : $0.recordedAtMicroseconds < $1.recordedAtMicroseconds
            }
    }

    /// Only a new host process may seal an orphan; live tasks in another
    /// window of this process are not interrupted by a restore operation.
    func recoverInterrupted(sessionID: UUID) throws -> AgentExecutionEvidenceEvent? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let recoveryKey = root.path + ":" + sessionID.uuidString
        guard !Self.recoveredSessions.contains(recoveryKey) else { return nil }
        Self.recoveredSessions.insert(recoveryKey)
        let events = try events().filter { $0.sessionID == sessionID }
        let terminal = Set(events.filter { ["finished", "interrupted"].contains($0.kind) }.map(\.runID))
        var last: AgentExecutionEvidenceEvent?
        for start in events where start.kind == "started" && !terminal.contains(start.runID) && start.processID != AgentExecutionTrace.processID {
            var interrupted = start
            interrupted.id = UUID(); interrupted.recordedAt = Date(); interrupted.kind = "interrupted"
            interrupted.recordedAtMicroseconds = Int(Date().timeIntervalSince1970 * 1_000_000)
            interrupted.status = "interrupted"; interrupted.processID = AgentExecutionTrace.processID
            try append(interrupted); last = start
        }
        return last
    }
}

nonisolated struct AgentExecutionTrace: Sendable {
    static let processID = UUID()
    @TaskLocal static var current: AgentExecutionTrace?
    @TaskLocal static var physicalRequestID: UUID?
    let store: AgentExecutionEvidenceStore
    var seed: AgentExecutionEvidenceEvent

    func record(_ kind: String, configure: (inout AgentExecutionEvidenceEvent) -> Void = { _ in }) {
        var event = seed; event.id = UUID(); event.recordedAt = Date(); event.kind = kind
        event.recordedAtMicroseconds = Int(Date().timeIntervalSince1970 * 1_000_000)
        configure(&event)
        do { try store.append(event) }
        catch { NSLog("Execution evidence could not be persisted; this run has incomplete evidence") }
    }

    static func root(sessionID: UUID, turnID: UUID, configuration: AgentConfiguration) -> Self {
        // Ordinary turns never enumerate other sessions and recovery runs
        // once per process/session, not on every subsequent user turn.
        let store = current?.store ?? AgentExecutionEvidenceStore(root: AgentExecutionEvidenceStore.local.root
            .appendingPathComponent("sessions/" + sessionID.uuidString.lowercased()))
        let recovered = try? store.recoverInterrupted(sessionID: sessionID)
        let id = UUID()
        let event = AgentExecutionEvidenceEvent(runID: id, rootRunID: recovered?.rootRunID ?? id, sessionID: sessionID,
            turnID: turnID, recoveredFromRunID: recovered?.runID, mode: "root", kind: "started",
            provider: configuration.providerID, model: configuration.model)
        return Self(store: store, seed: event)
    }
}
