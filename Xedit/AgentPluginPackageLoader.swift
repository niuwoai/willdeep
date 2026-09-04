//
//  AgentPluginPackageLoader.swift
//  WillDeep
//
//  Filesystem discovery and strict validation for Codex-compatible plugin
//  packages. This layer is intentionally UI-free so installation proposals
//  and tests use the exact same security checks as runtime discovery.
//

import CryptoKit
import Darwin
import Foundation

nonisolated enum AgentPluginPackageError: LocalizedError, Equatable {
    case missingCodexManifest(String)
    case unreadableManifest(String)
    case unsupportedSchema(Int)
    case invalidIdentifier(String)
    case invalidVersion(String)
    case incompatibleWillDeepVersion(String)
    case duplicateContribution(String)
    case missingContribution(String)
    case invalidContribution(String)
    case resourceOutsidePackage(String)
    case missingResource(String)
    case oversizedManifest(String)

    var errorDescription: String? {
        switch self {
        case .missingCodexManifest(let path):
            return "Missing .codex-plugin/plugin.json in \(path)."
        case .unreadableManifest(let path):
            return "Cannot read plugin manifest at \(path)."
        case .unsupportedSchema(let version):
            return "Unsupported WillDeep plugin schema version \(version)."
        case .invalidIdentifier(let value):
            return "Invalid plugin or contribution identifier: \(value)."
        case .invalidVersion(let value):
            return "Invalid semantic version: \(value)."
        case .incompatibleWillDeepVersion(let version):
            return "This plugin requires WillDeep \(version) or later."
        case .duplicateContribution(let identifier):
            return "Duplicate plugin contribution identifier: \(identifier)."
        case .missingContribution(let identifier):
            return "Plugin contribution not found: \(identifier)."
        case .invalidContribution(let detail):
            return "Invalid plugin contribution: \(detail)."
        case .resourceOutsidePackage(let path):
            return "Plugin resource escapes its package: \(path)."
        case .missingResource(let path):
            return "Plugin resource does not exist: \(path)."
        case .oversizedManifest(let path):
            return "Plugin manifest is too large: \(path)."
        }
    }
}

