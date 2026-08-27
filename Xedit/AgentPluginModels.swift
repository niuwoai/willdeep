//
//  AgentPluginModels.swift
//  WillDeep
//
//  Public data contracts for Codex-compatible WillDeep plugins. Third-party
//  packages contribute declarative destinations; native Swift code remains a
//  compile-time-only extension point for WillDeep itself.
//

import Foundation

typealias AgentPluginID = String
typealias AgentPluginDestinationID = String
typealias AgentPluginPageID = String
typealias AgentPluginSidebarID = String
typealias AgentPluginCommandID = String

nonisolated enum AgentPluginPackageSource: String, Codable, Sendable {
    case installed
    case codexCache
    case bundled
    case draft
}

nonisolated struct AgentCodexPluginInterface: Codable, Equatable, Sendable {
    var displayName: String?
    var shortDescription: String?
    var logo: String?
    var composerIcon: String?
}

nonisolated struct AgentCodexPluginManifest: Codable, Equatable, Sendable {
    var name: String
    var version: String
    var description: String?
    var skills: String?
    var apps: String?
    var interface: AgentCodexPluginInterface?
}

nonisolated struct AgentPluginPermission: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let conversationRead = Self(rawValue: "conversation.read")
    static let workspaceRead = Self(rawValue: "workspace.read")
    static let workspaceWrite = Self(rawValue: "workspace.write")
    static let processExecute = Self(rawValue: "process.execute")
    static let networkAccess = Self(rawValue: "network.access")
    static let credentialUse = Self(rawValue: "credentials.use")
    static let clipboardWrite = Self(rawValue: "clipboard.write")
    static let notifications = Self(rawValue: "notifications")
}

nonisolated enum AgentPluginSidebarMode: String, Codable, Sendable {
    case sessionList
    case declarative
    case none
}

nonisolated enum AgentPluginPageRuntime: String, Codable, Sendable {
    case localWeb
    case mcpApp
    case declarative
}

nonisolated struct AgentPluginMCPResourceDescriptor: Codable, Equatable, Sendable {
    var type: String?
    var server: String
    var uri: String
}

nonisolated struct AgentPluginNavigationDescriptor: Codable, Equatable, Sendable {
    var titleKey: String
    var icon: String?
}

nonisolated struct AgentPluginDestinationContribution: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var titleKey: String
    var icon: String?
    var mainPage: String
    var companionSidebar: String?
    var toolbarCommandIDs: [String]
    var defaultPinned: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case titleKey
        case icon
        case mainPage
        case companionSidebar
        case toolbarCommandIDs
        case defaultPinned
    }

    init(
        id: String,
        titleKey: String,
        icon: String? = nil,
        mainPage: String,
        companionSidebar: String? = nil,
        toolbarCommandIDs: [String] = [],
        defaultPinned: Bool = false
    ) {
        self.id = id
        self.titleKey = titleKey
        self.icon = icon
        self.mainPage = mainPage
        self.companionSidebar = companionSidebar
        self.toolbarCommandIDs = toolbarCommandIDs
        self.defaultPinned = defaultPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        titleKey = try container.decode(String.self, forKey: .titleKey)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        mainPage = try container.decode(String.self, forKey: .mainPage)
        companionSidebar = try container.decodeIfPresent(String.self, forKey: .companionSidebar)
        toolbarCommandIDs = try container.decodeIfPresent([String].self, forKey: .toolbarCommandIDs) ?? []
        defaultPinned = try container.decodeIfPresent(Bool.self, forKey: .defaultPinned) ?? false
    }
}

nonisolated struct AgentPluginSidebarContribution: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var mode: AgentPluginSidebarMode
    var schema: String?
    var resource: AgentPluginMCPResourceDescriptor?

    enum CodingKeys: String, CodingKey {
        case id
        case mode
        case schema
        case resource
    }

    init(
        id: String,
        mode: AgentPluginSidebarMode = .sessionList,
        schema: String? = nil,
        resource: AgentPluginMCPResourceDescriptor? = nil
    ) {
        self.id = id
        self.mode = mode
        self.schema = schema
        self.resource = resource
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        mode = try container.decodeIfPresent(AgentPluginSidebarMode.self, forKey: .mode) ?? .sessionList
        schema = try container.decodeIfPresent(String.self, forKey: .schema)
        resource = try container.decodeIfPresent(AgentPluginMCPResourceDescriptor.self, forKey: .resource)
    }
}

