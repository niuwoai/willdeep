//
//  AgentMessageModels.swift
//  WillDeep
//
//  Message, attachment, and queued-message models shared by Agent
//  providers, transcript renderers, session persistence, and tools.
//

import Foundation

enum AppMode: String, Codable {
    case editor
    case agent
}

struct AgentEditorSelectionContext: Equatable {
    let text: String
    let startLine: Int
    let endLine: Int
}

nonisolated enum AgentRole: String, Codable {
    case system
    case user
    case assistant
    case tool
    /// 1.81.0-rc1：workflow（/research / /code-review / …）启动时塞一条这种
    /// role 的消息进 messages，content 留空，挂在 `workflowReport` 字段上
    /// 的 `WorkflowReport` 持续被 engine 更新。transcript 渲染时识别此
    /// role 走 AgentWorkflowCardView，不走普通 bubble。模型看不到此类
    /// 消息（AgentChatHistoryFormatter 会过滤），workflow 的最终结果由
    /// engine 完成时单独 inject 一条 `.system` notice。
    case workflowReport
    /// 1.84.0-rc1：`show_widget` 工具生成的可视化卡片消息。
    /// `content` 留空，HTML/SVG 挂在 `widget: AgentWidget?` 字段上。
    /// 渲染走 AgentWidgetCardView（WKWebView + CSP sandbox）。同样
    /// **不发给 LLM**：所有 AgentClient adapter 看到都跳过。
    case widget
}

nonisolated enum AgentMessageOrigin: String, Codable, Equatable {
    case nativeModel
    case delegatedExternal
}

/// A user-attached image, encoded inline so it round-trips through session
/// JSON without a separate blob store. `dataBase64` is the raw image bytes
/// base64-encoded (no `data:` prefix); `mimeType` is e.g. `image/png`.
nonisolated struct AgentImageAttachment: Codable, Equatable, Identifiable {
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

/// Plain text pasted into the composer as a compact `.txt` attachment
/// instead of being inlined into the visible chat bubble. This keeps
/// crash logs and other long snippets readable while still sending the
/// full payload to the model.
nonisolated struct AgentTextAttachment: Codable, Equatable, Identifiable {
    nonisolated static let pastedTextFilename = "Pasted text.txt"
    nonisolated static let largePasteCharacterThreshold = 1_800
    nonisolated static let largePasteLineThreshold = 18
    nonisolated static let maxPastedTextCharacters = 200_000

    let id: UUID
    var filename: String
    var content: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        filename: String = AgentTextAttachment.pastedTextFilename,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.filename = filename
        self.content = content
        self.createdAt = createdAt
    }

    nonisolated var byteCount: Int {
        content.utf8.count
    }

    nonisolated var byteLabel: String {
        Self.byteLabel(byteCount)
    }

    nonisolated var displayName: String {
        filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.pastedTextFilename
            : filename
    }

    nonisolated var modelBlock: String {
        """
        ### Attached text: \(displayName)

        ```text
        \(content)
        ```
        """
    }

    nonisolated static func shouldCapturePaste(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.count >= largePasteCharacterThreshold { return true }
        let lineCount = trimmed.components(separatedBy: .newlines).count
        return lineCount >= largePasteLineThreshold
    }

    nonisolated static func sanitizedPastedContent(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxPastedTextCharacters else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxPastedTextCharacters)
        return String(trimmed[..<end])
    }

    nonisolated static func byteLabel(_ count: Int) -> String {
        if count < 1_024 {
            return "\(count) B"
        }
        let kb = Double(count) / 1_024.0
        if kb < 1_024 {
            return String(format: "%.1f KB", kb)
        }
        return String(format: "%.1f MB", kb / 1_024.0)
    }
}

/// Tool call emitted by the assistant in an OpenAI function-calling response.
/// `argumentsJSON` is the raw JSON text the model produced (it may stream in
/// fragments and only be valid JSON once complete).
nonisolated struct AgentMessageToolCall: Codable, Equatable {
    var externalID: String
    var toolName: String
    var argumentsJSON: String
}

