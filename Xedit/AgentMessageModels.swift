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
    /// 设计门拦下一个回合、模型写完设计文档之后塞进 transcript 的卡片。
    /// `content` 留空，文档路径与命中的信号挂在 `specProposal` 字段上，
    /// 渲染走 AgentSpecProposalCardView。与 scheduledTask 一样**不发给
    /// LLM**且**会持久化**——用户可能关掉 App 明天再来决定。
    ///
    /// 与前两种卡片不同的是它**状态可变**（待决定 → 已采纳 / 已跳过），
    /// 所以它的展示字段必须进 messageHash，否则卡片会永远停在初始状态。
    case specProposal
}

nonisolated enum AgentMessageOrigin: String, Codable, Equatable {
    case nativeModel
    case delegatedExternal
    /// A visible host notice, not an inference attempt or completion claim.
    case hostGenerated
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
    /// Legacy event retained so old transcripts remain decodable.
    case autoPlanModeEntered
}

nonisolated enum AgentImageAttachmentSource: String, Codable, Equatable, Sendable {
    case userUpload
    case generated
    case capture
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
    /// Tool that produced this image, stamped when a tool result's images
    /// are lifted onto the assistant message. While a turn runs, images sit
    /// on their tool card and the origin is obvious; once the turn settles
    /// the card collapses and the picture would otherwise float free of
    /// whatever produced it. Nil for user uploads and for images recorded
    /// before this field existed.
    var originToolName: String?

    init(
        id: UUID = UUID(),
        mimeType: String,
        dataBase64: String,
        source: AgentImageAttachmentSource? = nil,
        filePath: String? = nil,
        model: String? = nil,
        prompt: String? = nil,
        createdAt: Date? = nil,
        originToolName: String? = nil
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
        self.originToolName = originToolName
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
        createdAt: Date? = nil,
        originToolName: String? = nil
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
        self.originToolName = originToolName
    }

    enum CodingKeys: String, CodingKey {
        case id, mimeType, dataBase64, filePath, byteCount, sha256, source, model, prompt, createdAt
        case originToolName
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
        originToolName = try container.decodeIfPresent(String.self, forKey: .originToolName)
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
        try container.encodeIfPresent(originToolName, forKey: .originToolName)
    }

    /// Decoded inline bytes, if any — nil for purely file-backed images.
    /// Unlike `dataBase64`, this never touches disk, so it is safe on
    /// render-frequency paths.
    nonisolated var inlineImageData: Data? {
        inlineDataBase64.flatMap { Data(base64Encoded: $0) }
    }

    nonisolated var inlineImageEncodedByteCount: Int { inlineDataBase64?.utf8.count ?? 0 }

    /// Exact application-owned upload location, not any path whose parent
    /// happens to be named AgentAttachments.
    nonisolated var isInOwnedAttachmentStorage: Bool {
        guard let fileURL, let directory = try? Self.attachmentDirectory(for: id) else { return false }
        return fileURL == directory.appendingPathComponent("image.\(Self.fileExtension(for: mimeType))").standardizedFileURL
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

    /// One-line provenance shown under a content-sized image: which tool
    /// took it, or which model generated it. Nil when there is nothing to
    /// say beyond "the user attached this".
    nonisolated var originCaption: String? {
        if let toolName = originToolName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !toolName.isEmpty {
            return "↳ \(toolName)"
        }
        if source == .generated,
           let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            return "↳ \(model)"
        }
        return nil
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
        let isLegacyAgentAttachment = directory.lastPathComponent == id.uuidString
            && directory.deletingLastPathComponent().lastPathComponent == "AgentAttachments"
        let isWillDeepCapture = directory.lastPathComponent == id.uuidString.lowercased()
            && directory.deletingLastPathComponent().lastPathComponent == "captures"
            && directory
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .lastPathComponent == ".willdeep"
        guard isLegacyAgentAttachment || isWillDeepCapture else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }

    /// The app-owned directory for one attachment. Also the fallback store for
    /// MCP tool-result media when `~/.willdeep/captures` is not writable.
    nonisolated static func attachmentDirectory(for id: UUID) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest") != nil
            || environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            // Like the session store, tests must never create upload assets in
            // the user's Application Support directory.
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("WillDeepTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
                .appendingPathComponent("AgentAttachments", isDirectory: true)
                .appendingPathComponent(id.uuidString, isDirectory: true)
        }
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
/// What one finished `spawn_agent` child loop cost and whether it worked.
///
/// This lives on the parent's tool call rather than only in the transcript
/// sidecar because the stats dashboard is a pure function over session
/// snapshots. Without it every token a worker spends is invisible to the
/// model-usage table — the exact blind spot that makes a cheap-model tier
/// look free while the bill says otherwise.
nonisolated struct AgentSubagentRunUsage: Codable, Equatable, Sendable {
    /// Trade that ran (`scout` / `test_fixer` / …).
    var profileID: String
    /// Model that actually produced the report. After an escalation this is
    /// the parent's model, not the trade's cheap binding.
    var model: String
    var providerID: String?
    /// Total tokens across every round of the child loop.
    var usageTokens: Int
    /// Prompt/completion split summed over the run's rounds. Zero when the
    /// provider reported only a total; the dashboard then falls back to its
    /// estimator rather than pricing a guessed ratio as if it were measured.
    var promptTokens: Int
    var completionTokens: Int
    var cachedPromptTokens: Int
    var roundCount: Int
    var toolInvocationCount: Int
    /// Model escalated away from, when a cheap trade stalled and the run was
    /// re-run on the parent's model. Nil when no escalation happened.
    var escalatedFromModel: String?
    /// Verifier verdict for the run. Nil when the run had no verifier at all;
    /// nil and `false` must stay distinct, because "never verified" is not
    /// "verified and failed" and the two belong in different KPI buckets.
    var verifierPassed: Bool?
    /// Citations the runtime spot-checked in a report-only run, and how many
    /// pointed at nothing. Nil when no check ran. Report-only trades never
    /// earn a verifier verdict, so without these the dashboard has nothing to
    /// say about them at all — and silence there reads as "fine".
    var citationsChecked: Int?
    var citationsUnverifiable: Int?

    init(
        profileID: String,
        model: String,
        providerID: String? = nil,
        usageTokens: Int = 0,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        cachedPromptTokens: Int = 0,
        roundCount: Int = 0,
        toolInvocationCount: Int = 0,
        escalatedFromModel: String? = nil,
        verifierPassed: Bool? = nil,
        citationsChecked: Int? = nil,
        citationsUnverifiable: Int? = nil
    ) {
        self.profileID = profileID
        self.model = model
        self.providerID = providerID
        self.usageTokens = usageTokens
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.roundCount = roundCount
        self.toolInvocationCount = toolInvocationCount
        self.escalatedFromModel = escalatedFromModel
        self.verifierPassed = verifierPassed
        self.citationsChecked = citationsChecked
        self.citationsUnverifiable = citationsUnverifiable
    }
}

/// One worker invocation started by WillDeep's host runtime rather than by a
/// provider-emitted `spawn_agent` tool call.
///
/// Model-requested workers persist on `AgentMessageToolCall`. Automatic
/// preflights and failed-command repairs have no provider tool-call id to
/// attach to, so they need a parallel session ledger or they disappear from
/// usage statistics after the live card is gone.
nonisolated struct AgentHostWorkerRunRecord: Identifiable, Codable, Equatable, Sendable {
    enum Source: String, Codable, Equatable, Sendable {
        case requestPreflight
        case codingPlanCacheHit
        case failedCommandRepair
        case automaticCoding
        case automaticCodingEscalation
        case automaticCodingReview
        case goalVerification
        /// Read-only worker started in parallel with the root model's first
        /// request; its report is injected at a tool boundary of the same
        /// turn or dropped when the turn ends first.
        case speculativeScout
    }

    enum Status: String, Codable, Equatable, Sendable {
        case proposed
        case running
        case succeeded
        case failed
        case denied
    }

    let id: UUID
    /// Operator message that caused this dispatch. It lets analytics measure
    /// eligible user turns instead of dividing by every assistant message.
    var userMessageID: UUID?
    var profileID: String
    var source: Source
    var status: Status
    var requestedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    /// Effective child-loop model, known even when the loop fails before it
    /// can return token accounting.
    var model: String?
    var providerID: String?
    var usage: AgentSubagentRunUsage?
    /// Set after the independent review gate. Nil means this run was not a
    /// coding candidate or never reached a delivery decision.
    var acceptedOutput: Bool?
    /// True when the automatic lane handed the partially completed turn back
    /// to the parent model for diagnosis or repair.
    var requiredParentRepair: Bool?

    init(
        id: UUID = UUID(),
        userMessageID: UUID? = nil,
        profileID: String,
        source: Source,
        status: Status = .proposed,
        requestedAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        model: String? = nil,
        providerID: String? = nil,
        usage: AgentSubagentRunUsage? = nil,
        acceptedOutput: Bool? = nil,
        requiredParentRepair: Bool? = nil
    ) {
        self.id = id
        self.userMessageID = userMessageID
        self.profileID = profileID
        self.source = source
        self.status = status
        self.requestedAt = requestedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.model = model
        self.providerID = providerID
        self.usage = usage
        self.acceptedOutput = acceptedOutput
        self.requiredParentRepair = requiredParentRepair
    }
}

nonisolated struct AgentMessageToolCall: Codable, Equatable {
    var externalID: String
    var toolName: String
    var argumentsJSON: String
    /// For `spawn_agent`: the run whose per-round transcript is stored in
    /// `AgentSubagentTranscriptStore`. Persisted with the assistant message
    /// so the inspector still opens after the session is reopened. Nil for
    /// every other tool and for runs recorded before this field existed.
    var subagentRunID: UUID?
    /// Stamped when the run named by `subagentRunID` finishes. Nil while it
    /// is still running, for every non-spawn tool, and for runs recorded
    /// before worker accounting existed.
    var subagentUsage: AgentSubagentRunUsage?

    /// `argumentsJSON` as it may be replayed to an OpenAI-shaped provider:
    /// always a JSON **object** literal.
    ///
    /// The model does emit malformed arguments (truncated streams, wrong
    /// schema). The agent loop already reports those as a failed tool call
    /// and asks for a re-emit — but the request carrying that instruction
    /// replays the same broken payload, and strict upstreams reject the
    /// ENTIRE history for it (`Assistant tool call function.arguments must
    /// be valid JSON.`), so the session deadlocks: every retry re-sends the
    /// same invalid history. The raw payload is preserved for the model in
    /// the failed tool result, so repairing it here loses no evidence.
    ///
    /// Matches what `AgentClientAnthropic` and `AgentClientGemini` already
    /// do when the same payload fails to parse.
    var wireArgumentsJSON: String {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "{}" }
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              parsed is [String: Any] else {
            return "{}"
        }
        return argumentsJSON
    }
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
    /// Public references reported directly by a provider-hosted tool, such as
    /// Responses `web_search`. Client-executed tools keep their references on
    /// `AgentToolResult`; this field preserves server-side citations without
    /// inventing a local tool call.
    var sourceReferences: [AgentSourceReference]
    /// Wall-clock seconds the assistant streamed for, from first stream
    /// connect to `.finishedTurn`. Only set on assistant messages once
    /// the stream terminates.
    var elapsedSeconds: Double?
    /// Seconds from dispatch until the first visible or reasoning character.
    /// Nil means the provider/request predates this metric or emitted no text.
    var firstResponseSeconds: Double?
    /// Whether the concrete request endpoint was local at dispatch time.
    /// Persisting the resolved value avoids trying to infer custom localhost
    /// providers later from session-level settings that may have changed.
    var requestIsLocal: Bool?
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
    /// Exact client-side routing snapshot for the request that produced this
    /// assistant message. Session-level model/provider fields describe the
    /// latest selection and cannot faithfully attribute a conversation that
    /// switched models between turns. Optional for persisted legacy messages.
    var requestModelID: String?
    var requestProviderID: String?
    var requestProviderDisplayName: String?
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
    /// role == .specProposal 时挂载的设计门提案。其它 role 一定 nil。
    /// 进 CodingKeys 持久化：门可能跨 App 重启等着用户回答。
    var specProposal: AgentSpecProposal?
    /// Explicit `/subagent` / `/no-subagent` choice for the turn this user
    /// message started. Nil on every message that didn't carry an explicit
    /// directive (including all older sessions), so the transcript marker
    /// only appears where the user actually asked for it.
    var delegationPolicy: AgentDelegationPolicy?
    /// Set on a `.required` turn once it ends without any `spawn_agent`
    /// call. `/subagent` cannot be enforced in code (see
    /// `AgentDelegationPolicy`), so the marker says so rather than implying
    /// the directive was obeyed.
    var delegationPolicyUnhonored: Bool?
    let createdAt: Date

    /// Transient per-tool-call outcome receipts (externalID → 终态),
    /// keyed by `AgentMessageToolCall.externalID`. Populated only at
    /// render time by `AgentChatTranscript` from the sibling `.tool`
    /// result messages (which carry `toolCallStatus`), so the settled
    /// TextKit history can show the outcome next to each intent line
    /// instead of a bare "我要做 X". Deliberately **not** in CodingKeys:
    /// this is a presentation projection, never persisted — the source of
    /// truth is the `.tool` message's own persisted `toolCallStatus`.
    var settledToolReceipts: [String: AgentToolCallStatus]? = nil

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
        sourceReferences: [AgentSourceReference] = [],
        elapsedSeconds: Double? = nil,
        firstResponseSeconds: Double? = nil,
        requestIsLocal: Bool? = nil,
        source: AgentMessageSource? = nil,
        transcriptEvent: AgentTranscriptEvent? = nil,
        origin: AgentMessageOrigin? = nil,
        originLabel: String? = nil,
        requestModelID: String? = nil,
        requestProviderID: String? = nil,
        requestProviderDisplayName: String? = nil,
        requestPrefixHash: String? = nil,
        requestStablePrefixCharacters: Int? = nil,
        managedRoute: AgentManagedRouteDecision? = nil,
        workflowReport: WorkflowReport? = nil,
        widget: AgentWidget? = nil,
        scheduledTask: AgentScheduledTaskCard? = nil,
        delegationPolicy: AgentDelegationPolicy? = nil,
        delegationPolicyUnhonored: Bool? = nil,
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
        self.sourceReferences = sourceReferences
        self.elapsedSeconds = elapsedSeconds
        self.firstResponseSeconds = firstResponseSeconds
        self.requestIsLocal = requestIsLocal
        self.source = source
        self.transcriptEvent = transcriptEvent
        self.origin = origin
        self.originLabel = originLabel
        self.requestModelID = requestModelID
        self.requestProviderID = requestProviderID
        self.requestProviderDisplayName = requestProviderDisplayName
        self.requestPrefixHash = requestPrefixHash
        self.requestStablePrefixCharacters = requestStablePrefixCharacters
        self.managedRoute = managedRoute
        self.workflowReport = workflowReport
        self.widget = widget
        self.scheduledTask = scheduledTask
        self.delegationPolicy = delegationPolicy
        self.delegationPolicyUnhonored = delegationPolicyUnhonored
        self.createdAt = createdAt
    }

    /// Explicit keys so newer fields can use `decodeIfPresent` without
    /// breaking older session JSON.
    enum CodingKeys: String, CodingKey {
        case id, role, content, reasoningContent, images, textAttachments, modelContext, toolCalls, toolCallID
        case toolCallStatus, toolErrorMessage
        case usageTokens, promptTokens, completionTokens
        case cachedPromptTokens, cacheWritePromptTokens, reasoningTokens, sourceReferences
        case elapsedSeconds, firstResponseSeconds, requestIsLocal, source, transcriptEvent
        case origin, originLabel, requestModelID, requestProviderID, requestProviderDisplayName
        case requestPrefixHash, requestStablePrefixCharacters
        case managedRoute, workflowReport
        case scheduledTask, specProposal
        case delegationPolicy, delegationPolicyUnhonored
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
        sourceReferences = try container.decodeIfPresent([AgentSourceReference].self, forKey: .sourceReferences) ?? []
        elapsedSeconds = try container.decodeIfPresent(Double.self, forKey: .elapsedSeconds)
        firstResponseSeconds = try container.decodeIfPresent(Double.self, forKey: .firstResponseSeconds)
        requestIsLocal = try container.decodeIfPresent(Bool.self, forKey: .requestIsLocal)
        source = try container.decodeIfPresent(AgentMessageSource.self, forKey: .source)
        transcriptEvent = try container.decodeIfPresent(AgentTranscriptEvent.self, forKey: .transcriptEvent)
        origin = try container.decodeIfPresent(AgentMessageOrigin.self, forKey: .origin)
        originLabel = try container.decodeIfPresent(String.self, forKey: .originLabel)
        requestModelID = try container.decodeIfPresent(String.self, forKey: .requestModelID)
        requestProviderID = try container.decodeIfPresent(String.self, forKey: .requestProviderID)
        requestProviderDisplayName = try container.decodeIfPresent(
            String.self,
            forKey: .requestProviderDisplayName
        )
        requestPrefixHash = try container.decodeIfPresent(String.self, forKey: .requestPrefixHash)
        requestStablePrefixCharacters = try container.decodeIfPresent(Int.self, forKey: .requestStablePrefixCharacters)
        managedRoute = try container.decodeIfPresent(AgentManagedRouteDecision.self, forKey: .managedRoute)
        workflowReport = try container.decodeIfPresent(WorkflowReport.self, forKey: .workflowReport)
        scheduledTask = try container.decodeIfPresent(AgentScheduledTaskCard.self, forKey: .scheduledTask)
        specProposal = try container.decodeIfPresent(AgentSpecProposal.self, forKey: .specProposal)
        delegationPolicy = try container.decodeIfPresent(AgentDelegationPolicy.self, forKey: .delegationPolicy)
        delegationPolicyUnhonored = try container.decodeIfPresent(Bool.self, forKey: .delegationPolicyUnhonored)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

extension AgentMessage {
    /// Whether `content` contains at least one user-visible scalar.
    ///
    /// OpenAI-compatible providers may stream newlines before a tool call and
    /// persist them as the assistant content. Treating that payload with
    /// `String.isEmpty` makes a tool-only round look like a prose reply and
    /// leaves an empty status/footer shell in the transcript.
    nonisolated var hasRenderableTextContent: Bool {
        content.unicodeScalars.contains { !$0.properties.isWhitespace }
    }

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

    /// Verbatim prose the operator typed, with every host-generated wrapper
    /// removed. Human-facing summaries (session titles, approval rows, pet
    /// bubbles) must use this instead of raw `content`: composer attachments
    /// splice their security prelude into `content`, and image analysis adds
    /// another generated block after the prose.
    nonisolated var userAuthoredText: String {
        guard isOperatorInput else { return "" }
        let display = AgentAttachedPromptDisplay.transform(content)
        let withoutAttachmentPrelude = display.isSplicedPrelude
            ? display.userAuthoredText
            : content
        return AgentUserContentSplitter.split(withoutAttachmentPrelude).visible
    }

    /// The text the operator actually authored this turn: visible content
    /// plus pasted-text attachments, WITHOUT the hidden per-turn host
    /// context (`modelContext`). Turn-end learning/audit must mine this,
    /// never `modelContent` — the wire encoding appends harness guidance,
    /// and mining it stores prompt scaffolding as if the human said it
    /// (a bare "hello" turn once suggested two "memories" quoting the
    /// session-title and unattended-run guidance verbatim).
    nonisolated var operatorAuthoredContent: String {
        // 1.287.0-rc6:host 合成文本不止 modelContext 一处 —— composer 附件
        // 会把 preludeHeader + skill/file 块直接拼进 `content` 本体(spliced
        // prelude),图片理解也会往 content 末尾追加生成的描述块。1.238.1
        // 只挡了 modelContext,于是「The user attached the following
        // context…」连同附件技能的 description 被当成用户工作流捕获,
        // 落盘成 ~/.willdeep/skills/auto-the-user-attached-the。这里统一
        // 反拼接:spliced prelude 只认边界标记之后用户真正敲的字(注意读
        // `userAuthoredText`,不是带附件标签行的 `visibleContent`),图片
        // 描述块同样剥掉;用户粘贴的 textAttachments 仍按 1.238.1 口径保留。
        let authoredBody = userAuthoredText
        guard !textAttachments.isEmpty else { return authoredBody }
        var blocks: [String] = []
        if !authoredBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(authoredBody)
        }
        blocks.append(contentsOf: textAttachments.map(\.modelBlock))
        return blocks.joined(separator: "\n\n")
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

/// A single UI-safe line taken only from text the operator typed. Keeping the
/// extraction here prevents small secondary surfaces from accidentally using
/// raw model-facing prompts or auto-derived session titles.
nonisolated enum AgentUserInputPreview {
    static func first(in messages: [AgentMessage]) -> String? {
        preview(from: messages.first(where: \.isOperatorInput))
    }

    static func latest(in messages: [AgentMessage]) -> String? {
        preview(from: messages.last(where: \.isOperatorInput))
    }

    static func preview(from message: AgentMessage?) -> String? {
        guard let message else { return nil }
        let compact = message.userAuthoredText
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return compact.isEmpty ? nil : compact
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
    /// 这一轮 Agent 输出结束的时刻（各条回复 createdAt + 耗时的最大值）。
    let completedAt: Date

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
            ),
            completedAt: completedAt(of: assistantMessages) ?? last.createdAt
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

    static func completedAt(of assistantMessages: [AgentMessage]) -> Date? {
        assistantMessages
            .map { $0.createdAt.addingTimeInterval(max(0, $0.elapsedSeconds ?? 0)) }
            .max()
    }

    private static func totalElapsedSeconds(
        userMessage: AgentMessage?,
        assistantMessages: [AgentMessage]
    ) -> Double? {
        guard let first = assistantMessages.first else { return nil }
        let startedAt = userMessage?.createdAt ?? first.createdAt
        let providerElapsed = assistantMessages.compactMap(\.elapsedSeconds).filter { $0 > 0 }
        let completedAt = completedAt(of: assistantMessages) ?? first.createdAt
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
    /// `/subagent` / `/no-subagent` staged for this message. Queued while the
    /// runtime was busy, so the directive has to ride along — otherwise it
    /// would silently degrade to `.automatic` on drain.
    var delegationPolicy: AgentDelegationPolicy

    init(
        id: UUID = UUID(),
        text: String,
        images: [AgentImageAttachment] = [],
        textAttachments: [AgentTextAttachment] = [],
        attachedSkills: [AgentSkillEntry] = [],
        executionAgent: AgentExecutionAgent = .willDeep,
        source: AgentMessageSource = .operatorInput,
        delegationPolicy: AgentDelegationPolicy = .automatic
    ) {
        self.id = id
        self.text = text
        self.images = images
        self.textAttachments = textAttachments
        self.attachedSkills = attachedSkills
        self.executionAgent = executionAgent
        self.source = source
        self.delegationPolicy = delegationPolicy
    }
}