nonisolated struct AgentPluginPageContribution: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var runtime: AgentPluginPageRuntime
    var entryPath: String?
    var schema: String?
    var server: String?
    var resourceURI: String?

    enum CodingKeys: String, CodingKey {
        case id
        case runtime
        case entryPath
        case schema
        case server
        case resourceURI
    }

    init(
        id: String,
        runtime: AgentPluginPageRuntime,
        entryPath: String? = nil,
        schema: String? = nil,
        server: String? = nil,
        resourceURI: String? = nil
    ) {
        self.id = id
        self.runtime = runtime
        self.entryPath = entryPath
        self.schema = schema
        self.server = server
        self.resourceURI = resourceURI
    }
}

nonisolated enum AgentPluginCommandHandlerType: String, Codable, Sendable {
    case host
    case mcpTool
    case navigate
}

nonisolated struct AgentPluginCommandHandler: Codable, Equatable, Sendable {
    var type: AgentPluginCommandHandlerType
    var action: String?
    var server: String?
    var tool: String?
    var destination: String?
}

nonisolated struct AgentPluginCommandContribution: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var titleKey: String
    var icon: String?
    var handler: AgentPluginCommandHandler
}

/// `contributes.menus` 支持的挂载位置（与 docs/plugin-schema 的枚举一一对应）。
nonisolated enum AgentPluginMenuLocation {
    static let commandPalette = "commandPalette"
    static let sessionContext = "session.context"
    static let composerMore = "composer.more"
    static let pageToolbar = "plugin.page.toolbar"
    static let sidebarRowContext = "plugin.sidebar.row.context"
    /// 聊天正文选中文字后的气泡与右键菜单：插件在这里加自己的动作，
    /// 被点中时命令会收到 `text`（选中的原文）与 `source` 两个参数。
    static let chatSelection = "chat.selection"

    static let all: [String] = [
        commandPalette, sessionContext, composerMore, pageToolbar, sidebarRowContext, chatSelection,
    ]
}

nonisolated struct AgentPluginResolvedCommand: Identifiable, Sendable {
    var id: String { "\(pluginID):\(command.id)" }
    let pluginID: AgentPluginID
    let command: AgentPluginCommandContribution
}

nonisolated enum AgentPluginSettingType: String, Codable, Sendable {
    case string
    case number
    case boolean
    case enumeration = "enum"
    case secret
}

nonisolated struct AgentPluginSettingContribution: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var type: AgentPluginSettingType
    var titleKey: String
    var descriptionKey: String?
    var defaultValue: String?
    var options: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case titleKey
        case descriptionKey
        case defaultValue
        case options
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(AgentPluginSettingType.self, forKey: .type)
        titleKey = try container.decode(String.self, forKey: .titleKey)
        descriptionKey = try container.decodeIfPresent(String.self, forKey: .descriptionKey)
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
        options = try container.decodeIfPresent([String].self, forKey: .options) ?? []
    }
}

nonisolated struct AgentPluginContributions: Codable, Equatable, Sendable {
    var destinations: [AgentPluginDestinationContribution]
    var sidebars: [AgentPluginSidebarContribution]
    var pages: [AgentPluginPageContribution]
    var commands: [AgentPluginCommandContribution]
    var menus: [String: [String]]
    var settings: [AgentPluginSettingContribution]

    enum CodingKeys: String, CodingKey {
        case destinations
        case sidebars
        case pages
        case commands
        case menus
        case settings
    }

    init(
        destinations: [AgentPluginDestinationContribution] = [],
        sidebars: [AgentPluginSidebarContribution] = [],
        pages: [AgentPluginPageContribution] = [],
        commands: [AgentPluginCommandContribution] = [],
        menus: [String: [String]] = [:],
        settings: [AgentPluginSettingContribution] = []
    ) {
        self.destinations = destinations
        self.sidebars = sidebars
        self.pages = pages
        self.commands = commands
        self.menus = menus
        self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        destinations = try container.decodeIfPresent([AgentPluginDestinationContribution].self, forKey: .destinations) ?? []
        sidebars = try container.decodeIfPresent([AgentPluginSidebarContribution].self, forKey: .sidebars) ?? []
        pages = try container.decodeIfPresent([AgentPluginPageContribution].self, forKey: .pages) ?? []
        commands = try container.decodeIfPresent([AgentPluginCommandContribution].self, forKey: .commands) ?? []
        menus = try container.decodeIfPresent([String: [String]].self, forKey: .menus) ?? [:]
        settings = try container.decodeIfPresent([AgentPluginSettingContribution].self, forKey: .settings) ?? []
    }
}

