//
//  AgentRemoteRuntimeModels.swift
//  WillDeep
//
//  Remote runtime descriptors, workspace locations, path validation,
//  and lightweight persistence helpers shared by SSH and daemon backends.
//

import Foundation
import Security

enum RuntimePlatform: String, Codable, CaseIterable, Identifiable {
    case macOS
    case linux
    case unknown

    var id: String { rawValue }

    static func parse(_ value: String) -> RuntimePlatform {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "darwin": return .macOS
        case "linux": return .linux
        default: return .unknown
        }
    }

    var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .linux: return "Linux"
        case .unknown: return "Unknown"
        }
    }
}

enum RuntimeArch: String, Codable, CaseIterable, Identifiable {
    case arm64
    case x86_64
    case unknown

    var id: String { rawValue }

    static func parse(_ value: String) -> RuntimeArch {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "arm64", "aarch64": return .arm64
        case "x86_64", "amd64": return .x86_64
        default: return .unknown
        }
    }

    var displayName: String {
        switch self {
        case .arm64: return "arm64"
        case .x86_64: return "x86_64"
        case .unknown: return "unknown"
        }
    }
}

enum RuntimeTransport: String, Codable, CaseIterable, Identifiable {
    case local
    case ssh
    case daemon

    var id: String { rawValue }
}

struct RuntimeCapabilities: Codable, Equatable {
    var hasGit: Bool
    var hasRipgrep: Bool
    var shellPath: String?
    var nodeVersion: String?
    var npmVersion: String?
    var yarnVersion: String?
    var pythonVersion: String?
    var pipVersion: String?
    var rubyVersion: String?
    var goVersion: String?
    var javaVersion: String?
    var ghVersion: String?
    var ghAuthStatus: String?
    var npmRegistry: String?
    var yarnRegistry: String?
    var npmProxy: String?
    var npmHTTPSProxy: String?
    var pipProxy: String?
    var proxyEnvironment: [String: String]

    static let empty = RuntimeCapabilities(
        hasGit: false,
        hasRipgrep: false,
        shellPath: nil,
        nodeVersion: nil,
        npmVersion: nil,
        yarnVersion: nil,
        pythonVersion: nil,
        pipVersion: nil,
        rubyVersion: nil,
        goVersion: nil,
        javaVersion: nil,
        ghVersion: nil,
        ghAuthStatus: nil,
        npmRegistry: nil,
        yarnRegistry: nil,
        npmProxy: nil,
        npmHTTPSProxy: nil,
        pipProxy: nil,
        proxyEnvironment: [:]
    )

    enum CodingKeys: String, CodingKey {
        case hasGit, hasRipgrep, shellPath
        case nodeVersion, npmVersion, yarnVersion, pythonVersion, pipVersion
        case rubyVersion, goVersion, javaVersion, ghVersion, ghAuthStatus
        case npmRegistry, yarnRegistry, npmProxy, npmHTTPSProxy, pipProxy, proxyEnvironment
    }

