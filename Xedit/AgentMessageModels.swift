//
//  AgentMessageModels.swift
//  WillDeep
//
//  Message, attachment, and queued-message models shared by Agent
//  providers, transcript renderers, session persistence, and tools.
//

import Foundation
import CryptoKit

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
    /// `schedule_task` 工具在会话里安排定时任务时塞进 transcript 的卡片
    /// 消息。`content` 留空，任务快照挂在 `scheduledTask` 字段上，渲染走
    /// AgentScheduledTaskCardView。与 widget 一样**不发给 LLM**，但**会
    /// 持久化**（是一次操作记录，重开会话应保留）。
    case scheduledTask
}

nonisolated enum AgentMessageOrigin: String, Codable, Equatable {
    case nativeModel
    case delegatedExternal
}

/// Identifies who supplied a user-role message. Providers still receive both
/// variants as `.user`, but the transcript only presents real operator input
/// as a user bubble. `nil` means operator input for backward compatibility.
nonisolated enum AgentMessageSource: String, Codable, Equatable {
    case operatorInput
    case hostInstruction
}

/// A local-only marker rendered in the transcript. These events are stored
/// with the conversation for auditability, but must never be sent to a model
/// as chat context.
nonisolated enum AgentTranscriptEvent: String, Codable, Equatable {
    case modelChanged
    case responseStopped
    /// A complex task auto-entered Plan mode after the suggestion banner
    /// timed out without an explicit user choice.
    case autoPlanModeEntered
}

nonisolated enum AgentImageAttachmentSource: String, Codable, Equatable, Sendable {
    case userUpload
    case generated
}

