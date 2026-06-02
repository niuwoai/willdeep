//
//  AgentModels.swift
//  VeilWriter
//
//  Lightweight models for the built-in project agent.
//

import Foundation

enum AppMode: String, Codable {
    case editor
    case agent
}

enum AgentRole: String, Codable {
    case system
    case user
    case assistant
    case tool
}

/// A user-attached image, encoded inline so it round-trips through session
/// JSON without a separate blob store. `dataBase64` is the raw image bytes
/// base64-encoded (no `data:` prefix); `mimeType` is e.g. `image/png`.
struct AgentImageAttachment: Codable, Equatable, Identifiable {
    let id: UUID
    let mimeType: String
    let dataBase64: String

    init(id: UUID = UUID(), mimeType: String, dataBase64: String) {
        self.id = id
        self.mimeType = mimeType
        self.dataBase64 = dataBase64
    }

    nonisolated var dataURL: String {
        "data:\(mimeType);base64,\(dataBase64)"
    }
}

/// Tool call emitted by the assistant in an OpenAI function-calling response.
/// `argumentsJSON` is the raw JSON text the model produced (it may stream in
/// fragments and only be valid JSON once complete).
struct AgentMessageToolCall: Codable, Equatable {
    var externalID: String
    var toolName: String
    var argumentsJSON: String
}

struct AgentMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: AgentRole
    var content: String
    /// User-attached images, only meaningful for `role == .user`.
    var images: [AgentImageAttachment]
    var toolCalls: [AgentMessageToolCall]
    /// When `role == .tool`, the external id of the assistant tool_call this
    /// message answers.
    var toolCallID: String?
    let createdAt: Date

    nonisolated init(
        id: UUID = UUID(),
        role: AgentRole,
        content: String,
        images: [AgentImageAttachment] = [],
        toolCalls: [AgentMessageToolCall] = [],
        toolCallID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.images = images
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(AgentRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        images = try container.decodeIfPresent([AgentImageAttachment].self, forKey: .images) ?? []
        toolCalls = try container.decodeIfPresent([AgentMessageToolCall].self, forKey: .toolCalls) ?? []
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

/// A message the user queued while the agent was busy. Consumed FIFO
/// once the current response completes (or is stopped).
struct AgentQueuedMessage: Identifiable, Equatable {
    let id: UUID
    var text: String
    var images: [AgentImageAttachment]

    init(id: UUID = UUID(), text: String, images: [AgentImageAttachment] = []) {
        self.id = id
        self.text = text
        self.images = images
    }
}

/// A persisted Agent conversation. Lives as one JSON file under the app's
/// Application Support directory. `workspaceRootPath` is used to group
/// sessions by project in the Agent-mode sidebar.
struct AgentSession: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    /// Optional — sessions started before a folder was picked have no root.
    var workspaceRootPath: String?
    /// Model id captured at the time the session was last sent (so changing
    /// the global model later doesn't silently switch what an old chat used).
    var modelID: String?
    let createdAt: Date
    var updatedAt: Date
    var messages: [AgentMessage]

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        workspaceRootPath: String? = nil,
        modelID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [AgentMessage] = []
    ) {
        self.id = id
        self.title = title
        self.workspaceRootPath = workspaceRootPath
        self.modelID = modelID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    var workspaceName: String {
        guard let path = workspaceRootPath, !path.isEmpty else { return "No workspace" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

enum AgentModelRoutingMode: String, Codable, CaseIterable, Identifiable {
    case auto
    case flash
    case pro

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .flash: return "Flash"
        case .pro: return "Pro"
        }
    }

    var description: String {
        switch self {
        case .auto:
            return "Cost-first routing. Agent turns and compression use Flash unless a session override is selected."
        case .flash:
            return "Always use the lower-cost model slot."
        case .pro:
            return "Always use the stronger model slot."
        }
    }
}

enum AgentModelPurpose {
    case interactive
    case compression
}

struct AgentImageDescriptionConfiguration: Codable, Equatable {
    var providerID: String
    var baseURL: String
    var model: String
    var apiKey: String

    static let `default` = AgentImageDescriptionConfiguration(
        providerID: "dashscope",
        baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
        model: "qwen3-vl-plus",
        apiKey: ""
    )

    init(providerID: String, baseURL: String, model: String, apiKey: String) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID) ?? Self.default.providerID
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? Self.default.baseURL
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.default.model
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    }

    var normalized: AgentImageDescriptionConfiguration {
        var result = self
        result.providerID = result.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        result.baseURL = result.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        result.model = result.model.trimmingCharacters(in: .whitespacesAndNewlines)
        result.apiKey = result.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let preset = AgentProviderPreset.preset(id: result.providerID)
        if preset == nil {
            result.providerID = AgentProviderPreset.customID
        }
        if result.baseURL.isEmpty {
            result.baseURL = Self.default.baseURL
        }
        if result.model.isEmpty {
            result.model = Self.default.model
        }
        return result
    }

    var agentConfiguration: AgentConfiguration {
        AgentConfiguration(
            providerID: providerID,
            baseURL: baseURL,
            model: model,
            flashModel: model,
            proModel: model,
            routingMode: .flash,
            imageDescription: self,
            apiKey: apiKey
        ).normalized
    }
}