    init(
        hasGit: Bool,
        hasRipgrep: Bool,
        shellPath: String?,
        nodeVersion: String? = nil,
        npmVersion: String? = nil,
        yarnVersion: String? = nil,
        pythonVersion: String? = nil,
        pipVersion: String? = nil,
        rubyVersion: String? = nil,
        goVersion: String? = nil,
        javaVersion: String? = nil,
        ghVersion: String? = nil,
        ghAuthStatus: String? = nil,
        npmRegistry: String? = nil,
        yarnRegistry: String? = nil,
        npmProxy: String? = nil,
        npmHTTPSProxy: String? = nil,
        pipProxy: String? = nil,
        proxyEnvironment: [String: String] = [:]
    ) {
        self.hasGit = hasGit
        self.hasRipgrep = hasRipgrep
        self.shellPath = shellPath
        self.nodeVersion = nodeVersion
        self.npmVersion = npmVersion
        self.yarnVersion = yarnVersion
        self.pythonVersion = pythonVersion
        self.pipVersion = pipVersion
        self.rubyVersion = rubyVersion
        self.goVersion = goVersion
        self.javaVersion = javaVersion
        self.ghVersion = ghVersion
        self.ghAuthStatus = ghAuthStatus
        self.npmRegistry = npmRegistry
        self.yarnRegistry = yarnRegistry
        self.npmProxy = npmProxy
        self.npmHTTPSProxy = npmHTTPSProxy
        self.pipProxy = pipProxy
        self.proxyEnvironment = proxyEnvironment
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hasGit = try c.decodeIfPresent(Bool.self, forKey: .hasGit) ?? false
        self.hasRipgrep = try c.decodeIfPresent(Bool.self, forKey: .hasRipgrep) ?? false
        self.shellPath = try c.decodeIfPresent(String.self, forKey: .shellPath)
        self.nodeVersion = try c.decodeIfPresent(String.self, forKey: .nodeVersion)
        self.npmVersion = try c.decodeIfPresent(String.self, forKey: .npmVersion)
        self.yarnVersion = try c.decodeIfPresent(String.self, forKey: .yarnVersion)
        self.pythonVersion = try c.decodeIfPresent(String.self, forKey: .pythonVersion)
        self.pipVersion = try c.decodeIfPresent(String.self, forKey: .pipVersion)
        self.rubyVersion = try c.decodeIfPresent(String.self, forKey: .rubyVersion)
        self.goVersion = try c.decodeIfPresent(String.self, forKey: .goVersion)
        self.javaVersion = try c.decodeIfPresent(String.self, forKey: .javaVersion)
        self.ghVersion = try c.decodeIfPresent(String.self, forKey: .ghVersion)
        self.ghAuthStatus = try c.decodeIfPresent(String.self, forKey: .ghAuthStatus)
        self.npmRegistry = try c.decodeIfPresent(String.self, forKey: .npmRegistry)
        self.yarnRegistry = try c.decodeIfPresent(String.self, forKey: .yarnRegistry)
        self.npmProxy = try c.decodeIfPresent(String.self, forKey: .npmProxy)
        self.npmHTTPSProxy = try c.decodeIfPresent(String.self, forKey: .npmHTTPSProxy)
        self.pipProxy = try c.decodeIfPresent(String.self, forKey: .pipProxy)
        self.proxyEnvironment = try c.decodeIfPresent([String: String].self, forKey: .proxyEnvironment) ?? [:]
    }
}

struct RuntimeDescriptor: Identifiable, Codable, Equatable {
    var id: UUID
    var displayName: String
    var transport: RuntimeTransport
    var host: String
    var port: Int
    var username: String
    var identityFilePath: String?
    var daemonBaseURL: String?
    var defaultWorkspacePath: String
    var terminalProfile: RuntimeTerminalProfile?
    var platform: RuntimePlatform
    var arch: RuntimeArch
    var lastProbeAt: Date?
    var capabilities: RuntimeCapabilities

