//
//  CollaborationConnectorModels.swift
//  WillDeep
//
//  Local settings for team collaboration connectors such as Feishu,
//  DingTalk, WeCom, and desktop automation bridges.
//

import Foundation
import SwiftUI

enum CollaborationConnectorPlatform: String, Codable, CaseIterable, Identifiable {
    case feishu
    case dingtalk
    case wecom
    case wechatClaw

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .feishu: return L10n.Settings.Connectors.platformFeishu
        case .dingtalk: return L10n.Settings.Connectors.platformDingTalk
        case .wecom: return L10n.Settings.Connectors.platformWeCom
        case .wechatClaw: return L10n.Settings.Connectors.platformWechatClaw
        }
    }

    var summary: String {
        switch self {
        case .feishu: return L10n.Settings.Connectors.summaryFeishu
        case .dingtalk: return L10n.Settings.Connectors.summaryDingTalk
        case .wecom: return L10n.Settings.Connectors.summaryWeCom
        case .wechatClaw: return L10n.Settings.Connectors.summaryWechatClaw
        }
    }

    var systemImageName: String {
        switch self {
        case .feishu: return "doc.richtext"
        case .dingtalk: return "bell.badge"
        case .wecom: return "building.2"
        case .wechatClaw: return "cursorarrow.motionlines"
        }
    }

    var tint: Color {
        switch self {
        case .feishu: return .blue
        case .dingtalk: return .cyan
        case .wecom: return .green
        case .wechatClaw: return .orange
        }
    }

    var documentationURL: URL? {
        switch self {
        case .feishu:
            return URL(string: "https://open.feishu.cn/document/home/index")
        case .dingtalk:
            return URL(string: "https://open.dingtalk.com/document/")
        case .wecom:
            return URL(string: "https://developer.work.weixin.qq.com/")
        case .wechatClaw:
            return nil
        }
    }

    var defaultAuthMode: CollaborationConnectorAuthMode {
        switch self {
        case .feishu:
            return .officialLarkCLI
        case .dingtalk:
            return .officialMCP
        case .wecom:
            return .oauth
        case .wechatClaw:
            return .desktopAutomation
        }
    }

    var defaultCapabilities: [CollaborationConnectorCapability] {
        switch self {
        case .feishu:
            return [.sendMessages, .receiveCommands, .createDocs, .editDocs, .importDocs]
        case .dingtalk:
            return [.sendMessages, .receiveCommands, .approvals]
        case .wecom:
            return [.sendMessages, .receiveCommands]
        case .wechatClaw:
            return [.desktopAutomation]
        }
    }

    var isExperimental: Bool {
        self == .wechatClaw
    }
}

enum CollaborationConnectorAuthMode: String, Codable, CaseIterable, Identifiable {
    case officialLarkCLI
    case officialMCP
    case webhook
    case oauth
    case cloudRelay
    case desktopAutomation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .officialLarkCLI: return L10n.Settings.Connectors.authOfficialLarkCLI
        case .officialMCP: return L10n.Settings.Connectors.authOfficialMCP
        case .webhook: return L10n.Settings.Connectors.authWebhook
        case .oauth: return L10n.Settings.Connectors.authOAuth
        case .cloudRelay: return L10n.Settings.Connectors.authCloudRelay
        case .desktopAutomation: return L10n.Settings.Connectors.authDesktopAutomation
        }
    }

    var helpText: String {
        switch self {
        case .officialLarkCLI: return L10n.Settings.Connectors.authOfficialLarkCLIHelp
        case .officialMCP: return L10n.Settings.Connectors.authOfficialMCPHelp
        case .webhook: return L10n.Settings.Connectors.authWebhookHelp
        case .oauth: return L10n.Settings.Connectors.authOAuthHelp
        case .cloudRelay: return L10n.Settings.Connectors.authCloudRelayHelp
        case .desktopAutomation: return L10n.Settings.Connectors.authDesktopAutomationHelp
        }
    }
}

enum CollaborationConnectorConnectionState: String, Codable, CaseIterable, Identifiable {
    case notConfigured
    case ready
    case connected
    case needsReview

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notConfigured: return L10n.Settings.Connectors.stateNotConfigured
        case .ready: return L10n.Settings.Connectors.stateReady
        case .connected: return L10n.Settings.Connectors.stateConnected
        case .needsReview: return L10n.Settings.Connectors.stateNeedsReview
        }
    }
}

enum CollaborationConnectorCapability: String, Codable, CaseIterable, Identifiable {
    case sendMessages
    case receiveCommands
    case createDocs
    case editDocs
    case importDocs
    case calendar
    case tasks
    case approvals
    case desktopAutomation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sendMessages: return L10n.Settings.Connectors.capabilitySendMessages
        case .receiveCommands: return L10n.Settings.Connectors.capabilityReceiveCommands
        case .createDocs: return L10n.Settings.Connectors.capabilityCreateDocs
        case .editDocs: return L10n.Settings.Connectors.capabilityEditDocs
        case .importDocs: return L10n.Settings.Connectors.capabilityImportDocs
        case .calendar: return L10n.Settings.Connectors.capabilityCalendar
        case .tasks: return L10n.Settings.Connectors.capabilityTasks
        case .approvals: return L10n.Settings.Connectors.capabilityApprovals
        case .desktopAutomation: return L10n.Settings.Connectors.capabilityDesktopAutomation
        }
    }

    func isSupported(by platform: CollaborationConnectorPlatform) -> Bool {
        switch self {
        case .sendMessages, .receiveCommands:
            return platform != .wechatClaw
        case .createDocs, .editDocs, .importDocs, .calendar, .tasks:
            return platform == .feishu
        case .approvals:
            return platform == .dingtalk || platform == .wecom
        case .desktopAutomation:
            return platform == .wechatClaw
        }
    }
}