struct AgentConfiguration: Codable, Equatable {
    var providerID: String
    var baseURL: String
    /// Legacy/current resolved model field. Older settings only stored this.
    var model: String
    var flashModel: String
    var proModel: String
    var routingMode: AgentModelRoutingMode
    var imageDescription: AgentImageDescriptionConfiguration
    var apiKey: String

    static let `default` = AgentConfiguration(
        providerID: AgentProviderPreset.openAIID,
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4.1-mini",
        flashModel: "gpt-4.1-mini",
        proModel: "gpt-4.1",
        routingMode: .auto,
        imageDescription: .default,
        apiKey: ""
    )

    init(
        providerID: String,
        baseURL: String,
        model: String,
        flashModel: String? = nil,
        proModel: String? = nil,
        routingMode: AgentModelRoutingMode = .auto,
        imageDescription: AgentImageDescriptionConfiguration = .default,
        apiKey: String
    ) {
        self.providerID = providerID
        self.baseURL = baseURL
        self.model = model
        self.flashModel = flashModel ?? model
        self.proModel = proModel ?? model
        self.routingMode = routingMode
        self.imageDescription = imageDescription
        self.apiKey = apiKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID) ?? AgentProviderPreset.openAIID
        baseURL = try container.decode(String.self, forKey: .baseURL)
        let legacyModel = try container.decodeIfPresent(String.self, forKey: .model) ?? AgentConfiguration.default.model
        model = legacyModel
        flashModel = try container.decodeIfPresent(String.self, forKey: .flashModel) ?? legacyModel
        proModel = try container.decodeIfPresent(String.self, forKey: .proModel) ?? legacyModel
        routingMode = try container.decodeIfPresent(AgentModelRoutingMode.self, forKey: .routingMode) ?? .auto
        imageDescription = try container.decodeIfPresent(AgentImageDescriptionConfiguration.self, forKey: .imageDescription) ?? .default
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    }

    var normalized: AgentConfiguration {
        var result = self
        result.providerID = result.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        result.baseURL = result.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        result.model = result.model.trimmingCharacters(in: .whitespacesAndNewlines)
        result.flashModel = result.flashModel.trimmingCharacters(in: .whitespacesAndNewlines)
        result.proModel = result.proModel.trimmingCharacters(in: .whitespacesAndNewlines)
        result.imageDescription = result.imageDescription.normalized
        result.apiKey = result.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let preset = AgentProviderPreset.preset(id: result.providerID)
        if preset == nil {
            result.providerID = AgentProviderPreset.customID
        }
        if result.baseURL.isEmpty {
            result.baseURL = AgentConfiguration.default.baseURL
        }
        if result.flashModel.isEmpty {
            result.flashModel = preset?.defaultFlashModel ?? result.model
        }
        if result.proModel.isEmpty {
            result.proModel = preset?.defaultProModel ?? result.model
        }
        if result.flashModel.isEmpty {
            result.flashModel = AgentConfiguration.default.flashModel
        }
        if result.proModel.isEmpty {
            result.proModel = AgentConfiguration.default.proModel
        }
        if result.model.isEmpty {
            result.model = result.model(for: .interactive)
        }
        return result
    }

    func model(for purpose: AgentModelPurpose) -> String {
        switch purpose {
        case .compression:
            return flashModel
        case .interactive:
            switch routingMode {
            case .auto, .flash:
                return flashModel
            case .pro:
                return proModel
            }
        }
    }

    func resolved(for purpose: AgentModelPurpose) -> AgentConfiguration {
        var result = normalized
        result.model = result.model(for: purpose)
        return result
    }

    var routingLabel: String {
        "\(routingMode.displayName) · \(model(for: .interactive))"
    }

    var supportsImageInput: Bool {
        AgentProviderPreset.preset(id: providerID)?.supportsImageInput ?? true
    }
}

