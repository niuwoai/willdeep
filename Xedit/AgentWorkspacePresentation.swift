import Foundation

/// UI-only metadata; never added to signed definitions, RSI specs or evidence.
nonisolated struct AgentRSIPresentationStore {
    let store: AgentRSIStore
    private var path: URL { store.directory.appendingPathComponent("presentation.json") }
    func label(candidateID: String) throws -> String? { try labels()[candidateID] }
    func save(label: String, candidateID: String) throws {
        guard !candidateID.isEmpty else { throw AgentRSIError.invalidContract }
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 120 else { throw AgentRSIError.invalidContract }
        var values = try labels(); values[candidateID] = value.isEmpty ? nil : value
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(values).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    private func labels() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        guard try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AgentRSIError.invalidContract }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: path))
    }
}

nonisolated enum AgentWorkspacePresentation {
    static func eligible(_ package: AgentPackageV1?) -> Bool {
        package?.signature == nil && package?.definition.definition_id.hasPrefix("user/") == true
    }
    static func nextVersion(_ version: String) -> String {
        let base = version.replacingOccurrences(of: "-rc[0-9]+$", with: "", options: .regularExpression)
        let number = Int(version.components(separatedBy: "-rc").last ?? "") ?? 0
        return base + "-rc" + String(number < Int.max ? number + 1 : number)
    }
    static func defaultRemark(name: String, version: String) -> String { name + " · " + version }
    static func matches(name: String, id: String, query: String) -> Bool {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || (name + " " + id).localizedCaseInsensitiveContains(value)
    }
    static func matchesSource(_ source: String, filter: String) -> Bool { filter == "all" || source == filter }
    static func latestEvidenceDate(_ experiment: AgentCanonicalJSON, evidence: [AgentCanonicalJSON]) -> String? {
        evidence.filter { $0["experiment_id"] == experiment["experiment_id"] }.compactMap { $0["finished_at"].text }.max()
    }
}

/// Also invalidates late responses after A → B → A, even if the token is reused.
nonisolated struct AgentWorkspaceOperationScope: Equatable {
    let owner: String
    let epoch: UUID
    func validate(owner: String, epoch: UUID) throws {
        guard matches(owner: owner, epoch: epoch) else { throw AgentRSIError.ownerChanged }
    }
    func matches(owner: String, epoch: UUID) -> Bool { self.owner == owner && self.epoch == epoch }
}

/// A queued action and its UI completion belong to the scope at the click,
/// rather than whichever account happens to be active when Task is scheduled.
@MainActor final class AgentWorkspaceOperationGate {
    struct Ticket { let id: UUID; let scope: AgentWorkspaceOperationScope }
    private var active: UUID?
    func begin(scope: AgentWorkspaceOperationScope) -> Ticket {
        let id = UUID(); active = id; return Ticket(id: id, scope: scope)
    }
    func invalidate() { active = nil }
    private func accepts(_ ticket: Ticket, current: AgentWorkspaceOperationScope) -> Bool {
        active == ticket.id && ticket.scope == current
    }
    func execute(_ ticket: Ticket, current: @MainActor () -> AgentWorkspaceOperationScope,
                 action: @MainActor () async throws -> Void, completion: @MainActor (Result<Void, Error>) -> Void) async {
        guard accepts(ticket, current: current()) else { return }
        let result: Result<Void, Error>
        do { try await action(); result = .success(()) } catch { result = .failure(error) }
        guard accepts(ticket, current: current()) else { return }
        active = nil; completion(result)
    }
}
