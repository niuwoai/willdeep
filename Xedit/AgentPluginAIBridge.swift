//
//  AgentPluginAIBridge.swift
//  WillDeep
//
//  插件页面调模型的桥。插件系统和一张 H5 页面的分界线就在这里：页面能问模型，
//  但一把 API key 都拿不到，也选不了用户 provider 库之外的任何端点。
//
//  三条不许松的口子：
//  1. 密钥永远不出宿主。页面拿到的 provider 清单只有 id / 名称 / 模型名。
//  2. provider 与模型必须落在用户自己配置的库里（本地 Ollama 也算一条），
//     页面递上来的 baseURL 一律不认——否则插件就能把用户的对话发去任意端点。
//  3. 载荷有硬上限（条数、字数、并发），插件不能借这条路把用户的额度烧干。
//     输出长度不在这里管：它由 provider adapter 按用户自己的设置决定，
//     页面无从指定——2026-09 前这里曾收一个 `maxOutputTokens` 却从不使用，
//     现已连同文档一起删除。
//

import Foundation

nonisolated struct AgentPluginAIMessage: Equatable, Sendable {
    let role: AgentRole
    let content: String
}

nonisolated struct AgentPluginAIRequest: Equatable, Sendable {
    var messages: [AgentPluginAIMessage]
    /// nil = 用默认 provider 的 flash 档（和压缩、审核解释走同一条辅助路线）
    var providerID: String?
    var model: String?
    /// 页面用 `$` 选中的技能。这里只存 identifier，正文由宿主读取并注入——
    /// 页面既拿不到 SKILL.md 全文，也拿不到它在磁盘上的位置。
    var skillIdentifiers: [String] = []
    /// 页面自己生成的流式标识。非空时宿主把模型的增量文本按这个 id 回推给
    /// 页面，让它能一边等一边显示，而不是对着一个转圈等十几秒。
    var streamID: String?

    static let maximumMessages = 24
    static let maximumCharacters = 32_000
    /// 同一个插件页面同时在跑的对话数。共创页会连着点「生成」，没有这道闸
    /// 就能并行发出任意多条请求，用户的额度是按条烧的。
    static let maximumConcurrentRequests = 2
    /// 主聊天那条路对「一条消息挂几个技能」没有上限，用户从 popover 连点就能
    /// 挂 N 个，N × 24k 全进 prompt。这条通道是给插件页面的，一开始就封死。
    static let maximumSkills = 3
    static let maximumSkillCharacters = 8_000
}

/// 递给页面的技能描述。刻意不带 `url`：技能在磁盘上的位置是宿主的事，
/// 页面只需要一个能回传的 identifier。
nonisolated struct AgentPluginSkillDescriptor: Equatable, Sendable {
    let identifier: String
    let name: String
    let description: String
    let source: String
    let tier: String?

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "identifier": identifier,
            "name": name,
            "description": description,
            "source": source,
        ]
        if let tier { object["tier"] = tier }
        return object
    }
}

nonisolated struct AgentPluginAIResult: Equatable, Sendable {
    let text: String
    let model: String
    let providerID: String
}

nonisolated struct AgentPluginImageRequest: Equatable, Sendable {
    let prompt: String
    let model: String
    let size: String

    static let allowedModels = ["gpt-image-2", "nano-banana-2"]
    static let allowedSizes = ["1024x1024", "1536x1024", "1024x1536"]
    static let maximumCharacters = 8_000
}

nonisolated struct AgentPluginImageResult: Equatable, Sendable {
    let mediaURL: String
    let filePath: String
    let model: String
    let providerID: String
}

/// 递给页面的 provider 描述。刻意不带 baseURL 与任何密钥字段。
nonisolated struct AgentPluginAIProviderDescriptor: Equatable, Sendable {
    let providerID: String
    let displayName: String
    let isActive: Bool
    let isLocal: Bool
    let models: [String]
    let flashModel: String

    var jsonObject: [String: Any] {
        [
            "providerID": providerID,
            "displayName": displayName,
            "isActive": isActive,
            "isLocal": isLocal,
            "models": models,
            "flashModel": flashModel,
        ]
    }
}