nonisolated struct AgentPluginDependencies: Codable, Equatable, Sendable {
    var mcpServers: [String]
    var skills: [String]

    enum CodingKeys: String, CodingKey {
        case mcpServers
        case skills
    }

    init(mcpServers: [String] = [], skills: [String] = []) {
        self.mcpServers = mcpServers
        self.skills = skills
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mcpServers = try container.decodeIfPresent([String].self, forKey: .mcpServers) ?? []
        skills = try container.decodeIfPresent([String].self, forKey: .skills) ?? []
    }
}

nonisolated struct AgentPluginManifest: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var minimumWillDeepVersion: String?
    var contributes: AgentPluginContributions
    var permissions: [AgentPluginPermission]
    var dependencies: AgentPluginDependencies

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case minimumWillDeepVersion
        case contributes
        case permissions
        case dependencies
    }

    init(
        schemaVersion: Int = 1,
        minimumWillDeepVersion: String? = nil,
        contributes: AgentPluginContributions = .init(),
        permissions: [AgentPluginPermission] = [],
        dependencies: AgentPluginDependencies = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.minimumWillDeepVersion = minimumWillDeepVersion
        self.contributes = contributes
        self.permissions = permissions
        self.dependencies = dependencies
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        minimumWillDeepVersion = try container.decodeIfPresent(String.self, forKey: .minimumWillDeepVersion)
        contributes = try container.decodeIfPresent(AgentPluginContributions.self, forKey: .contributes) ?? .init()
        permissions = try container.decodeIfPresent([AgentPluginPermission].self, forKey: .permissions) ?? []
        dependencies = try container.decodeIfPresent(AgentPluginDependencies.self, forKey: .dependencies) ?? .init()
    }
}

nonisolated enum AgentPluginSidebarComponentKind: String, Codable, Sendable {
    case section
    case list
    case row
    case label
    case icon
    case badge
    case status
    case progress
    case button
    case disclosure
    case separator
    case emptyState
    case loadingState
    case errorState
}

nonisolated struct AgentPluginSidebarComponent: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: AgentPluginSidebarComponentKind
    var titleKey: String?
    var subtitleKey: String?
    var systemImage: String?
    var value: String?
    var progress: Double?
    var command: String?
    var contextCommands: [String]
    var arguments: [String: String]
    var children: [AgentPluginSidebarComponent]

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case titleKey
        case subtitleKey
        case systemImage
        case value
        case progress
        case command
        case contextCommands
        case arguments
        case children
    }

    init(
        id: String,
        kind: AgentPluginSidebarComponentKind,
        titleKey: String? = nil,
        subtitleKey: String? = nil,
        systemImage: String? = nil,
        value: String? = nil,
        progress: Double? = nil,
        command: String? = nil,
        contextCommands: [String] = [],
        arguments: [String: String] = [:],
        children: [AgentPluginSidebarComponent] = []
    ) {
        self.id = id
        self.kind = kind
        self.titleKey = titleKey
        self.subtitleKey = subtitleKey
        self.systemImage = systemImage
        self.value = value
        self.progress = progress
        self.command = command
        self.contextCommands = contextCommands
        self.arguments = arguments
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(AgentPluginSidebarComponentKind.self, forKey: .kind)
        titleKey = try container.decodeIfPresent(String.self, forKey: .titleKey)
        subtitleKey = try container.decodeIfPresent(String.self, forKey: .subtitleKey)
        systemImage = try container.decodeIfPresent(String.self, forKey: .systemImage)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        progress = try container.decodeIfPresent(Double.self, forKey: .progress)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        contextCommands = try container.decodeIfPresent([String].self, forKey: .contextCommands) ?? []
        arguments = try container.decodeIfPresent([String: String].self, forKey: .arguments) ?? [:]
        children = try container.decodeIfPresent([AgentPluginSidebarComponent].self, forKey: .children) ?? []
    }
}

nonisolated struct AgentPluginSidebarDocument: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var components: [AgentPluginSidebarComponent]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case components
    }

    init(schemaVersion: Int = 1, components: [AgentPluginSidebarComponent]) {
        self.schemaVersion = schemaVersion
        self.components = components
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        components = try container.decodeIfPresent([AgentPluginSidebarComponent].self, forKey: .components) ?? []
    }
}

nonisolated struct AgentPluginDestinationDescriptor: Equatable, Identifiable, Sendable {
    var id: String { qualifiedID }
    let qualifiedID: String
    let pluginID: AgentPluginID
    let packageURL: URL
    let navigation: AgentPluginNavigationDescriptor
    let companionSidebar: AgentPluginSidebarContribution
    let mainPage: AgentPluginPageContribution
    let toolbarCommandIDs: [AgentPluginCommandID]
    let defaultPinned: Bool
}