/// An image surfaced in the transcript. Unifies two storage models:
/// user uploads may keep bytes inline (so older sessions round-trip through
/// session JSON) or be file-backed so queued drafts keep only lightweight
/// metadata (`byteCount`/`sha256`); generated images keep a small inline
/// preview plus a workspace-local `filePath` and carry `source`/`model`/
/// `prompt`, and quoting them sends a text marker instead of re-uploading bytes.
nonisolated struct AgentImageAttachment: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let mimeType: String
    /// Inline bytes: the full image for legacy uploads, or a small preview for
    /// generated / file-backed images. `nil` when the bytes live only on disk.
    private let inlineDataBase64: String?
    var filePath: String?
    let byteCount: Int?
    let sha256: String?
    var source: AgentImageAttachmentSource?
    var model: String?
    var prompt: String?
    var createdAt: Date?

    init(
        id: UUID = UUID(),
        mimeType: String,
        dataBase64: String,
        source: AgentImageAttachmentSource? = nil,
        filePath: String? = nil,
        model: String? = nil,
        prompt: String? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.mimeType = mimeType
        self.inlineDataBase64 = dataBase64.isEmpty ? nil : dataBase64
        self.filePath = filePath
        self.byteCount = Data(base64Encoded: dataBase64)?.count
        self.sha256 = nil
        self.source = source
        self.model = model
        self.prompt = prompt
        self.createdAt = createdAt
    }

    init(
        id: UUID = UUID(),
        mimeType: String,
        filePath: String,
        byteCount: Int? = nil,
        sha256: String? = nil,
        source: AgentImageAttachmentSource? = nil,
        model: String? = nil,
        prompt: String? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.mimeType = mimeType
        self.inlineDataBase64 = nil
        self.filePath = filePath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.source = source
        self.model = model
        self.prompt = prompt
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, mimeType, dataBase64, filePath, byteCount, sha256, source, model, prompt, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        inlineDataBase64 = try container.decodeIfPresent(String.self, forKey: .dataBase64)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount)
            ?? inlineDataBase64.flatMap { Data(base64Encoded: $0)?.count }
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        source = try container.decodeIfPresent(AgentImageAttachmentSource.self, forKey: .source)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(mimeType, forKey: .mimeType)
        if let inlineDataBase64 {
            try container.encode(inlineDataBase64, forKey: .dataBase64)
        }
        try container.encodeIfPresent(filePath, forKey: .filePath)
        try container.encodeIfPresent(byteCount, forKey: .byteCount)
        try container.encodeIfPresent(sha256, forKey: .sha256)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(prompt, forKey: .prompt)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }

    /// Decoded inline bytes, if any — nil for purely file-backed images.
    /// Unlike `dataBase64`, this never touches disk, so it is safe on
    /// render-frequency paths.
    nonisolated var inlineImageData: Data? {
        inlineDataBase64.flatMap { Data(base64Encoded: $0) }
    }

    /// Image bytes as base64, read from the inline copy if present, otherwise
    /// lazily from the file-backed copy.
    nonisolated var dataBase64: String {
        if let inlineDataBase64 {
            return inlineDataBase64
        }
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL) else {
            return ""
        }
        return data.base64EncodedString()
    }

    nonisolated var dataURL: String {
        "data:\(mimeType);base64,\(dataBase64)"
    }

    nonisolated var fileURL: URL? {
        guard let filePath, !filePath.isEmpty else { return nil }
        return URL(fileURLWithPath: filePath).standardizedFileURL
    }

    nonisolated var isFileBacked: Bool {
        fileURL != nil
    }

    nonisolated var thumbnailCacheKey: String {
        if let filePath {
            return "file|\(filePath)|\(sha256 ?? "")"
        }
        return "inline|\(id.uuidString)|\(inlineDataBase64?.count ?? 0)"
    }

    nonisolated var generatedReferenceMarker: String? {
        guard source == .generated,
              let filePath = filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !filePath.isEmpty else {
            return nil
        }
        return AgentGeneratedImageReference.marker(
            id: id.uuidString,
            path: filePath,
            model: model
        )
    }

    nonisolated static func fileBacked(
        data: Data,
        mimeType: String,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> AgentImageAttachment {
        let directory = try attachmentDirectory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "image.\(fileExtension(for: mimeType))"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try data.write(to: url, options: [.atomic])
        return AgentImageAttachment(
            id: id,
            mimeType: mimeType,
            filePath: url.standardizedFileURL.path,
            byteCount: data.count,
            sha256: sha256Hex(for: data),
            createdAt: createdAt
        )
    }

    nonisolated func diskBackedCopy() throws -> AgentImageAttachment {
        if isFileBacked {
            return self
        }
        guard let inlineDataBase64,
              let data = Data(base64Encoded: inlineDataBase64) else {
            return self
        }
        return try Self.fileBacked(data: data, mimeType: mimeType, id: id, createdAt: createdAt ?? Date())
    }

    nonisolated func removeStoredFileIfNeeded() {
        guard let fileURL else { return }
        let directory = fileURL.deletingLastPathComponent()
        guard directory.lastPathComponent == id.uuidString,
              directory.deletingLastPathComponent().lastPathComponent == "AgentAttachments" else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private nonisolated static func attachmentDirectory(for id: UUID) throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.willdeep.app"
        return base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("AgentAttachments", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private nonisolated static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        default: return "png"
        }
    }

    private nonisolated static func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

nonisolated enum AgentGeneratedImageReference {
    static let tagName = "generated-image-reference"

    static func marker(id: String, path: String, model: String?) -> String {
        var attributes = [
            "id=\"\(escape(id))\"",
            "path=\"\(escape(path))\""
        ]
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            attributes.append("model=\"\(escape(model))\"")
        }
        return "<\(tagName) \(attributes.joined(separator: " ")) />"
    }

    static func path(from marker: String) -> String? {
        attribute("path", in: marker)
    }

    private static func escape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func unescape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func attribute(_ name: String, in marker: String) -> String? {
        guard marker.contains(tagName),
              let nameRange = marker.range(of: "\(name)=\"") else {
            return nil
        }
        let valueStart = nameRange.upperBound
        guard let valueEnd = marker[valueStart...].firstIndex(of: "\"") else {
            return nil
        }
        let value = String(marker[valueStart..<valueEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : unescape(value)
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
    /// Images attached to the visible message. User messages carry pasted
    /// uploads; assistant messages can carry generated-image previews whose
    /// original files live in the workspace and can be quoted by reference.
    var images: [AgentImageAttachment]
    /// Long pasted text captured as compact `.txt` attachments. The
    /// visible bubble renders chips, while AgentClient includes the
    /// full text in the provider payload.
    var textAttachments: [AgentTextAttachment]
    /// Hidden host context appended only to provider-facing content. Once a
    /// user turn is sent this value is persisted with that message so later
    /// requests reproduce the exact same history bytes for prompt caching;
    /// transcript renderers and copy actions intentionally ignore it.
    var modelContext: String?
    var toolCalls: [AgentMessageToolCall]
    /// When `role == .tool`, the external id of the assistant tool_call this
    /// message answers.
    var toolCallID: String?
    /// Persisted terminal state for a tool result. This deliberately lives on
    /// the result message, so the activity dashboard can review real failures
    /// after a session has been reopened instead of inferring them from prose.
    var toolCallStatus: AgentToolCallStatus?
    /// A concise, already-redacted failure reason for the tool result.
    /// Populated only for explicit execution failures; user-denied calls are
    /// kept distinct from failures in the workbench review.
    var toolErrorMessage: String?
    /// Real prompt+completion tokens reported by the provider for the
    /// turn that produced this assistant message. Only assistant
    /// messages populate this. Older sessions without it fall back to
    /// the chars/4 estimator.
    var usageTokens: Int?
    /// Total prompt-side tokens (input) reported by the provider on the final
    /// streaming chunk, including cache reads/writes when a provider reports
    /// those as separate buckets. Only set on assistant messages. Older
    /// sessions without this field decode to nil.
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
    /// User-role messages generated by WillDeep itself (for example the
    /// instruction sent after approving a plan) remain model context without
    /// impersonating text typed by the operator in the transcript.
    var source: AgentMessageSource?
    /// Presentation-only event metadata for system messages such as a model
    /// switch. Unlike ordinary `.system` messages, these are visible in the
    /// transcript and excluded from every provider request.
    var transcriptEvent: AgentTranscriptEvent?
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
    /// some.im managed-routing decision for this assistant turn (nil on
    /// non-managed turns). Records the resolved model / tier / domain /
    /// complexity plus fallback and escalation markers for observability.
    var managedRoute: AgentManagedRouteDecision?
    /// 1.81.0-rc1：role == .workflowReport 时挂载的 workflow 运行数据。
    /// engine 边跑边 mutate 这里的字段（subAgents 状态、totalUsageTokens、
    /// summary 等），UI 卡片读它显示进度。其它 role 一定是 nil；旧版本
    /// session 反序列化时也是 nil（Codable optional），向后兼容。
    var workflowReport: WorkflowReport?
    /// 1.84.0-rc1：role == .widget 时挂载的 HTML/SVG 可视化数据。其它
    /// role 一定 nil；旧 session 反序列化时也是 nil（Codable optional 向
    /// 后兼容）。
    var widget: AgentWidget?
    /// role == .scheduledTask 时挂载的定时任务快照。其它 role 一定 nil。
    /// 与 widget 不同，此字段**进 CodingKeys 持久化**，
    /// 让"我在这里安排了一个定时任务"的记录随会话保留。
    var scheduledTask: AgentScheduledTaskCard?
    let createdAt: Date

    nonisolated init(
        id: UUID = UUID(),
        role: AgentRole,
        content: String,
        reasoningContent: String? = nil,
        images: [AgentImageAttachment] = [],
        textAttachments: [AgentTextAttachment] = [],
        modelContext: String? = nil,
        toolCalls: [AgentMessageToolCall] = [],
        toolCallID: String? = nil,
        toolCallStatus: AgentToolCallStatus? = nil,
        toolErrorMessage: String? = nil,
        usageTokens: Int? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cachedPromptTokens: Int? = nil,
        cacheWritePromptTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        elapsedSeconds: Double? = nil,
        source: AgentMessageSource? = nil,
        transcriptEvent: AgentTranscriptEvent? = nil,
        origin: AgentMessageOrigin? = nil,
        originLabel: String? = nil,
        requestPrefixHash: String? = nil,
        requestStablePrefixCharacters: Int? = nil,
        managedRoute: AgentManagedRouteDecision? = nil,
        workflowReport: WorkflowReport? = nil,
        widget: AgentWidget? = nil,
        scheduledTask: AgentScheduledTaskCard? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.images = images
        self.textAttachments = textAttachments
        self.modelContext = modelContext
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolCallStatus = toolCallStatus
        self.toolErrorMessage = toolErrorMessage
        self.usageTokens = usageTokens
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.cacheWritePromptTokens = cacheWritePromptTokens
        self.reasoningTokens = reasoningTokens
        self.elapsedSeconds = elapsedSeconds
        self.source = source
        self.transcriptEvent = transcriptEvent
        self.origin = origin
        self.originLabel = originLabel
        self.requestPrefixHash = requestPrefixHash
        self.requestStablePrefixCharacters = requestStablePrefixCharacters
        self.managedRoute = managedRoute
        self.workflowReport = workflowReport
        self.widget = widget
        self.scheduledTask = scheduledTask
        self.createdAt = createdAt
    }

    /// Explicit keys so newer fields can use `decodeIfPresent` without
    /// breaking older session JSON.
    enum CodingKeys: String, CodingKey {
        case id, role, content, reasoningContent, images, textAttachments, modelContext, toolCalls, toolCallID
        case toolCallStatus, toolErrorMessage
        case usageTokens, promptTokens, completionTokens
        case cachedPromptTokens, cacheWritePromptTokens, reasoningTokens
        case elapsedSeconds, source, transcriptEvent
        case origin, originLabel, requestPrefixHash, requestStablePrefixCharacters
        case managedRoute, workflowReport
        case scheduledTask
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
        modelContext = try container.decodeIfPresent(String.self, forKey: .modelContext)
        toolCalls = try container.decodeIfPresent([AgentMessageToolCall].self, forKey: .toolCalls) ?? []
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        toolCallStatus = try container.decodeIfPresent(AgentToolCallStatus.self, forKey: .toolCallStatus)
        toolErrorMessage = try container.decodeIfPresent(String.self, forKey: .toolErrorMessage)
        usageTokens = try container.decodeIfPresent(Int.self, forKey: .usageTokens)
        promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens)
        completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens)
        cachedPromptTokens = try container.decodeIfPresent(Int.self, forKey: .cachedPromptTokens)
        cacheWritePromptTokens = try container.decodeIfPresent(Int.self, forKey: .cacheWritePromptTokens)
        reasoningTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningTokens)
        elapsedSeconds = try container.decodeIfPresent(Double.self, forKey: .elapsedSeconds)
        source = try container.decodeIfPresent(AgentMessageSource.self, forKey: .source)
        transcriptEvent = try container.decodeIfPresent(AgentTranscriptEvent.self, forKey: .transcriptEvent)
        origin = try container.decodeIfPresent(AgentMessageOrigin.self, forKey: .origin)
        originLabel = try container.decodeIfPresent(String.self, forKey: .originLabel)
        requestPrefixHash = try container.decodeIfPresent(String.self, forKey: .requestPrefixHash)
        requestStablePrefixCharacters = try container.decodeIfPresent(Int.self, forKey: .requestStablePrefixCharacters)
        managedRoute = try container.decodeIfPresent(AgentManagedRouteDecision.self, forKey: .managedRoute)
        workflowReport = try container.decodeIfPresent(WorkflowReport.self, forKey: .workflowReport)
        scheduledTask = try container.decodeIfPresent(AgentScheduledTaskCard.self, forKey: .scheduledTask)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

extension AgentMessage {
    nonisolated var isLocalTranscriptEvent: Bool {
        transcriptEvent != nil
    }

    /// Older sessions predate `source`; recognize the one host-only prompt
    /// that was previously persisted as a visible user message so reopening a
    /// conversation does not keep showing text the operator never typed.
    nonisolated var isHostInstruction: Bool {
        guard role == .user else { return false }
        if source == .hostInstruction { return true }
        return content.hasPrefix("Plan approved. Execute the complete plan step by step.")
            || content.hasPrefix("Plan approved. Please proceed with executing the plan step by step.")
    }

    nonisolated var isOperatorInput: Bool {
        role == .user && !isHostInstruction
    }

    /// Content as sent to providers. UI renderers use `content` plus
    /// compact attachment chips; wire encoding appends full pasted text and
    /// the persisted hidden host context so the model receives both while the
    /// transcript remains unchanged.
    nonisolated var modelContent: String {
        let trimmedModelContext = modelContext?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !textAttachments.isEmpty || trimmedModelContext?.isEmpty == false else {
            return content
        }
        var blocks: [String] = []
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            blocks.append(content)
        }
        blocks.append(contentsOf: textAttachments.map(\.modelBlock))
        if let modelContext = trimmedModelContext,
           !modelContext.isEmpty {
            blocks.append(modelContext)
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Clipboard-friendly full text for copy buttons and standalone
    /// readers: visible text first, then pasted-text attachments.
    nonisolated var copyableContent: String {
        // Workflow 卡片消息 content 恒为空,可复制的正文是 engine
        // synthesize 出的最终报告(report.summary)。
        if role == .workflowReport, let report = workflowReport {
            return report.summary
        }
        let visibleContent: String
        if role == .user {
            let display = AgentAttachedPromptDisplay.transform(content)
            let source = display.isSplicedPrelude ? display.visibleContent : content
            visibleContent = AgentUserContentSplitter.split(source).visible
        } else {
            visibleContent = content
        }

        guard !textAttachments.isEmpty else { return visibleContent }
        var blocks: [String] = []
        let trimmed = visibleContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            blocks.append(visibleContent)
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

/// Presentation metadata for every visible assistant message produced after
/// one user input. Provider tool loops can emit several assistant messages,
/// but the transcript presents them as one user-facing turn.
nonisolated struct AgentAssistantTurnPresentation {
    let userMessageID: AgentMessage.ID?
    let firstVisibleAssistantMessageID: AgentMessage.ID
    let lastVisibleAssistantMessageID: AgentMessage.ID
    let summaryMessage: AgentMessage

    func isFirstVisibleMessage(_ message: AgentMessage) -> Bool {
        message.id == firstVisibleAssistantMessageID
    }

    func isLastVisibleMessage(_ message: AgentMessage) -> Bool {
        message.id == lastVisibleAssistantMessageID
    }
}

nonisolated enum AgentAssistantTurnGrouping {
    static func presentations(
        in messages: [AgentMessage],
        aggregatesCopyContent: Bool = true,
        visibleAssistantMessageIDs: Set<AgentMessage.ID>? = nil
    ) -> [AgentMessage.ID: AgentAssistantTurnPresentation] {
        var result: [AgentMessage.ID: AgentAssistantTurnPresentation] = [:]
        var userMessage: AgentMessage?
        var assistantMessages: [AgentMessage] = []

        for message in messages {
            if message.role == .user {
                appendPresentation(
                    userMessage: userMessage,
                    assistantMessages: assistantMessages,
                    aggregatesCopyContent: aggregatesCopyContent,
                    visibleAssistantMessageIDs: visibleAssistantMessageIDs,
                    to: &result
                )
                userMessage = message
                assistantMessages.removeAll(keepingCapacity: true)
            } else if message.role == .assistant {
                assistantMessages.append(message)
            }
        }
        appendPresentation(
            userMessage: userMessage,
            assistantMessages: assistantMessages,
            aggregatesCopyContent: aggregatesCopyContent,
            visibleAssistantMessageIDs: visibleAssistantMessageIDs,
            to: &result
        )
        return result
    }

    static func presentation(
        for messageID: AgentMessage.ID,
        in messages: [AgentMessage],
        aggregatesCopyContent: Bool = false
    ) -> AgentAssistantTurnPresentation? {
        presentations(in: messages, aggregatesCopyContent: aggregatesCopyContent)[messageID]
    }

    private static func appendPresentation(
        userMessage: AgentMessage?,
        assistantMessages: [AgentMessage],
        aggregatesCopyContent: Bool,
        visibleAssistantMessageIDs: Set<AgentMessage.ID>?,
        to result: inout [AgentMessage.ID: AgentAssistantTurnPresentation]
    ) {
        let visibleMessages = assistantMessages.filter { message in
            isVisibleAssistantMessage(message)
                && (visibleAssistantMessageIDs?.contains(message.id) ?? true)
        }
        guard let first = visibleMessages.first, let last = visibleMessages.last else { return }
        let presentation = AgentAssistantTurnPresentation(
            userMessageID: userMessage?.id,
            firstVisibleAssistantMessageID: first.id,
            lastVisibleAssistantMessageID: last.id,
            summaryMessage: summaryMessage(
                userMessage: userMessage,
                assistantMessages: assistantMessages,
                visibleMessages: visibleMessages,
                aggregatesCopyContent: aggregatesCopyContent
            )
        )
        for message in visibleMessages {
            result[message.id] = presentation
        }
    }

    private static func isVisibleAssistantMessage(_ message: AgentMessage) -> Bool {
        !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !message.images.isEmpty
    }

    private static func summaryMessage(
        userMessage: AgentMessage?,
        assistantMessages: [AgentMessage],
        visibleMessages: [AgentMessage],
        aggregatesCopyContent: Bool
    ) -> AgentMessage {
        var summary = visibleMessages[visibleMessages.count - 1]
        if aggregatesCopyContent {
            summary.content = visibleMessages
                .map { message in
                    AgentTurnProgressPresentation.extract(
                        from: message.copyableContent,
                        plan: nil
                    ).visibleContent
                }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
        }
        summary.usageTokens = sum(assistantMessages, \.usageTokens)
        summary.promptTokens = sum(assistantMessages, \.promptTokens)
        summary.completionTokens = sum(assistantMessages, \.completionTokens)
        summary.cachedPromptTokens = sum(assistantMessages, \.cachedPromptTokens)
        summary.cacheWritePromptTokens = sum(assistantMessages, \.cacheWritePromptTokens)
        summary.reasoningTokens = sum(assistantMessages, \.reasoningTokens)
        summary.elapsedSeconds = totalElapsedSeconds(
            userMessage: userMessage,
            assistantMessages: assistantMessages
        )
        summary.managedRoute = assistantMessages.reversed().compactMap(\.managedRoute).first
        return summary
    }

    private static func sum(
        _ messages: [AgentMessage],
        _ keyPath: KeyPath<AgentMessage, Int?>
    ) -> Int? {
        let values = messages.compactMap { $0[keyPath: keyPath] }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    private static func totalElapsedSeconds(
        userMessage: AgentMessage?,
        assistantMessages: [AgentMessage]
    ) -> Double? {
        guard let first = assistantMessages.first else { return nil }
        let startedAt = userMessage?.createdAt ?? first.createdAt
        let providerElapsed = assistantMessages.compactMap(\.elapsedSeconds).filter { $0 > 0 }
        let completedAt = assistantMessages
            .map { $0.createdAt.addingTimeInterval(max(0, $0.elapsedSeconds ?? 0)) }
            .max() ?? first.createdAt
        let wallClockElapsed = completedAt.timeIntervalSince(startedAt)
        guard wallClockElapsed > 0 || !providerElapsed.isEmpty else { return nil }
        return max(wallClockElapsed, providerElapsed.reduce(0, +))
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
    var source: AgentMessageSource

    init(
        id: UUID = UUID(),
        text: String,
        images: [AgentImageAttachment] = [],
        textAttachments: [AgentTextAttachment] = [],
        attachedSkills: [AgentSkillEntry] = [],
        executionAgent: AgentExecutionAgent = .willDeep,
        source: AgentMessageSource = .operatorInput
    ) {
        self.id = id
        self.text = text
        self.images = images
        self.textAttachments = textAttachments
        self.attachedSkills = attachedSkills
        self.executionAgent = executionAgent
        self.source = source
    }
}