struct AgentProviderPreset: Identifiable, Equatable {
    let id: String
    let displayName: String
    let baseURL: String
    let defaultFlashModel: String
    let defaultProModel: String
    let supportsModelFetch: Bool
    let supportsImageInput: Bool

    static let openAIID = "openai"
    static let customID = "custom"

    var defaultModel: String { defaultFlashModel }
    var defaultVisionModel: String {
        if id == "dashscope" {
            return "qwen3-vl-plus"
        }
        if id == Self.customID {
            return ""
        }
        return defaultFlashModel
    }

    init(
        id: String,
        displayName: String,
        baseURL: String,
        defaultModel: String,
        defaultFlashModel: String? = nil,
        defaultProModel: String? = nil,
        supportsModelFetch: Bool,
        supportsImageInput: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.defaultFlashModel = defaultFlashModel ?? defaultModel
        self.defaultProModel = defaultProModel ?? defaultModel
        self.supportsModelFetch = supportsModelFetch
        self.supportsImageInput = supportsImageInput
    }

    static let all: [AgentProviderPreset] = [
        AgentProviderPreset(
            id: openAIID,
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-4.1-mini",
            defaultProModel: "gpt-4.1",
            supportsModelFetch: true
        ),
        AgentProviderPreset(
            id: "dashscope",
            displayName: "DashScope",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            defaultModel: "qwen-plus",
            defaultProModel: "qwen-max",
            supportsModelFetch: true
        ),
        AgentProviderPreset(
            id: "deepseek",
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            defaultModel: "deepseek-v4-flash",
            defaultProModel: "deepseek-v4-pro",
            supportsModelFetch: true,
            supportsImageInput: false
        ),
        AgentProviderPreset(
            id: "kimi",
            displayName: "Kimi",
            baseURL: "https://api.moonshot.cn/v1",
            defaultModel: "kimi-k2.5",
            supportsModelFetch: true
        ),
        AgentProviderPreset(
            id: "moonshot",
            displayName: "Moonshot",
            baseURL: "https://api.moonshot.cn/v1",
            defaultModel: "moonshot-v1-8k",
            supportsModelFetch: true
        ),
        AgentProviderPreset(
            id: "claude",
            displayName: "Claude",
            baseURL: "https://api.anthropic.com/v1",
            defaultModel: "claude-sonnet-4-5",
            supportsModelFetch: true
        ),
        AgentProviderPreset(
            id: customID,
            displayName: "Custom",
            baseURL: "",
            defaultModel: "",
            supportsModelFetch: true
        )
    ]

    static func preset(id: String) -> AgentProviderPreset? {
        all.first { $0.id == id }
    }

    static func matchingBaseURL(_ baseURL: String) -> AgentProviderPreset? {
        let normalized = normalizeBaseURL(baseURL)
        return all.first { preset in
            !preset.baseURL.isEmpty && normalizeBaseURL(preset.baseURL) == normalized
        }
    }

