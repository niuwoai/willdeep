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
    /// Reasoning / thinking-mode trace from providers that emit it
    /// separately (DashScope qwen3, qwq, DeepSeek-R1 family). When set
    /// on an assistant message, we MUST send it back on the next turn
    /// — DashScope returns HTTP 400 otherwise. Empty for providers
    /// that don't split reasoning out.
    var reasoningContent: String?
    /// User-attached images, only meaningful for `role == .user`.
    var images: [AgentImageAttachment]
    var toolCalls: [AgentMessageToolCall]
    /// When `role == .tool`, the external id of the assistant tool_call this
    /// message answers.
    var toolCallID: String?
    /// Real prompt+completion tokens reported by the provider for the
    /// turn that produced this assistant message. Only assistant
    /// messages populate this. Older sessions without it fall back to
    /// the chars/4 estimator.
    var usageTokens: Int?
    /// Prompt-side tokens (input) reported by the provider on the final
    /// streaming chunk. Only set on assistant messages, only when the
    /// provider emits a usage block. Older sessions without this field
    /// decode to nil.
    var promptTokens: Int?
    /// Completion-side tokens (output) reported by the provider.
    var completionTokens: Int?
    /// Wall-clock seconds the assistant streamed for — from first
    /// stream connect to `.finishedTurn`. Only set on assistant
    /// messages once the stream terminates. Used by the message
    /// footer to render "2.3s". Nil on user/system/tool rows and on
    /// in-flight assistant messages.
    var elapsedSeconds: Double?
    let createdAt: Date

    nonisolated init(
        id: UUID = UUID(),
        role: AgentRole,
        content: String,
        reasoningContent: String? = nil,
        images: [AgentImageAttachment] = [],
        toolCalls: [AgentMessageToolCall] = [],
        toolCallID: String? = nil,
        usageTokens: Int? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        elapsedSeconds: Double? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.images = images
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.usageTokens = usageTokens
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.elapsedSeconds = elapsedSeconds
        self.createdAt = createdAt
    }

    /// Explicit keys so newer fields can use `decodeIfPresent` without
    /// breaking older session JSON.
    enum CodingKeys: String, CodingKey {
        case id, role, content, reasoningContent, images, toolCalls, toolCallID
        case usageTokens, promptTokens, completionTokens, elapsedSeconds
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(AgentRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        images = try container.decodeIfPresent([AgentImageAttachment].self, forKey: .images) ?? []
        toolCalls = try container.decodeIfPresent([AgentMessageToolCall].self, forKey: .toolCalls) ?? []
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        usageTokens = try container.decodeIfPresent(Int.self, forKey: .usageTokens)
        promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens)
        completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens)
        elapsedSeconds = try container.decodeIfPresent(Double.self, forKey: .elapsedSeconds)
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
    /// True once the Agent has successfully applied at least one patch in
    /// this session. Drives whether the "正在编辑 / N 个文件已更改" worktree
    /// card appears — empty/new sessions never show it, even when the
    /// underlying repo has unrelated uncommitted changes.
    var didEditFiles: Bool
    /// Per-session interaction mode. Persisted so re-selecting a session
    /// resumes plan/goal context without the user having to redo setup.
    var interactionMode: AgentInteractionMode
    /// Plan-mode state (proposed → approved → done). Nil outside Plan
    /// mode, or when Plan mode is on but no plan has been drafted yet.
    var currentPlan: AgentPlan?
    /// Goal-mode definition (statement + acceptance checklist). Nil
    /// outside Goal mode, or when Goal mode is on but the user hasn't
    /// defined a goal yet.
    var currentGoal: AgentGoal?
    /// When the user pinned this session to the top of its workspace
    /// group. Nil = not pinned. We store the timestamp (not a bool) so
    /// that multiple pinned items inside one workspace can be ordered
    /// "most-recently-pinned first" in the sidebar.
    var pinnedAt: Date?
    /// When the user archived this session. Nil = active. Archived
    /// sessions are hidden from the regular workspace list and
    /// surfaced under a collapsed "已归档" group at the bottom of each
    /// workspace.
    var archivedAt: Date?

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        workspaceRootPath: String? = nil,
        modelID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [AgentMessage] = [],
        didEditFiles: Bool = false,
        interactionMode: AgentInteractionMode = .normal,
        currentPlan: AgentPlan? = nil,
        currentGoal: AgentGoal? = nil,
        pinnedAt: Date? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.workspaceRootPath = workspaceRootPath
        self.modelID = modelID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.didEditFiles = didEditFiles
        self.interactionMode = interactionMode
        self.currentPlan = currentPlan
        self.currentGoal = currentGoal
        self.pinnedAt = pinnedAt
        self.archivedAt = archivedAt
    }

    var isPinned: Bool { pinnedAt != nil }
    var isArchived: Bool { archivedAt != nil }

    var workspaceName: String {
        guard let path = workspaceRootPath, !path.isEmpty else { return "No workspace" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    // Custom decoding so older session JSON without the newer fields
    // (didEditFiles, interactionMode, currentPlan, currentGoal) loads
    // cleanly — every newer field uses decodeIfPresent with a default.
    enum CodingKeys: String, CodingKey {
        case id, title, workspaceRootPath, modelID, createdAt, updatedAt, messages
        case didEditFiles, interactionMode, currentPlan, currentGoal
        case pinnedAt, archivedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.workspaceRootPath = try c.decodeIfPresent(String.self, forKey: .workspaceRootPath)
        self.modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.messages = try c.decode([AgentMessage].self, forKey: .messages)
        self.didEditFiles = try c.decodeIfPresent(Bool.self, forKey: .didEditFiles) ?? false
        self.interactionMode = try c.decodeIfPresent(AgentInteractionMode.self, forKey: .interactionMode) ?? .normal
        self.currentPlan = try c.decodeIfPresent(AgentPlan.self, forKey: .currentPlan)
        self.currentGoal = try c.decodeIfPresent(AgentGoal.self, forKey: .currentGoal)
        self.pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        self.archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
    }
}

// MARK: - Plan & Goal modes

/// Top-level interaction mode for an Agent session. Plan locks all write
/// tools until the user approves a plan; Goal pins a long-term objective
/// + checklist to every system prompt. Normal is the default.
enum AgentInteractionMode: String, Codable, CaseIterable, Identifiable {
    case normal
    case plan
    case goal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .plan: return "Plan"
        case .goal: return "Goal"
        }
    }

    var symbol: String {
        switch self {
        case .normal: return "bubble.left.and.bubble.right"
        case .plan: return "list.number"
        case .goal: return "target"
        }
    }
}