nonisolated enum AgentPluginAIError: Error, Equatable, LocalizedError {
    case permissionDenied
    case imagePermissionDenied
    case skillPermissionDenied
    case tooManySkills
    case unknownSkill(String)
    case emptyRequest
    case tooManyMessages
    case tooLong
    case unknownProvider(String)
    case unknownModel(String)
    case unavailable
    case emptyResponse
    case tooManyConcurrentRequests
    case cancelled
    case invalidImageRequest
    case invalidImageModel(String)
    case invalidImageSize(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "This plugin did not declare the ai.chat permission."
        case .imagePermissionDenied: return "This plugin did not declare the ai.image permission."
        case .skillPermissionDenied: return "This plugin did not declare the skills.read permission."
        case .tooManySkills: return "At most \(AgentPluginAIRequest.maximumSkills) skills can be attached to one request."
        case .unknownSkill(let identifier): return "No enabled skill matches: \(identifier)"
        case .emptyRequest: return "The request carried no messages."
        case .tooManyMessages: return "Too many messages in one request."
        case .tooLong: return "The request is too long."
        case .unknownProvider(let id): return "Unknown provider: \(id)"
        case .unknownModel(let model): return "Model is not in this provider's list: \(model)"
        case .unavailable: return "No usable model is configured."
        case .emptyResponse: return "The model returned nothing."
        case .tooManyConcurrentRequests:
            return "At most \(AgentPluginAIRequest.maximumConcurrentRequests) AI requests can run at once on one page."
        case .cancelled: return "The request was cancelled."
        case .invalidImageRequest: return "The image prompt is empty or too long."
        case .invalidImageModel(let model): return "Unsupported some.im image model: \(model)"
        case .invalidImageSize(let size): return "Unsupported image size: \(size)"
        }
    }
}