nonisolated enum AgentPluginPackageLoader {
    static let supportedSchemaVersion = 1
    static let maximumManifestBytes = 1_048_576
    static let maximumPackageFiles = 20_000
    static let maximumPackageBytes: Int64 = 256 * 1_024 * 1_024
    static let maximumPackageFileBytes: Int64 = 32 * 1_024 * 1_024
    /// 允许的菜单挂载点：与 `AgentPluginMenuLocation` 同源，避免这里和
    /// docs/plugin-schema 的枚举各写一份、加了新位置却忘了放行。
    static let allowedMenuLocations = Set(AgentPluginMenuLocation.all)
    static let allowedHostCommands: Set<String> = [
        "plugin.refresh",
        "destination.select",
        "settings.mcp",
        "plugins.open-center",
        // 打开指定 Agent 会话。执行时要求插件声明 conversation.read，
        // 见 AgentPluginCommandExecutor.executeHost。
        "session.open",
    ]
    static let allowedPermissions: Set<AgentPluginPermission> = [
        .conversationRead,
        .conversationWrite,
        .workspaceRead,
        .workspaceWrite,
        .processExecute,
        .networkAccess,
        .credentialUse,
        .clipboardWrite,
        .notifications,
        // 插件页面借宿主的手问模型 / 读 provider 清单，见
        // docs/PLUGIN_HOST_CAPABILITIES_DESIGN.md 与 AgentPluginAIBridge。
        .aiChat,
        .aiImage,
        .providersRead,
        .skillsRead,
    ]

    static func load(
        packageURL: URL,
        source: AgentPluginPackageSource,
        currentWillDeepVersion: String
    ) throws -> AgentPluginPackage {
        let root = canonicalFileURL(packageURL)
        let codexURL = root.appendingPathComponent(".codex-plugin/plugin.json")
        guard FileManager.default.fileExists(atPath: codexURL.path) else {
            throw AgentPluginPackageError.missingCodexManifest(root.path)
        }

        let codex: AgentCodexPluginManifest = try decodeManifest(at: codexURL)
        let pluginID = codex.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeIdentifier(pluginID) else {
            throw AgentPluginPackageError.invalidIdentifier(pluginID)
        }
        guard AppVersion(codex.version) != nil else {
            throw AgentPluginPackageError.invalidVersion(codex.version)
        }
        guard isSafePathComponent(codex.version) else {
            throw AgentPluginPackageError.invalidVersion(codex.version)
        }

        let willDeepURL = root.appendingPathComponent(".willdeep-plugin/plugin.json")
        let manifest: AgentPluginManifest?
        if FileManager.default.fileExists(atPath: willDeepURL.path) {
            manifest = try decodeManifest(at: willDeepURL)
        } else {
            manifest = nil
        }

        if let manifest {
            try validate(
                manifest,
                packageURL: root,
                currentWillDeepVersion: currentWillDeepVersion
            )
        }

        let digest = try packageDigest(root)
        let displayName = codex.interface?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = displayName?.isEmpty == false ? displayName! : pluginID
        let destinations = try resolvedDestinations(
            pluginID: pluginID,
            packageURL: root,
            manifest: manifest
        )
        return AgentPluginPackage(
            pluginID: pluginID,
            version: codex.version,
            displayName: resolvedName,
            summary: codex.interface?.shortDescription ?? codex.description ?? "",
            packageURL: root,
            source: source,
            digest: digest,
            codexManifest: codex,
            manifest: manifest,
            destinations: destinations
        )
    }

    static func safeResourceURL(relativePath: String, packageURL: URL) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("\0") else {
            throw AgentPluginPackageError.resourceOutsidePackage(relativePath)
        }
        let root = canonicalFileURL(packageURL)
        let candidate = root
            .appendingPathComponent(trimmed)
            .standardizedFileURL
        let canonicalCandidate = canonicalFileURL(candidate)
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard canonicalCandidate.path == root.path || canonicalCandidate.path.hasPrefix(prefix) else {
            throw AgentPluginPackageError.resourceOutsidePackage(relativePath)
        }
        guard FileManager.default.fileExists(atPath: canonicalCandidate.path) else {
            throw AgentPluginPackageError.missingResource(relativePath)
        }
        return canonicalCandidate
    }

    static func localizedString(
        key: String,
        package: AgentPluginPackage,
        locale: Locale = .current
    ) -> String {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return key }
        let localeRoot = package.packageURL.appendingPathComponent(".willdeep-plugin/locales")
        let languageCode = locale.language.languageCode?.identifier ?? "en"
        let candidates = [
            locale.identifier,
            languageCode == "zh" ? "zh-Hans" : languageCode,
            "en",
        ]
        for candidate in candidates {
            let url = localeRoot.appendingPathComponent("\(candidate).json")
            guard let data = try? Data(contentsOf: url),
                  data.count <= maximumManifestBytes,
                  let table = try? JSONDecoder().decode([String: String].self, from: data),
                  let value = table[normalizedKey],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            return value
        }
        return normalizedKey
    }

    private static func validate(
        _ manifest: AgentPluginManifest,
        packageURL: URL,
        currentWillDeepVersion: String
    ) throws {
        guard manifest.schemaVersion == supportedSchemaVersion else {
            throw AgentPluginPackageError.unsupportedSchema(manifest.schemaVersion)
        }
        if let minimum = manifest.minimumWillDeepVersion {
            guard let required = AppVersion(minimum) else {
                throw AgentPluginPackageError.invalidVersion(minimum)
            }
            if let current = AppVersion(currentWillDeepVersion), current < required {
                throw AgentPluginPackageError.incompatibleWillDeepVersion(minimum)
            }
        }

        let destinations = manifest.contributes.destinations
        let sidebars = manifest.contributes.sidebars
        let pages = manifest.contributes.pages
        let commands = manifest.contributes.commands
        try requireUnique(destinations.map(\.id))
        try requireUnique(sidebars.map(\.id))
        try requireUnique(pages.map(\.id))
        try requireUnique(commands.map(\.id))
        try requireUnique(manifest.contributes.settings.map(\.id))

        let pageIDs = Set(pages.map(\.id))
        let sidebarIDs = Set(sidebars.map(\.id))
        let commandIDs = Set(commands.map(\.id))
        let destinationIDs = Set(destinations.map(\.id))
        let declaredMCPServers = Set(manifest.dependencies.mcpServers)
        var localizationKeys: Set<String> = []
        for destination in destinations {
            try requireIdentifier(destination.id)
            try requireLocalizationKey(destination.titleKey)
            localizationKeys.insert(destination.titleKey)
            guard pageIDs.contains(destination.mainPage) else {
                throw AgentPluginPackageError.missingContribution(destination.mainPage)
            }
            if let sidebar = destination.companionSidebar,
               !sidebarIDs.contains(sidebar) {
                throw AgentPluginPackageError.missingContribution(sidebar)
            }
            for commandID in destination.toolbarCommandIDs where !commandIDs.contains(commandID) {
                throw AgentPluginPackageError.missingContribution(commandID)
            }
            if let icon = destination.icon, !icon.hasPrefix("sf:") {
                _ = try safeResourceURL(relativePath: icon, packageURL: packageURL)
            }
        }

        for page in pages {
            try requireIdentifier(page.id)
            switch page.runtime {
            case .localWeb:
                guard let entryPath = page.entryPath else {
                    throw AgentPluginPackageError.invalidContribution("localWeb page \(page.id) requires entryPath")
                }
                _ = try safeResourceURL(relativePath: entryPath, packageURL: packageURL)
            case .mcpApp:
                guard page.server?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      page.resourceURI?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    throw AgentPluginPackageError.invalidContribution("mcpApp page \(page.id) requires server and resourceURI")
                }
                guard page.server.map(declaredMCPServers.contains) == true else {
                    throw AgentPluginPackageError.invalidContribution("mcpApp page \(page.id) uses an undeclared MCP server")
                }
                guard let resourceURI = page.resourceURI,
                      URLComponents(string: resourceURI)?.scheme?.lowercased() == "ui" else {
                    throw AgentPluginPackageError.invalidContribution("mcpApp page \(page.id) requires a ui:// resource")
                }
            case .declarative:
                guard let schema = page.schema else {
                    throw AgentPluginPackageError.invalidContribution("declarative page \(page.id) requires schema")
                }
                let url = try safeResourceURL(relativePath: schema, packageURL: packageURL)
                try validateDeclarativeDocument(
                    at: url,
                    commandIDs: commandIDs,
                    localizationKeys: &localizationKeys
                )
            }
        }

        for sidebar in sidebars {
            try requireIdentifier(sidebar.id)
            if sidebar.mode == .declarative {
                guard sidebar.schema != nil || sidebar.resource != nil else {
                    throw AgentPluginPackageError.invalidContribution("declarative sidebar \(sidebar.id) requires schema or resource")
                }
                if let schema = sidebar.schema {
                    let url = try safeResourceURL(relativePath: schema, packageURL: packageURL)
                    try validateDeclarativeDocument(
                        at: url,
                        commandIDs: commandIDs,
                        localizationKeys: &localizationKeys
                    )
                }
                if let resource = sidebar.resource {
                    guard resource.type == nil || resource.type == "mcpResource",
                          declaredMCPServers.contains(resource.server),
                          !resource.uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AgentPluginPackageError.invalidContribution("sidebar \(sidebar.id) has an invalid MCP resource")
                    }
                }
            }
        }

        for command in commands {
            try requireIdentifier(command.id)
            try requireLocalizationKey(command.titleKey)
            localizationKeys.insert(command.titleKey)
            if let icon = command.icon {
                guard icon.hasPrefix("sf:"), icon.count > 3 else {
                    throw AgentPluginPackageError.invalidContribution("command \(command.id) requires an sf: icon")
                }
            }
            switch command.handler.type {
            case .host:
                guard let action = command.handler.action,
                      allowedHostCommands.contains(action) else {
                    throw AgentPluginPackageError.invalidContribution("host command \(command.id) requires action")
                }
            case .mcpTool:
                guard command.handler.server?.isEmpty == false,
                      command.handler.tool?.isEmpty == false else {
                    throw AgentPluginPackageError.invalidContribution("MCP command \(command.id) requires server and tool")
                }
                guard command.handler.server.map(declaredMCPServers.contains) == true else {
                    throw AgentPluginPackageError.invalidContribution("MCP command \(command.id) uses an undeclared server")
                }
            case .navigate:
                guard let target = command.handler.destination,
                      destinationIDs.contains(target) else {
                    throw AgentPluginPackageError.invalidContribution("navigate command \(command.id) requires destination")
                }
            }
        }

        for location in manifest.contributes.menus.keys where !allowedMenuLocations.contains(location) {
            throw AgentPluginPackageError.invalidContribution("unsupported menu location \(location)")
        }
        for (location, ids) in manifest.contributes.menus {
            for id in ids where !commandIDs.contains(id) {
                throw AgentPluginPackageError.invalidContribution("menu \(location) references unknown command \(id)")
            }
        }

        for setting in manifest.contributes.settings {
            try requireIdentifier(setting.id)
            try requireLocalizationKey(setting.titleKey)
            localizationKeys.insert(setting.titleKey)
            if let descriptionKey = setting.descriptionKey {
                try requireLocalizationKey(descriptionKey)
                localizationKeys.insert(descriptionKey)
            }
            if setting.type == .enumeration {
                guard !setting.options.isEmpty else {
                    throw AgentPluginPackageError.invalidContribution("enum setting \(setting.id) requires options")
                }
                for optionKey in setting.options {
                    try requireLocalizationKey(optionKey)
                    localizationKeys.insert(optionKey)
                }
            }
            if setting.type == .secret,
               setting.defaultValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                throw AgentPluginPackageError.invalidContribution("secret setting \(setting.id) cannot have a default value")
            }
            if let defaultValue = setting.defaultValue {
                switch setting.type {
                case .number:
                    guard Double(defaultValue) != nil else {
                        throw AgentPluginPackageError.invalidContribution(
                            "number setting \(setting.id) has an invalid default value"
                        )
                    }
                case .boolean:
                    guard defaultValue == "true" || defaultValue == "false" else {
                        throw AgentPluginPackageError.invalidContribution(
                            "boolean setting \(setting.id) has an invalid default value"
                        )
                    }
                case .enumeration:
                    guard setting.options.contains(defaultValue) else {
                        throw AgentPluginPackageError.invalidContribution(
                            "enum setting \(setting.id) has a default outside its options"
                        )
                    }
                case .string, .secret:
                    break
                }
            }
        }
        for dependency in manifest.dependencies.mcpServers + manifest.dependencies.skills {
            try requireIdentifier(dependency)
        }
        for permission in manifest.permissions where !allowedPermissions.contains(permission) {
            throw AgentPluginPackageError.invalidContribution("unknown permission \(permission.rawValue)")
        }
        if manifest.contributes.settings.contains(where: { $0.type == .secret }),
           !manifest.permissions.contains(.credentialUse) {
            throw AgentPluginPackageError.invalidContribution(
                "secret settings require credentials.use permission"
            )
        }
        try validatePackagedMCP(manifest: manifest, packageURL: packageURL)
        try validateEnglishLocalization(keys: localizationKeys, packageURL: packageURL)
    }

    private static func validatePackagedMCP(
        manifest: AgentPluginManifest,
        packageURL: URL
    ) throws {
        let configURL = packageURL.appendingPathComponent("mcp.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        guard let data = try? Data(contentsOf: configURL), data.count <= maximumManifestBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let definitions = root["mcpServers"] as? [String: Any] else {
            throw AgentPluginPackageError.unreadableManifest("mcp.json")
        }
        let declaredServers = Set(manifest.dependencies.mcpServers)
        let permissions = Set(manifest.permissions)
        let settingIDs = Set(manifest.contributes.settings.map(\.id))
        for (name, rawDefinition) in definitions {
            try requireIdentifier(name)
            guard declaredServers.contains(name),
                  let definition = rawDefinition as? [String: Any],
                  let server = AgentMCPServerDirectory.parseJSONServer(
                    name: name,
                    source: .plugin,
                    dict: definition
                  ) else {
                throw AgentPluginPackageError.invalidContribution("invalid packaged MCP server \(name)")
            }
            switch server.transport {
            case .stdio:
                guard permissions.contains(.processExecute) else {
                    throw AgentPluginPackageError.invalidContribution(
                        "stdio MCP server \(name) requires process.execute permission"
                    )
                }
            case .streamableHTTP:
                guard permissions.contains(.networkAccess),
                      let scheme = URLComponents(string: server.url)?.scheme?.lowercased(),
                      scheme == "https" || scheme == "http" else {
                    throw AgentPluginPackageError.invalidContribution(
                        "HTTP MCP server \(name) requires network.access and an HTTP(S) URL"
                    )
                }
            }
            for values in [server.env, server.headers] {
                for (key, value) in values {
                    let placeholders = settingPlaceholders(in: value)
                    guard placeholders.allSatisfy(settingIDs.contains) else {
                        throw AgentPluginPackageError.invalidContribution(
                            "MCP server \(name) references an unknown setting"
                        )
                    }
                    if AgentMCPServerConfig.isSensitiveCredentialKey(key),
                       !AgentCredentialStore.isReference(value),
                       placeholders.isEmpty {
                        throw AgentPluginPackageError.invalidContribution(
                            "MCP server \(name) contains a plaintext credential"
                        )
                    }
                }
            }
        }
    }

    private static func settingPlaceholders(in value: String) -> Set<String> {
        let pattern = #"\$\{setting:([A-Za-z0-9][A-Za-z0-9_.-]{0,159})\}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return Set(expression.matches(in: value, range: range).compactMap { match in
            guard let keyRange = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[keyRange])
        })
    }

    private static func validateDeclarativeDocument(
        at url: URL,
        commandIDs: Set<String>,
        localizationKeys: inout Set<String>
    ) throws {
        let document: AgentPluginSidebarDocument = try decodeManifest(at: url)
        localizationKeys.formUnion(
            try validateDeclarativeDocument(document, commandIDs: commandIDs)
        )
    }

    static func validateDeclarativeDocument(
        _ document: AgentPluginSidebarDocument,
        commandIDs: Set<String>
    ) throws -> Set<String> {
        guard document.schemaVersion == supportedSchemaVersion else {
            throw AgentPluginPackageError.unsupportedSchema(document.schemaVersion)
        }
        var seen: Set<String> = []
        var componentCount = 0
        var localizationKeys: Set<String> = []
        func validate(_ components: [AgentPluginSidebarComponent], depth: Int) throws {
            guard depth <= 20 else {
                throw AgentPluginPackageError.invalidContribution("declarative component nesting exceeds 20 levels")
            }
            for component in components {
                componentCount += 1
                guard componentCount <= 1_000 else {
                    throw AgentPluginPackageError.invalidContribution("declarative document exceeds 1000 components")
                }
                try requireIdentifier(component.id)
                guard seen.insert(component.id).inserted else {
                    throw AgentPluginPackageError.duplicateContribution(component.id)
                }
                if let titleKey = component.titleKey {
                    try requireLocalizationKey(titleKey)
                    localizationKeys.insert(titleKey)
                }
                if let subtitleKey = component.subtitleKey {
                    try requireLocalizationKey(subtitleKey)
                    localizationKeys.insert(subtitleKey)
                }
                if let progress = component.progress, !progress.isFinite || !(0...1).contains(progress) {
                    throw AgentPluginPackageError.invalidContribution("progress for \(component.id) must be between 0 and 1")
                }
                if let command = component.command, !commandIDs.contains(command) {
                    throw AgentPluginPackageError.missingContribution(command)
                }
                for command in component.contextCommands where !commandIDs.contains(command) {
                    throw AgentPluginPackageError.missingContribution(command)
                }
                try validate(component.children, depth: depth + 1)
            }
        }
        try validate(document.components, depth: 0)
        return localizationKeys
    }

    static func validateEnglishLocalization(
        keys: Set<String>,
        packageURL: URL
    ) throws {
        guard !keys.isEmpty else { return }
        let relativePath = ".willdeep-plugin/locales/en.json"
        let url = try safeResourceURL(relativePath: relativePath, packageURL: packageURL)
        let table: [String: String] = try decodeManifest(at: url)
        for key in keys {
            guard let value = table[key],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentPluginPackageError.invalidContribution("missing English localization key \(key)")
            }
        }
    }

    private static func resolvedDestinations(
        pluginID: String,
        packageURL: URL,
        manifest: AgentPluginManifest?
    ) throws -> [AgentPluginDestinationDescriptor] {
        guard let manifest else { return [] }
        let pages = Dictionary(uniqueKeysWithValues: manifest.contributes.pages.map { ($0.id, $0) })
        let sidebars = Dictionary(uniqueKeysWithValues: manifest.contributes.sidebars.map { ($0.id, $0) })
        return try manifest.contributes.destinations.map { contribution in
            guard let page = pages[contribution.mainPage] else {
                throw AgentPluginPackageError.missingContribution(contribution.mainPage)
            }
            let sidebar = contribution.companionSidebar.flatMap { sidebars[$0] }
                ?? AgentPluginSidebarContribution(id: "\(contribution.id).sessions", mode: .sessionList)
            return AgentPluginDestinationDescriptor(
                qualifiedID: "\(pluginID):\(contribution.id)",
                pluginID: pluginID,
                packageURL: packageURL,
                navigation: AgentPluginNavigationDescriptor(
                    titleKey: contribution.titleKey,
                    icon: contribution.icon
                ),
                companionSidebar: sidebar,
                mainPage: page,
                toolbarCommandIDs: contribution.toolbarCommandIDs,
                defaultPinned: contribution.defaultPinned
            )
        }
    }

    private static func decodeManifest<T: Decodable>(at url: URL) throws -> T {
        guard let data = try? Data(contentsOf: url) else {
            throw AgentPluginPackageError.unreadableManifest(url.path)
        }
        guard data.count <= maximumManifestBytes else {
            throw AgentPluginPackageError.oversizedManifest(url.path)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AgentPluginPackageError.unreadableManifest("\(url.path): \(error.localizedDescription)")
        }
    }

    private static func requireUnique(_ identifiers: [String]) throws {
        var seen: Set<String> = []
        for identifier in identifiers {
            try requireIdentifier(identifier)
            guard seen.insert(identifier).inserted else {
                throw AgentPluginPackageError.duplicateContribution(identifier)
            }
        }
    }

    private static func requireIdentifier(_ identifier: String) throws {
        guard isSafeIdentifier(identifier) else {
            throw AgentPluginPackageError.invalidIdentifier(identifier)
        }
    }

    private static func requireLocalizationKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else {
            throw AgentPluginPackageError.invalidContribution("invalid localization key \(key)")
        }
    }

    static func isSafeIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 160,
              isSafePathComponent(trimmed),
              let first = trimmed.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func isSafePathComponent(_ value: String) -> Bool {
        value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\0")
    }

    static func canonicalFileURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        guard let pointer = realpath(standardized.path, nil) else {
            return standardized.resolvingSymlinksInPath()
        }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: standardized.hasDirectoryPath)
    }

    private static func packageDigest(_ root: URL) throws -> String {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw AgentPluginPackageError.unreadableManifest(root.path)
        }
        var files: [(relativePath: String, url: URL)] = []
        var totalBytes: Int64 = 0
        for case let url as URL in enumerator {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if relative == ".git" || relative.hasPrefix(".git/") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true || values.isSymbolicLink == true {
                let safeURL = try safeResourceURL(relativePath: relative, packageURL: root)
                let safeValues = try safeURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard safeValues.isRegularFile == true else {
                    throw AgentPluginPackageError.unreadableManifest(relative)
                }
                let fileBytes = Int64(safeValues.fileSize ?? 0)
                guard fileBytes <= maximumPackageFileBytes else {
                    throw AgentPluginPackageError.oversizedManifest(relative)
                }
                totalBytes += fileBytes
                guard totalBytes <= maximumPackageBytes else {
                    throw AgentPluginPackageError.oversizedManifest(root.path)
                }
                files.append((relativePath: relative, url: safeURL))
                guard files.count <= maximumPackageFiles else {
                    throw AgentPluginPackageError.oversizedManifest(root.path)
                }
            }
        }
        files.sort { $0.relativePath < $1.relativePath }
        var hasher = SHA256()
        for file in files {
            hasher.update(data: Data(file.relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: file.url))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum AgentPluginDiscovery {
    struct Root: Sendable {
        let url: URL
        let source: AgentPluginPackageSource
        let maximumDepth: Int
    }

    static func discover(
        roots: [Root],
        currentWillDeepVersion: String
    ) -> (packages: [AgentPluginPackage], issues: [String]) {
        var packageRoots: [(URL, AgentPluginPackageSource)] = []
        let manager = FileManager.default
        for root in roots where manager.fileExists(atPath: root.url.path) {
            collectPackages(
                at: root.url,
                source: root.source,
                depth: 0,
                maximumDepth: root.maximumDepth,
                into: &packageRoots
            )
        }

        var packages: [AgentPluginPackage] = []
        var issues: [String] = []
        var seen: Set<String> = []
        for (root, source) in packageRoots.sorted(by: { $0.0.path < $1.0.path }) {
            let path = root.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            do {
                packages.append(try AgentPluginPackageLoader.load(
                    packageURL: root,
                    source: source,
                    currentWillDeepVersion: currentWillDeepVersion
                ))
            } catch {
                issues.append("\(root.path): \(error.localizedDescription)")
            }
        }
        return (packages, issues)
    }

    private static func collectPackages(
        at url: URL,
        source: AgentPluginPackageSource,
        depth: Int,
        maximumDepth: Int,
        into results: inout [(URL, AgentPluginPackageSource)]
    ) {
        let manager = FileManager.default
        let manifest = url.appendingPathComponent(".codex-plugin/plugin.json")
        if manager.fileExists(atPath: manifest.path) {
            results.append((url, source))
            return
        }
        guard depth < maximumDepth,
              let children = try? manager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else { return }
        for child in children {
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            collectPackages(
                at: child,
                source: source,
                depth: depth + 1,
                maximumDepth: maximumDepth,
                into: &results
            )
        }
    }
}