/// A user-approvable execution plan parsed from the agent's reply.
/// Lifecycle:
///   proposed → awaiting user click
///   approved → write tools unlocked, agent continues
///   rejected → user dismissed; agent should re-plan on next turn
///   executing/done used purely for display once approved.
struct AgentPlan: Codable, Equatable {
    enum Status: String, Codable { case proposed, approved, rejected, executing, done }

    /// Per-step lifecycle. Agent self-reports via a ```progress fenced
    /// block; the user can also click checkboxes to override.
    enum StepStatus: String, Codable, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case done
        case skipped
        case failed
    }

    struct Step: Codable, Equatable, Identifiable {
        var id: UUID
        var text: String
        var status: StepStatus

        init(id: UUID = UUID(), text: String, status: StepStatus = .pending) {
            self.id = id
            self.text = text
            self.status = status
        }
    }

    var status: Status
    var steps: [Step]
    /// Free-form preamble the agent put before the numbered list. Shown
    /// muted at the top of the plan card.
    var summary: String

    init(status: Status = .proposed, steps: [Step] = [], summary: String = "") {
        self.status = status
        self.steps = steps
        self.summary = summary
    }

    /// Convenience for older call sites that built plans from raw strings.
    init(status: Status, summary: String, stepTexts: [String]) {
        self.status = status
        self.steps = stepTexts.map { Step(text: $0) }
        self.summary = summary
    }
}

