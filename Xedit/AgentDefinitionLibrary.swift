import Foundation
import Darwin

nonisolated struct AgentRevisionSnapshot: Codable, Equatable, Sendable {
    let definitionID: String
    let revision: String
    let baseRole: String
    let lockedSkills: [AgentDefinitionV1.Skill]
    var skillsPrompt: String? {
        let sections = lockedSkills.filter { !$0.content.isEmpty }.map { "### Skill: \($0.id) [\($0.sha256)]\n\($0.content)" }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }
}

nonisolated struct AgentDefinitionLibrary {
    enum Source: String, Codable, Sendable { case local, official, `private` }
    struct Installation: Codable, Equatable, Identifiable, Sendable {
        var definitionID: String
        var selected: String
        var revisions: [String]
        var source: Source
        var account: String?
        var enabled = true
        var binding = AgentSubagentProfile.ModelBinding.inheritsParent
        var etag: String?
        var dirty = false
        var deleted = false
        var conflict: AgentRegistryItem?
        var trustedKeys: [String: String]? = nil
        var pinned: Bool? = nil
        var id: String { (account ?? "local") + ":" + definitionID }
    }
    struct State: Codable { var installations: [Installation] = [] }
    struct VerifiedActivation: Codable {
        var identity: AgentRegistryIdentity
        var origin: String
        var sessionFingerprint: String
    }
    static let activeAccountKey = "com.willdeep.agentRegistry.activeAccount.v1"
    static let verifiedActivationKey = "com.willdeep.agentRegistry.verifiedActivation.v1"
    private static let lock = NSRecursiveLock()
    private nonisolated(unsafe) static var lockHandles: [String: (fd: Int32, depth: Int)] = [:]
    let root: URL
    let defaults: UserDefaults
    init(root: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let testing = NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.root = root ?? (testing
            ? FileManager.default.temporaryDirectory.appendingPathComponent("willdeep-registry-tests-\(ProcessInfo.processInfo.processIdentifier)")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WillDeep/AgentRegistry/v1"))
    }
    var activeAccount: String? { defaults.string(forKey: Self.activeAccountKey) }
    func activate(account: String?) {
        if let account { defaults.set(account, forKey: Self.activeAccountKey) }
        else { defaults.removeObject(forKey: Self.activeAccountKey) }
    }
    func recordVerifiedActivation(identity: AgentRegistryIdentity, origin: URL, sessionFingerprint: String) throws {
        let activation = VerifiedActivation(identity: identity, origin: origin.absoluteString, sessionFingerprint: sessionFingerprint)
        defaults.set(try JSONEncoder().encode(activation), forKey: Self.verifiedActivationKey)
        activate(account: identity.account(origin: origin))
    }
    func restoreVerifiedActivation(origin: URL?, sessionFingerprint: String?) {
        guard let origin, let sessionFingerprint,
              let data = defaults.data(forKey: Self.verifiedActivationKey),
              let activation = try? JSONDecoder().decode(VerifiedActivation.self, from: data),
              activation.origin == origin.absoluteString, activation.sessionFingerprint == sessionFingerprint else {
            activate(account: nil); return
        }
        activate(account: activation.identity.account(origin: origin))
    }
    private var stateURL: URL { root.appendingPathComponent("installations.json") }
    private func beginMutation() throws {
        Self.lock.lock()
        if var held = Self.lockHandles[root.path] {
            held.depth += 1; Self.lockHandles[root.path] = held; return
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            let fd = Darwin.open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw AgentAssetError.server }
            guard flock(fd, LOCK_EX) == 0 else { _ = Darwin.close(fd); throw AgentAssetError.server }
            Self.lockHandles[root.path] = (fd, 1)
        } catch { Self.lock.unlock(); throw error }
    }
    private func endMutation() {
        if var held = Self.lockHandles[root.path] {
            held.depth -= 1
            if held.depth == 0 { _ = flock(held.fd, LOCK_UN); _ = Darwin.close(held.fd); Self.lockHandles.removeValue(forKey: root.path) }
            else { Self.lockHandles[root.path] = held }
        }
        Self.lock.unlock()
    }
    private func secureWrite(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".pending-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AgentAssetError.server }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
            guard Darwin.rename(temporary.path, destination.path) == 0 else { throw AgentAssetError.server }
        } catch {
            try? handle.close(); try? FileManager.default.removeItem(at: temporary); throw error
        }
    }
    func state() throws -> State {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return State() }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
    }
    func save(_ state: State) throws {
        try beginMutation(); defer { endMutation() }
        try secureWrite(JSONEncoder().encode(state), to: stateURL)
    }
    private func packageURL(_ revision: String, account: String?) -> URL {
        let namespace = account.map { AgentPackageV1.hash(Data($0.utf8)) } ?? "public-local"
        return root.appendingPathComponent(namespace).appendingPathComponent(revision + ".json")
    }
    func package(revision: String, account: String? = nil) throws -> AgentPackageV1 {
        guard AgentPackageV1.isHash(revision) else { throw AgentAssetError.missingRevision }
        return try AgentPackageV1.decode(Data(contentsOf: packageURL(revision, account: account)))
    }
    func visibleInstallations() throws -> [Installation] {
        try state().installations.filter { $0.account == nil || $0.account == activeAccount }
    }
    @discardableResult
    func install(_ input: AgentPackageV1, source: Source, account: String? = nil, keys: [String: String] = [:], dirty: Bool = true) throws -> Installation {
        try installRevision(input, source: source, account: account, keys: keys, dirty: dirty, resolvingBranch: false)
    }
    /// Only explicit cloud resolution may archive a concurrent same-version
    /// branch. Ordinary edits retain the immutable semantic-version check.
    private func installRevision(_ input: AgentPackageV1, source: Source, account: String?, keys: [String: String],
                                 dirty: Bool, resolvingBranch: Bool) throws -> Installation {
        try beginMutation(); defer { endMutation() }
        let package = try AgentPackageV1.decode(input.encoded())
        if source == .official { try package.verify(keys: keys) }
        else {
            guard package.definition.definition_id.hasPrefix("user/"), package.signature == nil,
                  (source == .private) == (account != nil) else { throw AgentAssetError.untrustedSignature }
        }
        var state = try state()
        let existing = state.installations.firstIndex { $0.definitionID == package.definition.definition_id && $0.account == account }
        var installation = existing.map { state.installations[$0] } ?? Installation(
            definitionID: package.definition.definition_id, selected: package.sha256, revisions: [], source: source, account: account)
        for revision in installation.revisions {
            let previous = try self.package(revision: revision, account: account)
            if !resolvingBranch, previous.definition.version == package.definition.version, previous.sha256 != package.sha256 { throw AgentAssetError.immutableVersion }
        }
        if source == .official {
            // Verify host compatibility and trust changes before writing any envelope or selection.
            _ = try Self.project(package, binding: installation.binding)
            var trusted = installation.trustedKeys ?? [:]
            for (id, key) in keys {
                if let old = trusted[id], old != key { throw AgentAssetError.untrustedSignature }
                trusted[id] = key
            }
            installation.trustedKeys = trusted
        } else if existing == nil, (try? Self.project(package, binding: installation.binding)) == nil {
            installation.enabled = false
        }
        let destination = packageURL(package.sha256, account: account)
        try secureWrite(package.encoded(), to: destination)
        if !installation.revisions.contains(package.sha256) { installation.revisions.append(package.sha256) }
        installation.selected = package.sha256; installation.deleted = false
        installation.dirty = dirty && source != .official
        if let existing { state.installations[existing] = installation } else { state.installations.append(installation) }
        try save(state)
        return installation
    }
    func update(_ installation: Installation) throws {
        try beginMutation(); defer { endMutation() }
        var state = try state()
        guard let index = state.installations.firstIndex(where: { $0.id == installation.id }) else { throw AgentAssetError.missingRevision }
        state.installations[index] = installation; try save(state)
    }
    func select(_ revision: String, installation: Installation) throws {
        guard installation.revisions.contains(revision) else { throw AgentAssetError.missingRevision }
        let package = try package(revision: revision, account: installation.account)
        guard package.definition.definition_id == installation.definitionID else { throw AgentAssetError.invalidDefinition }
        var changed = installation; changed.selected = revision
        changed.pinned = true
        changed.dirty = changed.source != .official
        try update(changed)
    }
    func setEnabled(_ enabled: Bool, installation: Installation) throws {
        if enabled {
            let package = try package(revision: installation.selected, account: installation.account)
            _ = try Self.project(package, binding: installation.binding)
        }
        var changed = installation; changed.enabled = enabled
        try update(changed)
    }
    func fork(_ installation: Installation, id: String) throws -> Installation {
        let original = try package(revision: installation.selected, account: installation.account)
        var definition = original.definition; definition.definition_id = id
        definition.forked_from = original.sha256; definition.version = "1.0.0-rc1"
        return try install(.unsigned(definition), source: .local)
    }
    func share(_ installation: Installation, account: String) throws -> Installation {
        try beginMutation(); defer { endMutation() }
        guard installation.source == .local else { throw AgentAssetError.invalidDefinition }
        let hasAccountInstallation = try state().installations.contains { $0.definitionID == installation.definitionID && $0.account == account }
        var shared = try install(package(revision: installation.selected), source: .private, account: account)
        if !hasAccountInstallation {
            shared.binding = installation.binding
            shared.enabled = shared.enabled && installation.enabled
            shared.pinned = installation.pinned
            try update(shared)
        }
        return shared
    }
    func delete(_ installation: Installation) throws {
        var changed = installation; changed.deleted = true; changed.enabled = false; changed.dirty = true
        try update(changed)
    }
    /// Explicit resolution preserves the other revision on disk and requires another sync.
    func resolve(_ installation: Installation, keepLocal: Bool, newVersion: String? = nil) throws {
        try beginMutation(); defer { endMutation() }
        guard let remote = installation.conflict else { return }
        guard let current = try state().installations.first(where: { $0.id == installation.id }),
              current.selected == installation.selected, current.conflict == remote else { throw AgentAssetError.conflict }
        if keepLocal {
            var changed = installation
            let local = try package(revision: installation.selected, account: installation.account)
            if let newVersion {
                guard !newVersion.isEmpty, newVersion != local.definition.version, newVersion != remote.version else { throw AgentAssetError.immutableVersion }
                var definition = local.definition; definition.version = newVersion
                changed = try install(.unsigned(definition), source: .private, account: installation.account)
            } else if local.definition.version == remote.version && local.sha256 != remote.sha256 {
                throw AgentAssetError.immutableVersion
            }
            if let branch = remote.package {
                let archived = try AgentPackageV1.decode(branch.encoded())
                guard archived.definition.definition_id == installation.definitionID, archived.signature == nil else { throw AgentAssetError.invalidDefinition }
                try secureWrite(archived.encoded(), to: packageURL(archived.sha256, account: installation.account))
                if !changed.revisions.contains(archived.sha256) { changed.revisions.append(archived.sha256) }
            }
            changed.etag = remote.etag; changed.conflict = nil; changed.dirty = true
            try update(changed)
        } else {
            var changed = installation
            if let package = remote.package {
                changed = try installRevision(package, source: .private, account: installation.account, keys: [:], dirty: false, resolvingBranch: true)
            }
            changed.deleted = remote.deleted
            if remote.deleted { changed.enabled = false }
            changed.etag = remote.etag; changed.conflict = nil; changed.dirty = false
            try update(changed)
        }
    }
    func profiles() throws -> [AgentProfile] {
        var seen = Set<String>()
        let candidates = try visibleInstallations().sorted { ($0.account != nil) && ($1.account == nil) }
            .filter { seen.insert($0.definitionID).inserted }
        return try candidates.filter { $0.enabled && !$0.deleted }.compactMap { installation in
            let package = try package(revision: installation.selected, account: installation.account)
            if installation.source == .official { try package.verify(keys: installation.trustedKeys ?? [:]) }
            do { return try Self.project(package, binding: installation.binding) }
            catch AgentAssetError.unavailableCapability {
                // The installation remains visible with its readiness warning in Settings.
                return nil
            }
        }
    }
    static func project(_ package: AgentPackageV1, binding: AgentSubagentProfile.ModelBinding) throws -> AgentProfile {
        let definition = package.definition
        try definition.validate()
        // Native Workers currently accept a text task brief. Reject image instead of stripping it.
        guard definition.input_modalities == ["text"],
              let base = AgentSubagentProfileCatalog.builtIn.first(where: { $0.id == definition.base_role }) else { throw AgentAssetError.unavailableCapability }
        let requested = Set(definition.tools.flatMap { capability -> [String] in
            switch capability {
            case "workspace.read": return ["read_file", "list_directory", "search_files", "grep_files", AgentBundledRules.readerToolName]
            case "workspace.edit": return Array(AgentSubagentProfileCatalog.writeToolNames)
            case "repository.inspect": return ["git_status", "git_diff", "git_log"]
            case "process.verify": return ["run_command", "terminal_snapshot", "terminal_send_command"]
            default: return []
            }
        })
        let supported = base.effectiveToolNames(writeAccessGranted: true)
        // Capability requests narrow the code-owned role. Missing role capabilities are not grants.
        let effective = requested.intersection(supported)
        guard !effective.isEmpty else { throw AgentAssetError.unavailableCapability }
        var profile = AgentProfile.from(trade: base)
        profile.id = definition.definition_id; profile.name = definition.name["zh-Hans"] ?? definition.name["en"] ?? definition.definition_id
        profile.origin = .managed; profile.soul.purpose = definition.purpose
        profile.soul.promptSection = "Agent definition \(definition.definition_id) revision \(package.sha256) version \(definition.version).\n\n" + definition.instructions
        profile.soul.skillIdentifiers = []
        profile.runtime.modelBinding = binding
        profile.capability?.toolNames = effective
        profile.registrySnapshot = AgentRevisionSnapshot(definitionID: definition.definition_id, revision: package.sha256, baseRole: definition.base_role, lockedSkills: definition.skills)
        return profile
    }
}