enum CollaborationConnectorWritePolicy: String, Codable, CaseIterable, Identifiable {
    case previewThenPublish
    case askEveryTime
    case allowNewDocs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .previewThenPublish: return L10n.Settings.Connectors.policyPreviewThenPublish
        case .askEveryTime: return L10n.Settings.Connectors.policyAskEveryTime
        case .allowNewDocs: return L10n.Settings.Connectors.policyAllowNewDocs
        }
    }
}

struct CollaborationConnectorConfig: Identifiable, Codable, Equatable {
    var id: String
    var platform: CollaborationConnectorPlatform
    var isEnabled: Bool
    var authMode: CollaborationConnectorAuthMode
    var connectionState: CollaborationConnectorConnectionState
    var appID: String
    var tenantID: String
    var redirectURI: String
    var authorizationURL: String?
    var defaultSpace: String
    var defaultChat: String
    var credentialReference: String
    var enabledCapabilities: [CollaborationConnectorCapability]
    var writePolicy: CollaborationConnectorWritePolicy
    var cloudRelayEnabled: Bool
    var updatedAt: Date

    init(
        platform: CollaborationConnectorPlatform,
        isEnabled: Bool = false,
        authMode: CollaborationConnectorAuthMode? = nil,
        connectionState: CollaborationConnectorConnectionState = .notConfigured,
        appID: String = "",
        tenantID: String = "",
        redirectURI: String = "",
        authorizationURL: String = "",
        defaultSpace: String = "",
        defaultChat: String = "",
        credentialReference: String = "",
        enabledCapabilities: [CollaborationConnectorCapability]? = nil,
        writePolicy: CollaborationConnectorWritePolicy = .previewThenPublish,
        cloudRelayEnabled: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = platform.rawValue
        self.platform = platform
        self.isEnabled = isEnabled
        self.authMode = authMode ?? platform.defaultAuthMode
        self.connectionState = connectionState
        self.appID = appID
        self.tenantID = tenantID
        self.redirectURI = redirectURI
        self.authorizationURL = authorizationURL
        self.defaultSpace = defaultSpace
        self.defaultChat = defaultChat
        self.credentialReference = credentialReference
        self.enabledCapabilities = enabledCapabilities ?? platform.defaultCapabilities
        self.writePolicy = writePolicy
        self.cloudRelayEnabled = cloudRelayEnabled
        self.updatedAt = updatedAt
    }

    var normalized: CollaborationConnectorConfig {
        var copy = self
        copy.id = copy.platform.rawValue
        copy.appID = copy.appID.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.tenantID = copy.tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.redirectURI = copy.redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.authorizationURL = copy.authorizationURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.authorizationURL?.isEmpty == true {
            copy.authorizationURL = nil
        }
        if copy.platform != .feishu && copy.authMode == .officialLarkCLI {
            copy.authMode = copy.platform.defaultAuthMode
        }
        if copy.platform != .dingtalk && copy.authMode == .officialMCP {
            copy.authMode = copy.platform.defaultAuthMode
        }
        copy.defaultSpace = copy.defaultSpace.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.defaultChat = copy.defaultChat.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.credentialReference = copy.credentialReference.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.enabledCapabilities = CollaborationConnectorCapability.allCases.filter {
            copy.enabledCapabilities.contains($0) && $0.isSupported(by: copy.platform)
        }
        if copy.enabledCapabilities.isEmpty {
            copy.enabledCapabilities = copy.platform.defaultCapabilities
        }
        return copy
    }
}

struct CollaborationConnectorSettings: Codable, Equatable {
    var connectors: [CollaborationConnectorConfig]

    static let `default` = CollaborationConnectorSettings(
        connectors: CollaborationConnectorPlatform.allCases.map {
            CollaborationConnectorConfig(platform: $0)
        }
    )

    var normalized: CollaborationConnectorSettings {
        var byPlatform: [CollaborationConnectorPlatform: CollaborationConnectorConfig] = [:]
        for connector in connectors {
            byPlatform[connector.platform] = connector.normalized
        }
        return CollaborationConnectorSettings(
            connectors: CollaborationConnectorPlatform.allCases.map { platform in
                (byPlatform[platform] ?? CollaborationConnectorConfig(platform: platform)).normalized
            }
        )
    }

    func connector(for platform: CollaborationConnectorPlatform) -> CollaborationConnectorConfig {
        normalized.connectors.first { $0.platform == platform } ?? CollaborationConnectorConfig(platform: platform)
    }
}

enum CollaborationConnectorSettingsStore {
    private static let settingsKey = "com.willdeep.collaborationConnectors.settings.v1"
    static let didChangeNotification = Notification.Name("CollaborationConnectorSettingsDidChange")

    static func load(defaults: UserDefaults = .standard) -> CollaborationConnectorSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(CollaborationConnectorSettings.self, from: data) else {
            return .default
        }
        return settings.normalized
    }

    static func save(_ settings: CollaborationConnectorSettings, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings.normalized) else { return }
        defaults.set(data, forKey: settingsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func upsert(_ connector: CollaborationConnectorConfig, defaults: UserDefaults = .standard) {
        var settings = load(defaults: defaults)
        let normalized = connector.normalized
        if let index = settings.connectors.firstIndex(where: { $0.platform == normalized.platform }) {
            settings.connectors[index] = normalized
        } else {
            settings.connectors.append(normalized)
        }
        save(settings.normalized, defaults: defaults)
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: settingsKey)
    }
}