/// A long-term goal pinned to a session. Sticks to every system prompt so
/// the agent stays aligned, and renders as a banner at the top of the
/// transcript. `checklist` entries can be ticked off independently.
struct AgentGoal: Codable, Equatable {
    var statement: String
    var checklist: [Item]

    struct Item: Codable, Equatable, Identifiable {
        var id: UUID
        var text: String
        var done: Bool

        init(id: UUID = UUID(), text: String, done: Bool = false) {
            self.id = id
            self.text = text
            self.done = done
        }
    }

    init(statement: String = "", checklist: [Item] = []) {
        self.statement = statement
        self.checklist = checklist
    }

    var isEmpty: Bool { statement.isEmpty && checklist.isEmpty }
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
        // Detect a stale model carried over from a previous provider —
        // e.g. user had OpenAI's `gpt-3.5-16k` as flashModel, then
        // switched provider to DeepSeek in Settings. Without this check
        // the chat-mode model picker keeps offering `gpt-3.5-16k` as
        // the "route default", which is just confusing. If the model
        // string contains no hint that matches the current preset,
        // reset to that preset's documented default.
        if let preset, preset.id != AgentProviderPreset.customID {
            if !preset.recognizesModelID(result.flashModel) {
                result.flashModel = preset.defaultFlashModel
            }
            if !preset.recognizesModelID(result.proModel) {
                result.proModel = preset.defaultProModel
            }
            if !preset.recognizesModelID(result.model) {
                result.model = preset.defaultModel
            }
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
    /// Short list of substrings that identify a model as belonging to
    /// this provider — used by `normalized()` to detect when a stale
    /// flash/pro model name from a previous provider got carried over
    /// after the user switched providers in Settings. Best-effort: an
    /// unrecognised name doesn't crash, it just sticks until the user
    /// picks one from the live model list.
    let modelHints: [String]

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
        supportsImageInput: Bool = true,
        modelHints: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.defaultFlashModel = defaultFlashModel ?? defaultModel
        self.defaultProModel = defaultProModel ?? defaultModel
        self.supportsModelFetch = supportsModelFetch
        self.supportsImageInput = supportsImageInput
        self.modelHints = modelHints
    }

    /// Quick "does this model name look like it could be one of mine"
    /// check. Custom provider says yes to everything (no opinion); a
    /// preset without hints also says yes (back-compat). Lowercase
    /// substring match against `modelHints`.
    func recognizesModelID(_ rawID: String) -> Bool {
        let id = rawID.lowercased()
        guard !id.isEmpty else { return true }
        guard self.id != Self.customID else { return true }
        guard !modelHints.isEmpty else { return true }
        return modelHints.contains { id.contains($0.lowercased()) }
    }