nonisolated struct AgentMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: AgentRole
    var content: String
    /// Reasoning / thinking-mode trace from providers that emit it
    /// separately (DashScope qwen3, qwq, DeepSeek-R1 family). When set
    /// on an assistant message, we MUST send it back on the next turn
    /// because DashScope returns HTTP 400 otherwise. Empty for providers
    /// that don't split reasoning out.
    var reasoningContent: String?
    /// User-attached images, only meaningful for `role == .user`.
    var images: [AgentImageAttachment]
    /// Long pasted text captured as compact `.txt` attachments. The
    /// visible bubble renders chips, while AgentClient includes the
    /// full text in the provider payload.
    var textAttachments: [AgentTextAttachment]
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
    /// Prompt tokens served from provider-side context/prompt cache.
    /// Providers name this differently (`cached_tokens`,
    /// `cache_read_input_tokens`, `prompt_cache_hit_tokens`,
    /// `cachedContentTokenCount`); the adapters normalize it here.
    var cachedPromptTokens: Int?
    /// Prompt tokens written into provider-side cache on this request.
    var cacheWritePromptTokens: Int?
    /// Completion tokens spent on hidden reasoning/thinking traces when
    /// the provider reports them separately.
    var reasoningTokens: Int?
    /// Wall-clock seconds the assistant streamed for, from first stream
    /// connect to `.finishedTurn`. Only set on assistant messages once
    /// the stream terminates.
    var elapsedSeconds: Double?
    /// Distinguishes native provider turns from external CLI delegated
    /// results so cache/cost analytics don't mix black-box CLI output
    /// into WillDeep's provider-side cache rate.
    var origin: AgentMessageOrigin?
    var originLabel: String?
    /// Compact cache diagnostics captured for the request that produced
    /// this assistant message. The hash is a stable FNV-1a hex string
    /// for the request prefix; stablePrefixCharacters is the length of
    /// the fixed prefix before dynamic workspace/memory/history blocks.
    var requestPrefixHash: String?
    var requestStablePrefixCharacters: Int?
    /// 1.81.0-rc1：role == .workflowReport 时挂载的 workflow 运行数据。
    /// engine 边跑边 mutate 这里的字段（subAgents 状态、totalUsageTokens、
    /// summary 等），UI 卡片读它显示进度。其它 role 一定是 nil；旧版本
    /// session 反序列化时也是 nil（Codable optional），向后兼容。
    var workflowReport: WorkflowReport?
    /// 1.84.0-rc1：role == .widget 时挂载的 HTML/SVG 可视化数据。其它
    /// role 一定 nil；旧 session 反序列化时也是 nil（Codable optional 向
    /// 后兼容）。
    var widget: AgentWidget?
    let createdAt: Date

    nonisolated init(
        id: UUID = UUID(),
        role: AgentRole,
        content: String,
        reasoningContent: String? = nil,
        images: [AgentImageAttachment] = [],
        textAttachments: [AgentTextAttachment] = [],
        toolCalls: [AgentMessageToolCall] = [],
        toolCallID: String? = nil,
        usageTokens: Int? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cachedPromptTokens: Int? = nil,
        cacheWritePromptTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        elapsedSeconds: Double? = nil,
        origin: AgentMessageOrigin? = nil,
        originLabel: String? = nil,
        requestPrefixHash: String? = nil,
        requestStablePrefixCharacters: Int? = nil,
        workflowReport: WorkflowReport? = nil,
        widget: AgentWidget? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.images = images
        self.textAttachments = textAttachments
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.usageTokens = usageTokens
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.cacheWritePromptTokens = cacheWritePromptTokens
        self.reasoningTokens = reasoningTokens
        self.elapsedSeconds = elapsedSeconds
        self.origin = origin
        self.originLabel = originLabel
        self.requestPrefixHash = requestPrefixHash
        self.requestStablePrefixCharacters = requestStablePrefixCharacters
        self.workflowReport = workflowReport
        self.widget = widget
        self.createdAt = createdAt
    }

    /// Explicit keys so newer fields can use `decodeIfPresent` without
    /// breaking older session JSON.
    enum CodingKeys: String, CodingKey {
        case id, role, content, reasoningContent, images, textAttachments, toolCalls, toolCallID
        case usageTokens, promptTokens, completionTokens
        case cachedPromptTokens, cacheWritePromptTokens, reasoningTokens
        case elapsedSeconds
        case origin, originLabel, requestPrefixHash, requestStablePrefixCharacters
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(AgentRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        images = try container.decodeIfPresent([AgentImageAttachment].self, forKey: .images) ?? []
        textAttachments = try container.decodeIfPresent([AgentTextAttachment].self, forKey: .textAttachments) ?? []
        toolCalls = try container.decodeIfPresent([AgentMessageToolCall].self, forKey: .toolCalls) ?? []
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        usageTokens = try container.decodeIfPresent(Int.self, forKey: .usageTokens)
        promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens)
        completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens)
        cachedPromptTokens = try container.decodeIfPresent(Int.self, forKey: .cachedPromptTokens)
        cacheWritePromptTokens = try container.decodeIfPresent(Int.self, forKey: .cacheWritePromptTokens)
        reasoningTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningTokens)
        elapsedSeconds = try container.decodeIfPresent(Double.self, forKey: .elapsedSeconds)
        origin = try container.decodeIfPresent(AgentMessageOrigin.self, forKey: .origin)
        originLabel = try container.decodeIfPresent(String.self, forKey: .originLabel)
        requestPrefixHash = try container.decodeIfPresent(String.self, forKey: .requestPrefixHash)
        requestStablePrefixCharacters = try container.decodeIfPresent(Int.self, forKey: .requestStablePrefixCharacters)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

extension AgentMessage {
    /// Content as sent to providers. UI renderers use `content` plus
    /// compact attachment chips; wire encoding appends the full pasted
    /// text so the model still receives the user's context.
    nonisolated var modelContent: String {
        guard !textAttachments.isEmpty else { return content }
        var blocks: [String] = []
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            blocks.append(content)
        }
        blocks.append(contentsOf: textAttachments.map(\.modelBlock))
        return blocks.joined(separator: "\n\n")
    }

    /// Clipboard-friendly full text for copy buttons and standalone
    /// readers: visible text first, then pasted-text attachments.
    nonisolated var copyableContent: String {
        guard !textAttachments.isEmpty else { return content }
        var blocks: [String] = []
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            blocks.append(content)
        }
        for attachment in textAttachments {
            blocks.append("""
            [\(attachment.displayName)]
            \(attachment.content)
            """)
        }
        return blocks.joined(separator: "\n\n")
    }
}

/// A message the user queued while the agent was busy. Consumed FIFO
/// once the current response completes (or is stopped).
struct AgentQueuedMessage: Identifiable, Equatable {
    let id: UUID
    var text: String
    var images: [AgentImageAttachment]
    var textAttachments: [AgentTextAttachment]
    var attachedSkills: [AgentSkillEntry]
    var executionAgent: AgentExecutionAgent

    init(
        id: UUID = UUID(),
        text: String,
        images: [AgentImageAttachment] = [],
        textAttachments: [AgentTextAttachment] = [],
        attachedSkills: [AgentSkillEntry] = [],
        executionAgent: AgentExecutionAgent = .willDeep
    ) {
        self.id = id
        self.text = text
        self.images = images
        self.textAttachments = textAttachments
        self.attachedSkills = attachedSkills
        self.executionAgent = executionAgent
    }
}