    private static func normalizeBaseURL(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t")).lowercased()
    }
}

enum AgentPatchStatus: String, Codable {
    case pending
    case applied
    case rejected
    case failed
}

struct AgentPatchProposal: Identifiable, Codable, Equatable {
    let id: UUID
    let messageID: UUID
    let title: String
    let diff: String
    var status: AgentPatchStatus
    var statusMessage: String?

    init(
        id: UUID = UUID(),
        messageID: UUID,
        title: String,
        diff: String,
        status: AgentPatchStatus = .pending,
        statusMessage: String? = nil
    ) {
        self.id = id
        self.messageID = messageID
        self.title = title
        self.diff = diff
        self.status = status
        self.statusMessage = statusMessage
    }
}

struct AgentLineChangeStats: Equatable {
    var added: Int?
    var deleted: Int?

    nonisolated init(added: Int?, deleted: Int?) {
        self.added = added
        self.deleted = deleted
    }
}

struct AgentFileChangeSummary: Identifiable, Equatable {
    var path: String
    var kind: GitFileStatusKind
    var lineStats: AgentLineChangeStats

    nonisolated var id: String { path }

    nonisolated var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    nonisolated var addedLines: Int {
        lineStats.added ?? 0
    }

    nonisolated var deletedLines: Int {
        lineStats.deleted ?? 0
    }

    nonisolated var hasKnownLineStats: Bool {
        lineStats.added != nil || lineStats.deleted != nil
    }
}

struct AgentWorktreeChangeSummary: Equatable {
    var repositoryRoot: URL?
    var files: [AgentFileChangeSummary]

    nonisolated init(repositoryRoot: URL? = nil, files: [AgentFileChangeSummary] = []) {
        self.repositoryRoot = repositoryRoot
        self.files = files.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    nonisolated var isEmpty: Bool {
        files.isEmpty
    }

    nonisolated var fileCount: Int {
        files.count
    }

    nonisolated var totalAddedLines: Int {
        files.reduce(0) { $0 + $1.addedLines }
    }

    nonisolated var totalDeletedLines: Int {
        files.reduce(0) { $0 + $1.deletedLines }
    }

    nonisolated func change(for relativePath: String) -> AgentFileChangeSummary? {
        files.first { $0.path == relativePath }
    }
}

enum AgentPatchError: LocalizedError {
    case emptyDiff
    case unsupportedDiff
    case noWorkspace
    case pathOutsideWorkspace(String)
    case missingFile(String)
    case hunkDidNotMatch(String)

    var errorDescription: String? {
        switch self {
        case .emptyDiff:
            return "The diff is empty."
        case .unsupportedDiff:
            return "The diff format is not supported yet. Use a unified diff for existing files."
        case .noWorkspace:
            return "Open a project folder before applying an agent patch."
        case .pathOutsideWorkspace(let path):
            return "The patch path is outside the workspace: \(path)"
        case .missingFile(let path):
            return "The patch target file does not exist: \(path)"
        case .hunkDidNotMatch(let path):
            return "A patch hunk did not match the current file content: \(path)"
        }
    }
}

enum AgentClientError: LocalizedError {
    case missingAPIKey
    case invalidBaseURL
    case invalidResponse
    case serverStatus(AgentProviderHTTPError)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an API key in Settings before sending an agent request."
        case .invalidBaseURL:
            return "The agent base URL is invalid."
        case .invalidResponse:
            return "The model provider returned an invalid response."
        case .serverStatus(let error):
            return "The model provider returned HTTP \(error.statusCode)."
        }
    }
}

struct AgentProviderHTTPError: Equatable {
    let statusCode: Int
    let method: String
    let url: String
    let providerID: String
    let model: String
    let requestSummary: String
    let requestBody: String
    let responseBody: String
}

struct AgentErrorDetails: Equatable, Identifiable {
    let id = UUID()
    let sections: [Section]

    struct Section: Equatable, Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }
}