    static let all: [AgentProviderPreset] = [
        AgentProviderPreset(
            id: openAIID,
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-4.1-mini",
            defaultProModel: "gpt-4.1",
            supportsModelFetch: true,
            modelHints: ["gpt-", "o1", "o3", "text-embedding", "davinci"]
        ),
        AgentProviderPreset(
            id: "dashscope",
            displayName: "DashScope",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            defaultModel: "qwen-plus",
            defaultProModel: "qwen-max",
            supportsModelFetch: true,
            modelHints: ["qwen", "qwq"]
        ),
        AgentProviderPreset(
            id: "deepseek",
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            defaultModel: "deepseek-v4-flash",
            defaultProModel: "deepseek-v4-pro",
            supportsModelFetch: true,
            supportsImageInput: false,
            modelHints: ["deepseek"]
        ),
        AgentProviderPreset(
            id: "kimi",
            displayName: "Kimi",
            baseURL: "https://api.moonshot.cn/v1",
            defaultModel: "kimi-k2.5",
            supportsModelFetch: true,
            modelHints: ["kimi"]
        ),
        AgentProviderPreset(
            id: "moonshot",
            displayName: "Moonshot",
            baseURL: "https://api.moonshot.cn/v1",
            defaultModel: "moonshot-v1-8k",
            supportsModelFetch: true,
            modelHints: ["moonshot"]
        ),
        AgentProviderPreset(
            id: "claude",
            displayName: "Claude",
            baseURL: "https://api.anthropic.com/v1",
            defaultModel: "claude-sonnet-4-5",
            supportsModelFetch: true,
            modelHints: ["claude", "anthropic"]
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

struct AgentWorktreeDiffPreview: Identifiable, Equatable {
    let id: UUID
    var title: String
    var diff: String

    nonisolated init(id: UUID = UUID(), title: String, diff: String) {
        self.id = id
        self.title = title
        self.diff = diff
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

/// A file the user attached via the composer's `@` picker. We carry the
/// URL (for display + dedup) and a workspace-relative display path; the
/// actual contents get re-read at send time so the model always sees
/// the latest on-disk state, not a stale snapshot.
struct AgentFileAttachment: Identifiable, Equatable {
    let url: URL
    let relativePath: String

    var id: String { url.standardizedFileURL.path }
}

// MARK: - Multi-provider library

/// One entry in the user's saved provider library. Each entry carries
/// its own provider preset, base URL, API key, and primary/alternate
/// model lists for both flash and pro tiers. The "active" entry drives
/// `AgentConfiguration` for the current chat; alternates show up in
/// the chat-mode picker as one-click switches.
struct AgentProviderEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var providerID: String
    var displayName: String
    var baseURL: String
    /// Whether this entry should be used in routing right now. Exactly
    /// one entry in `agentProviderLibrary` is the active one; toggling
    /// activation is the library's job, not this struct's.
    var apiKey: String
    /// Primary model for Auto/Flash routing. Required when this entry
    /// is active.
    var flashPrimary: String
    /// Alternate flash models surfaced in the chat picker so the user
    /// can one-click try a different cheap model without leaving the
    /// conversation.
    var flashAlternates: [String]
    /// Primary model for Pro routing.
    var proPrimary: String
    /// Alternate pro models surfaced in the chat picker.
    var proAlternates: [String]
    /// Per-entry routing mode override. When the user switches active
    /// to this entry the live configuration adopts this. Defaults to
    /// `.auto` for new entries; existing entries that pre-date this
    /// field decode to `.auto` via decodeIfPresent below.
    var routingMode: AgentModelRoutingMode

    init(
        id: UUID = UUID(),
        providerID: String,
        displayName: String? = nil,
        baseURL: String,
        apiKey: String = "",
        flashPrimary: String,
        flashAlternates: [String] = [],
        proPrimary: String,
        proAlternates: [String] = [],
        routingMode: AgentModelRoutingMode = .auto
    ) {
        self.id = id
        self.providerID = providerID
        self.displayName = (displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                            ? displayName!
                            : AgentProviderPreset.preset(id: providerID)?.displayName ?? providerID)
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.flashPrimary = flashPrimary
        self.flashAlternates = AgentProviderEntry.cleanList(flashAlternates, excluding: flashPrimary)
        self.proPrimary = proPrimary
        self.proAlternates = AgentProviderEntry.cleanList(proAlternates, excluding: proPrimary)
        self.routingMode = routingMode
    }

    enum CodingKeys: String, CodingKey {
        case id, providerID, displayName, baseURL, apiKey
        case flashPrimary, flashAlternates, proPrimary, proAlternates
        case routingMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.providerID = try c.decode(String.self, forKey: .providerID)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.baseURL = try c.decode(String.self, forKey: .baseURL)
        self.apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        self.flashPrimary = try c.decode(String.self, forKey: .flashPrimary)
        self.flashAlternates = try c.decodeIfPresent([String].self, forKey: .flashAlternates) ?? []
        self.proPrimary = try c.decode(String.self, forKey: .proPrimary)
        self.proAlternates = try c.decodeIfPresent([String].self, forKey: .proAlternates) ?? []
        // New field — older library JSON has no routingMode, default to
        // .auto so existing entries keep their previous behaviour.
        self.routingMode = try c.decodeIfPresent(AgentModelRoutingMode.self, forKey: .routingMode) ?? .auto
    }

    /// All flash candidates with the primary first — convenient for
    /// picker menus.
    var allFlashModels: [String] {
        var out = [flashPrimary]
        out.append(contentsOf: flashAlternates)
        return out.filter { !$0.isEmpty }
    }

    /// All pro candidates with the primary first.
    var allProModels: [String] {
        var out = [proPrimary]
        out.append(contentsOf: proAlternates)
        return out.filter { !$0.isEmpty }
    }

    /// Build an `AgentConfiguration` snapshot from this entry, choosing
    /// a specific tier model (or falling back to the primaries).
    func makeConfiguration(
        flashOverride: String? = nil,
        proOverride: String? = nil,
        routingMode routingModeOverride: AgentModelRoutingMode? = nil,
        imageDescription: AgentImageDescriptionConfiguration = .default
    ) -> AgentConfiguration {
        let flash = flashOverride.nonEmpty ?? flashPrimary
        let pro = proOverride.nonEmpty ?? proPrimary
        // Use the entry's own routing mode by default — only callers
        // that need to force a specific mode (e.g. compression always
        // wants flash) pass an override.
        let mode = routingModeOverride ?? routingMode
        return AgentConfiguration(
            providerID: providerID,
            baseURL: baseURL,
            model: mode == .pro ? pro : flash,
            flashModel: flash,
            proModel: pro,
            routingMode: mode,
            imageDescription: imageDescription,
            apiKey: apiKey
        )
    }

    private static func cleanList(_ list: [String], excluding primary: String) -> [String] {
        var seen = Set<String>()
        seen.insert(primary)
        return list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let v = self?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }
}

/// Top-level container for the multi-provider library. Knows which
/// entry is currently active. Persisted as a single JSON blob.
struct AgentProviderLibrary: Codable, Equatable {
    var entries: [AgentProviderEntry]
    var activeID: UUID?

    init(entries: [AgentProviderEntry] = [], activeID: UUID? = nil) {
        self.entries = entries
        self.activeID = activeID ?? entries.first?.id
    }

    var active: AgentProviderEntry? {
        guard let id = activeID else { return entries.first }
        return entries.first(where: { $0.id == id }) ?? entries.first
    }

    mutating func upsert(_ entry: AgentProviderEntry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        if activeID == nil { activeID = entry.id }
    }

    mutating func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        if activeID == id { activeID = entries.first?.id }
    }

    mutating func setActive(_ id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        activeID = id
    }

    /// Promote a legacy single-provider AgentConfiguration to the new
    /// library shape. The single entry becomes the active one; its
    /// existing flash/pro models start with no alternates. Caller
    /// should only invoke this when no library yet exists in storage.
    static func migrate(from configuration: AgentConfiguration) -> AgentProviderLibrary {
        let entry = AgentProviderEntry(
            providerID: configuration.providerID,
            baseURL: configuration.baseURL,
            apiKey: configuration.apiKey,
            flashPrimary: configuration.flashModel.isEmpty ? configuration.model : configuration.flashModel,
            flashAlternates: [],
            proPrimary: configuration.proModel.isEmpty ? configuration.model : configuration.proModel,
            proAlternates: []
        )
        return AgentProviderLibrary(entries: [entry], activeID: entry.id)
    }
}