    init(
        id: UUID = UUID(),
        displayName: String,
        transport: RuntimeTransport = .ssh,
        host: String,
        port: Int = 22,
        username: String,
        identityFilePath: String? = nil,
        daemonBaseURL: String? = nil,
        defaultWorkspacePath: String,
        terminalProfile: RuntimeTerminalProfile? = nil,
        platform: RuntimePlatform = .unknown,
        arch: RuntimeArch = .unknown,
        lastProbeAt: Date? = nil,
        capabilities: RuntimeCapabilities = .empty
    ) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.host = host
        self.port = port
        self.username = username
        self.identityFilePath = identityFilePath
        self.daemonBaseURL = daemonBaseURL
        self.defaultWorkspacePath = defaultWorkspacePath
        self.terminalProfile = terminalProfile
        self.platform = platform
        self.arch = arch
        self.lastProbeAt = lastProbeAt
        self.capabilities = capabilities
    }

    var normalized: RuntimeDescriptor {
        var copy = self
        copy.displayName = copy.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.host = copy.host.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.username = copy.username.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.identityFilePath = copy.identityFilePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.identityFilePath?.isEmpty == true {
            copy.identityFilePath = nil
        }
        copy.daemonBaseURL = copy.daemonBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.daemonBaseURL?.isEmpty == true {
            copy.daemonBaseURL = nil
        }
        copy.defaultWorkspacePath = RemotePathValidator.normalizedWorkspaceRoot(copy.defaultWorkspacePath)
        copy.terminalProfile = copy.terminalProfile?.normalized
        copy.port = min(max(copy.port, 1), 65535)
        if copy.displayName.isEmpty {
            copy.displayName = copy.host.isEmpty ? "Remote Runtime" : copy.host
        }
        return copy
    }

    nonisolated var sshTarget: String {
        username.isEmpty ? host : "\(username)@\(host)"
    }

    var daemonEndpointURL: URL? {
        if let daemonBaseURL, let url = URL(string: daemonBaseURL), url.scheme != nil {
            return url
        }
        guard transport == .daemon, !host.isEmpty else { return nil }
        return URL(string: "http://\(host):\(port)")
    }
}

enum RemoteRuntimeSecretStore {
    private static let service = "com.willdeep.agent"
    private static let daemonTokenPrefix = "remote-runtime-token-"

    static func daemonToken(runtimeID: UUID) -> String {
        load(account: daemonTokenPrefix + runtimeID.uuidString)
    }

    static func saveDaemonToken(_ token: String, runtimeID: UUID) {
        save(token.trimmingCharacters(in: .whitespacesAndNewlines), account: daemonTokenPrefix + runtimeID.uuidString)
    }

    static func deleteDaemonToken(runtimeID: UUID) {
        save("", account: daemonTokenPrefix + runtimeID.uuidString)
    }

    private static func load(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    private static func save(_ value: String, account: String) {
        guard !value.isEmpty, let data = value.data(using: .utf8) else {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            return
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let existing = load(account: account)
        if existing == value { return }
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            SecItemDelete(baseQuery as CFDictionary)
        }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}

nonisolated enum WorkspaceLocation: Codable, Equatable {
    case local(path: String)
    case remote(runtimeID: UUID, path: String)

    enum Kind: String, Codable {
        case local
        case remote
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case path
        case runtimeID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        let path = try c.decode(String.self, forKey: .path)
        switch kind {
        case .local:
            self = .local(path: path)
        case .remote:
            let runtimeID = try c.decode(UUID.self, forKey: .runtimeID)
            self = .remote(runtimeID: runtimeID, path: path)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local(let path):
            try c.encode(Kind.local, forKey: .kind)
            try c.encode(path, forKey: .path)
        case .remote(let runtimeID, let path):
            try c.encode(Kind.remote, forKey: .kind)
            try c.encode(runtimeID, forKey: .runtimeID)
            try c.encode(path, forKey: .path)
        }
    }

    var localPath: String? {
        if case .local(let path) = self { return path }
        return nil
    }

    var remoteRuntimeID: UUID? {
        if case .remote(let runtimeID, _) = self { return runtimeID }
        return nil
    }

    var path: String {
        switch self {
        case .local(let path), .remote(_, let path): return path
        }
    }

    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent.isEmpty ? path : URL(fileURLWithPath: path).lastPathComponent
    }
}

enum RemotePathError: LocalizedError {
    case emptyWorkspace
    case emptyPath
    case pathEscapesWorkspace(String)