nonisolated enum AgentPluginImageRequestValidator {
    static func request(from raw: [String: Any]) -> Result<AgentPluginImageRequest, AgentPluginAIError> {
        let prompt = (raw["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= AgentPluginImageRequest.maximumCharacters else {
            return .failure(.invalidImageRequest)
        }
        let provider = (raw["provider"] as? String ?? raw["providerID"] as? String ?? "some-im")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider == "some-im" else { return .failure(.unknownProvider(provider)) }
        let model = (raw["model"] as? String ?? AgentPluginImageRequest.allowedModels[0])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentPluginImageRequest.allowedModels.contains(model) else {
            return .failure(.invalidImageModel(model))
        }
        let size = (raw["size"] as? String ?? AgentPluginImageRequest.allowedSizes[0])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentPluginImageRequest.allowedSizes.contains(size) else {
            return .failure(.invalidImageSize(size))
        }
        return .success(AgentPluginImageRequest(prompt: prompt, model: model, size: size))
    }
}

/// 纯函数校验：把页面递上来的 JSON 变成请求，或者给出拒绝理由。
/// 单独拎出来是为了能不起模型、不起 WebView 地测它。
nonisolated enum AgentPluginAIRequestValidator {
    static func request(from raw: [String: Any]) -> Result<AgentPluginAIRequest, AgentPluginAIError> {
        var messages: [AgentPluginAIMessage] = []
        if let system = (raw["system"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !system.isEmpty {
            messages.append(AgentPluginAIMessage(role: .system, content: system))
        }
        for entry in raw["messages"] as? [[String: Any]] ?? [] {
            guard let content = entry["content"] as? String else { continue }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let role: AgentRole
            switch (entry["role"] as? String)?.lowercased() {
            case "system": role = .system
            case "assistant": role = .assistant
            default: role = .user
            }
            messages.append(AgentPluginAIMessage(role: role, content: trimmed))
        }
        guard !messages.isEmpty else { return .failure(.emptyRequest) }
        guard messages.count <= AgentPluginAIRequest.maximumMessages else {
            return .failure(.tooManyMessages)
        }
        let characters = messages.reduce(0) { $0 + $1.content.count }
        guard characters <= AgentPluginAIRequest.maximumCharacters else { return .failure(.tooLong) }

        var request = AgentPluginAIRequest(messages: messages)
        request.providerID = (raw["provider"] as? String ?? raw["providerID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilWhenEmpty
        request.model = (raw["model"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilWhenEmpty
        var identifiers: [String] = []
        for entry in raw["skills"] as? [Any] ?? [] {
            guard let token = (entry as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty, token.count <= 200 else { continue }
            // 去重，否则页面可以把同一个技能挂三遍来绕过条数上限。
            if !identifiers.contains(token) { identifiers.append(token) }
        }
        guard identifiers.count <= AgentPluginAIRequest.maximumSkills else {
            return .failure(.tooManySkills)
        }
        request.skillIdentifiers = identifiers
        request.streamID = (raw["streamID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(160)
            .description
            .nilWhenEmpty
        return .success(request)
    }
}

nonisolated private extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}

private actor AgentPluginAITextBuffer {
    private var text = ""
    func append(_ delta: String) { text += delta }
    func value() -> String { text }
}

@MainActor
extension AppState {
    /// 页面能选的 provider：用户自己配的那些，加上本地 Ollama（如果开着）。
    func pluginAIProviders() async -> [AgentPluginAIProviderDescriptor] {
        for id in agentProviderLibrary.entries.map(\.id) {
            materializeProviderLibraryEntryAPIKey(id: id)
        }
        let entries = agentProviderLibrary.entries
        let discoveries = entries.map { entry in Task { @MainActor in
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForResource = 15
            let session = URLSession(configuration: sessionConfiguration)
            defer { session.invalidateAndCancel() }
            do {
                return try await AgentClient(configuration: entry.makeConfiguration(), session: session).fetchModels()
            } catch {
                // Preserve configured models when discovery is unavailable.
                NSLog("Plugin model discovery failed for provider %@", entry.providerID)
                return [String]()
            }
        } }
        for (entry, discovery) in zip(entries, discoveries) {
            let models = await discovery.value
            guard agentProviderLibrary.entries.contains(entry), !models.isEmpty else { continue }
            pluginDiscoveredModels[entry.id] = models
        }
        let activeID = agentProviderLibrary.active?.id
        var descriptors = agentProviderLibrary.entries.map { entry in
            AgentPluginAIProviderDescriptor(
                providerID: entry.providerID,
                displayName: entry.displayName,
                isActive: entry.id == activeID,
                isLocal: AgentLocalModelPrompting.isLocalProvider(entry.makeConfiguration()),
                models: modelList(for: entry),
                flashModel: entry.flashPrimary
            )
        }
        let local = AgentSettingsStore.loadLocalModelSettings()
        if local.enabled, !descriptors.contains(where: { $0.providerID == AgentProviderPreset.ollamaID }) {
            let models = [local.summaryModel, local.visionModel]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            descriptors.append(
                AgentPluginAIProviderDescriptor(
                    providerID: AgentProviderPreset.ollamaID,
                    displayName: local.composerDisplayName,
                    isActive: false,
                    isLocal: true,
                    models: Array(Set(models)).sorted(),
                    flashModel: models.first ?? ""
                )
            )
        }
        return descriptors
    }

    private func modelList(for entry: AgentProviderEntry) -> [String] {
        AgentExecutionProfileModelCatalog.models(
            for: entry, discoveredModels: pluginDiscoveredModels[entry.id] ?? [], builtIns: []
        )
    }

    /// 页面能引用的技能：用户当前启用的那些，含插件自带的。刻意不返回 url。
    nonisolated static func pluginSkills(limit: Int = 200) async -> [AgentPluginSkillDescriptor] {
        await AgentSkillDirectory.listAsync(includeDisabled: false)
            .prefix(limit)
            .map { entry in
                AgentPluginSkillDescriptor(
                    identifier: entry.identifier,
                    name: entry.name,
                    description: entry.description,
                    source: entry.source.rawValue,
                    tier: entry.tier?.rawValue
                )
            }
    }

    /// 把页面引用的技能读成一条 system 消息。正文由宿主从磁盘读取并截断，
    /// 页面全程只见 identifier。找不到的 identifier 直接报错，不静默跳过——
    /// 否则模型会在缺了技能的情况下若无其事地照答。
    nonisolated static func pluginSkillPreamble(
        identifiers: [String]
    ) async throws -> AgentPluginAIMessage? {
        guard !identifiers.isEmpty else { return nil }
        let catalog = await AgentSkillDirectory.listAsync(includeDisabled: false)
        var blocks: [String] = []
        for identifier in identifiers {
            guard let entry = catalog.first(where: { $0.identifier == identifier || $0.name == identifier }) else {
                throw AgentPluginAIError.unknownSkill(identifier)
            }
            let body = AgentSkillDirectory.loadBody(
                for: entry,
                maxCharacters: AgentPluginAIRequest.maximumSkillCharacters
            ) ?? "(skill body unavailable)"
            blocks.append("""
            ### Skill: \(entry.identifier)
            > \(entry.description)

            \(body)
            """)
        }
        return AgentPluginAIMessage(
            role: .system,
            content: "The user attached these skills to this request.\n\n" + blocks.joined(separator: "\n\n")
        )
    }

    /// 执行一次插件发起的模型对话。权限、路由、上限都在这里收口，
    /// 页面那侧只负责把文字递进来。
    func runPluginAICompletion(
        pluginID: AgentPluginID,
        request: AgentPluginAIRequest,
        onDelta: (@Sendable (String) -> Void)? = nil,
        /// 思考增量。插件页面上一次结构化生成要等十几秒到几十秒，期间正文
        /// 还没开始写，页面除了一个转圈没有别的可显示。推理模型这段时间
        /// 其实一直在输出思考文本，把它露出来，等待就有了内容。
        ///
        /// 与正文分开一条通道：页面要把它显示成「思考」而不是当成结果。
        onReasoning: (@Sendable (String) -> Void)? = nil
    ) async throws -> AgentPluginAIResult {
        guard AgentPluginRegistry.shared.hasPermission(.aiChat, pluginID: pluginID) else {
            throw AgentPluginAIError.permissionDenied
        }
        if !request.skillIdentifiers.isEmpty {
            guard AgentPluginRegistry.shared.hasPermission(.skillsRead, pluginID: pluginID) else {
                throw AgentPluginAIError.skillPermissionDenied
            }
        }
        let configuration = try pluginAIConfiguration(for: request)
        // 技能正文另算预算，不占页面自己那 32000 字的额度，也不参与条数上限。
        var outbound = request.messages
        if let preamble = try await Self.pluginSkillPreamble(identifiers: request.skillIdentifiers) {
            outbound.insert(preamble, at: 0)
        }
        let messages = outbound.map { AgentMessage(role: $0.role, content: $0.content) }
        let buffer = AgentPluginAITextBuffer()
        try await AgentClient(configuration: configuration).streamChat(messages: messages) { event in
            switch event {
            case .textDelta(let delta):
                await buffer.append(delta)
                onDelta?(delta)
            case .reasoningDelta(let delta):
                // 只转发，不累进结果缓冲：思考不是模型交出的答案，混进正文
                // 会把它一起解析成结构化内容。
                onReasoning?(delta)
            default:
                break
            }
        }
        // 取消是正常收场，不是「模型什么也没回」。先认取消再判空，
        // 否则页面按停止键会收到一条误导性的 emptyResponse。
        try Task.checkCancellation()
        let text = await buffer.value().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AgentPluginAIError.emptyResponse }
        return AgentPluginAIResult(
            text: text,
            model: configuration.model,
            providerID: configuration.providerID
        )
    }

    func runPluginImageGeneration(
        pluginID: AgentPluginID,
        request: AgentPluginImageRequest
    ) async throws -> AgentPluginImageResult {
        guard AgentPluginRegistry.shared.hasPermission(.aiImage, pluginID: pluginID) else {
            throw AgentPluginAIError.imagePermissionDenied
        }
        let outputDirectory = try AgentPluginGeneratedMediaResolver.directory(pluginID: pluginID)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let image = try await SomeIMClient.generateImage(
            prompt: request.prompt,
            size: request.size,
            model: request.model,
            outputDirectory: outputDirectory
        )
        let filename = image.fileURL.lastPathComponent
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed) ?? filename
        return AgentPluginImageResult(
            mediaURL: "willdeep-plugin://bundle/__media__/\(encoded)",
            filePath: image.fileURL.path,
            model: image.model,
            providerID: "some-im"
        )
    }

    private func pluginAIConfiguration(for request: AgentPluginAIRequest) throws -> AgentConfiguration {
        // 没指定就走「默认 provider 的 flash 档」——和上下文压缩、审核解释
        // 同一条辅助路线：便宜、快、用户已经配好了。
        guard let providerID = request.providerID else {
            var configuration = agentConfiguration.resolved(for: .compression)
            configuration.model = configuration.flashModel
            if let model = request.model {
                let allowed = Set([configuration.flashModel, configuration.proModel])
                guard allowed.contains(model) else { throw AgentPluginAIError.unknownModel(model) }
                configuration.model = model
            }
            guard !configuration.model.isEmpty else { throw AgentPluginAIError.unavailable }
            return configuration.normalized
        }

        if let entry = agentProviderLibrary.entries.first(where: { $0.providerID == providerID }) {
            var configuration = entry.makeConfiguration(routingMode: .flash)
            if let model = request.model {
                guard modelList(for: entry).contains(model) else {
                    throw AgentPluginAIError.unknownModel(model)
                }
                configuration.model = model
                configuration.flashModel = model
            }
            guard !configuration.model.isEmpty else { throw AgentPluginAIError.unavailable }
            return configuration.normalized
        }

        // 本地模型：用户在设置里开了 Ollama 才认，模型必须是他自己填的那两个
        if providerID == AgentProviderPreset.ollamaID {
            let local = AgentSettingsStore.loadLocalModelSettings()
            guard local.enabled else { throw AgentPluginAIError.unknownProvider(providerID) }
            let candidates = [local.summaryModel, local.visionModel]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let model = request.model ?? candidates.first ?? ""
            guard !model.isEmpty else { throw AgentPluginAIError.unavailable }
            guard candidates.contains(model) else { throw AgentPluginAIError.unknownModel(model) }
            return local.configuration(model: model)
        }

        throw AgentPluginAIError.unknownProvider(providerID)
    }
}
