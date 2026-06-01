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

struct AgentConfiguration: Codable, Equatable {
    var providerID: String
    var baseURL: String
    var model: String
    var apiKey: String

    static let `default` = AgentConfiguration(
        providerID: AgentProviderPreset.openAIID,
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4.1",
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
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID) ?? AgentProviderPreset.openAIID
        baseURL = try container.decode(String.self, forKey: .baseURL)
        model = try container.decode(String.self, forKey: .model)
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    }

    var normalized: AgentConfiguration {
        var result = self
        result.providerID = result.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        result.baseURL = result.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        result.model = result.model.trimmingCharacters(in: .whitespacesAndNewlines)
        result.apiKey = result.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if AgentProviderPreset.preset(id: result.providerID) == nil {
            result.providerID = AgentProviderPreset.customID
        }
        if result.baseURL.isEmpty {
            result.baseURL = AgentConfiguration.default.baseURL
        }
        if result.model.isEmpty {
            result.model = AgentConfiguration.default.model
        }
        return result
    }
}

struct AgentProviderPreset: Identifiable, Equatable {
    let id: String
    let displayName: String
    let baseURL: String
    let defaultModel: String
    let supportsModelFetch: Bool

    static let openAIID = "openai"
    static let customID = "custom"

    static let all: [AgentProviderPreset] = [
        AgentProviderPreset(
            id: openAIID,
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-4.1",
            supportsModelFetch: true
        ),
        AgentProviderPreset(
            id: "dashscope",
            displayName: "DashScope",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            defaultModel: "qwen-plus",
            supportsModelFetch: true
        ),
        AgentProviderPreset(
            id: "deepseek",
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            defaultModel: "deepseek-chat",
            supportsModelFetch: true
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
    case serverStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an API key in Settings before sending an agent request."
        case .invalidBaseURL:
            return "The agent base URL is invalid."
        case .invalidResponse:
            return "The model provider returned an invalid response."
        case .serverStatus(let statusCode):
            return "The model provider returned HTTP \(statusCode)."
        }
    }
}