    var errorDescription: String? {
        switch self {
        case .emptyWorkspace:
            return "Remote workspace path is empty."
        case .emptyPath:
            return "Remote path is empty."
        case .pathEscapesWorkspace(let path):
            return "Remote path escapes the workspace: \(path)"
        }
    }
}

nonisolated enum RemotePathValidator {
    static func normalizedWorkspaceRoot(_ path: String) -> String {
        var cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.count > 1 && cleaned.hasSuffix("/") {
            cleaned.removeLast()
        }
        return cleaned
    }

    static func resolve(_ rawPath: String?, workspaceRoot: String) throws -> String {
        let root = normalizedWorkspaceRoot(workspaceRoot)
        guard !root.isEmpty else { throw RemotePathError.emptyWorkspace }
        let raw = (rawPath ?? ".").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw RemotePathError.emptyPath }

        let combined: String
        if raw == "." {
            combined = root
        } else if raw.hasPrefix("/") {
            combined = raw
        } else {
            combined = root + "/" + raw
        }

        let normalized = normalizeLexically(combined)
        guard normalized == root || normalized.hasPrefix(root + "/") else {
            throw RemotePathError.pathEscapesWorkspace(raw)
        }
        return normalized
    }

    static func relativePath(_ rawPath: String?, workspaceRoot: String) throws -> String {
        let root = normalizedWorkspaceRoot(workspaceRoot)
        let resolved = try resolve(rawPath, workspaceRoot: root)
        if resolved == root { return "." }
        return String(resolved.dropFirst(root.count + 1))
    }

    private static func normalizeLexically(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        let joined = parts.joined(separator: "/")
        return absolute ? "/" + joined : joined
    }
}

enum AgentRuntimeStore {
    private static let defaultsKey = "com.willdeep.agentRuntime.descriptors.v1"
    private static var defaultsOverride: UserDefaults?
    private static var defaults: UserDefaults { defaultsOverride ?? .standard }
    private static let descriptorsLock = NSLock()
    private static var descriptorsCache: [RuntimeDescriptor]?

    static func loadDescriptors() -> [RuntimeDescriptor] {
        descriptorsLock.lock()
        if let descriptorsCache {
            descriptorsLock.unlock()
            return descriptorsCache
        }
        descriptorsLock.unlock()

        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([RuntimeDescriptor].self, from: data) else {
            cacheDescriptors([])
            return []
        }
        let descriptors = decoded
            .filter { $0.transport != .local }
            .map(\.normalized)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        cacheDescriptors(descriptors)
        return descriptors
    }

    static func saveDescriptors(_ descriptors: [RuntimeDescriptor]) {
        let cleaned = descriptors
            .filter { $0.transport != .local }
            .map(\.normalized)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        if let data = try? JSONEncoder().encode(cleaned) {
            defaults.set(data, forKey: defaultsKey)
            cacheDescriptors(cleaned)
        }
    }

    static func descriptor(id: UUID) -> RuntimeDescriptor? {
        loadDescriptors().first { $0.id == id }
    }

    static func upsert(_ descriptor: RuntimeDescriptor) {
        var all = loadDescriptors()
        let normalized = descriptor.normalized
        if let index = all.firstIndex(where: { $0.id == normalized.id }) {
            all[index] = normalized
        } else {
            all.append(normalized)
        }
        saveDescriptors(all)
    }

    static func delete(id: UUID) {
        RemoteRuntimeSecretStore.deleteDaemonToken(runtimeID: id)
        saveDescriptors(loadDescriptors().filter { $0.id != id })
    }

    private static func cacheDescriptors(_ descriptors: [RuntimeDescriptor]) {
        descriptorsLock.lock()
        descriptorsCache = descriptors
        descriptorsLock.unlock()
    }

    private static func resetDescriptorCache() {
        descriptorsLock.lock()
        descriptorsCache = nil
        descriptorsLock.unlock()
    }

    @discardableResult
    static func setTestDefaults(_ defaults: UserDefaults?) -> UserDefaults? {
        let previous = defaultsOverride
        defaultsOverride = defaults
        resetDescriptorCache()
        return previous
    }
}