nonisolated struct AgentPluginPackage: Equatable, Identifiable, Sendable {
    var id: String { "\(pluginID)@\(version)" }
    let pluginID: AgentPluginID
    let version: String
    let displayName: String
    let summary: String
    let packageURL: URL
    let source: AgentPluginPackageSource
    let digest: String
    let codexManifest: AgentCodexPluginManifest
    let manifest: AgentPluginManifest?
    let destinations: [AgentPluginDestinationDescriptor]
}

nonisolated struct AgentPluginRecord: Identifiable, Equatable, Sendable {
    var id: String { pluginID }
    let pluginID: AgentPluginID
    let activePackage: AgentPluginPackage
    let availableVersions: [AgentPluginPackage]
    let isEnabled: Bool
    let isApproved: Bool
    let validationMessage: String?
}

nonisolated enum AgentPluginInstallSourceKind: String, Codable, Sendable {
    case local
    case archive
    case git
}

/// Persisted provenance for an installed package. Approval is bound to both
/// the package digest and this source fingerprint so moving identical bytes to
/// a different origin cannot silently inherit trust.
nonisolated struct AgentPluginInstallSourceRecord: Codable, Equatable, Sendable {
    let kind: AgentPluginInstallSourceKind
    let location: String
    let reference: String?

    var fingerprint: String {
        [kind.rawValue, location, reference ?? ""].joined(separator: "\u{1f}")
    }
}

nonisolated struct AgentPluginRegistrySnapshot: Equatable, Sendable {
    var records: [AgentPluginRecord]
    var activeDestinations: [AgentPluginDestinationDescriptor]
    var pinnedDestinationIDs: [AgentPluginDestinationID]
    var issues: [String]

    static let empty = AgentPluginRegistrySnapshot(
        records: [],
        activeDestinations: [],
        pinnedDestinationIDs: [],
        issues: []
    )

    var pinnedDestinations: [AgentPluginDestinationDescriptor] {
        let byID = Dictionary(uniqueKeysWithValues: activeDestinations.map { ($0.qualifiedID, $0) })
        return pinnedDestinationIDs.compactMap { byID[$0] }
    }
}

nonisolated struct AgentPluginRegistryState: Codable, Equatable, Sendable {
    var activeVersions: [String: String]
    var disabledPluginIDs: [String]
    var approvedDigests: [String]
    var approvedInstallations: [String]
    var installSources: [String: AgentPluginInstallSourceRecord]
    var pinnedDestinationIDs: [String]

    enum CodingKeys: String, CodingKey {
        case activeVersions
        case disabledPluginIDs
        case approvedDigests
        case approvedInstallations
        case installSources
        case pinnedDestinationIDs
    }

    init(
        activeVersions: [String: String],
        disabledPluginIDs: [String],
        approvedDigests: [String],
        approvedInstallations: [String] = [],
        installSources: [String: AgentPluginInstallSourceRecord] = [:],
        pinnedDestinationIDs: [String]
    ) {
        self.activeVersions = activeVersions
        self.disabledPluginIDs = disabledPluginIDs
        self.approvedDigests = approvedDigests
        self.approvedInstallations = approvedInstallations
        self.installSources = installSources
        self.pinnedDestinationIDs = pinnedDestinationIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeVersions = try container.decodeIfPresent([String: String].self, forKey: .activeVersions) ?? [:]
        disabledPluginIDs = try container.decodeIfPresent([String].self, forKey: .disabledPluginIDs) ?? []
        approvedDigests = try container.decodeIfPresent([String].self, forKey: .approvedDigests) ?? []
        approvedInstallations = try container.decodeIfPresent([String].self, forKey: .approvedInstallations) ?? []
        installSources = try container.decodeIfPresent(
            [String: AgentPluginInstallSourceRecord].self,
            forKey: .installSources
        ) ?? [:]
        pinnedDestinationIDs = try container.decodeIfPresent([String].self, forKey: .pinnedDestinationIDs) ?? []
    }

    static let empty = AgentPluginRegistryState(
        activeVersions: [:],
        disabledPluginIDs: [],
        approvedDigests: [],
        approvedInstallations: [],
        installSources: [:],
        pinnedDestinationIDs: []
    )
}

nonisolated struct AgentPluginDestinationContext: Codable, Equatable, Sendable {
    let destinationID: AgentPluginDestinationID
    let selectedItemID: String?
    let workspaceReference: String?
    let sessionReference: String?
    let locale: String
    let colorScheme: String
}
