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
    /// 附在这条消息上的本地图片 / 视频路径（只认 user 消息）。宿主钳制到
    /// 插件生成目录、解码后作为图片附件送进模型，见 `AgentPluginAIMedia`。
    var imagePaths: [String] = []
    var videoPaths: [String] = []

    var hasMedia: Bool { !imagePaths.isEmpty || !videoPaths.isEmpty }
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
    /// 页面声明的产出形状。空数组时行为和以前完全一致。
    var tools: [AgentPluginAITool] = []

    static let maximumMessages = 24
    static let maximumCharacters = 32_000
    /// 同一个插件页面同时在跑的对话数。共创页会连着点「生成」，没有这道闸
    /// 就能并行发出任意多条请求，用户的额度是按条烧的。
    static let maximumConcurrentRequests = 2
    /// 主聊天那条路对「一条消息挂几个技能」没有上限，用户从 popover 连点就能
    /// 挂 N 个，N × 24k 全进 prompt。这条通道是给插件页面的，一开始就封死。
    static let maximumSkills = 3
    static let maximumSkillCharacters = 8_000
    /// 一次请求最多几个工具。页面每个阶段只需要一个「交出这一段产出」的
    /// 工具，四个已经宽裕；上限存在是因为工具定义整份进 prompt。
    static let maximumTools = 4
    static let maximumToolParameters = 12
}

/// 页面声明的一个「产出形状」。
///
/// **它不会被执行。** 宿主只是把它的 schema 交给模型，再把模型填好的参数
/// 原样递回页面——这是一个带类型的返回信封，不是一次工具调用的前半段。
/// 页面拿不到任何执行能力，也没有对应的执行器。
///
/// 存在的理由：在此之前页面靠围栏约定收结构化产出（「只输出一个
/// ```short_drama_episode 代码块」），而模型隔三差五回一个普通的 ```json，
/// 于是整块内容被当成闲聊，草稿一个字没改。围栏是口头约定，工具 schema
/// 是协议——provider 那一侧会强制字段名和类型。
nonisolated struct AgentPluginAITool: Equatable, Sendable {
    struct Parameter: Equatable, Sendable {
        let name: String
        let type: AgentToolParameter.ParameterType
        let description: String
        let required: Bool
    }

    let name: String
    let description: String
    let parameters: [Parameter]

    var descriptor: AgentToolDescriptor {
        AgentToolDescriptor(
            name: name,
            description: description,
            // 只读：这些工具什么也不做，审批与沙箱层面没有任何可授予的权限。
            risk: .read,
            parameters: parameters.map {
                AgentToolParameter(name: $0.name, type: $0.type, description: $0.description, required: $0.required)
            }
        )
    }
}

/// 模型填好的一份产出。`argumentsJSON` 原样递给页面，由页面按自己的
/// schema 解读——宿主不认识 `script` 或 `replacement` 是什么。
nonisolated struct AgentPluginAIToolCall: Equatable, Sendable {
    let name: String
    let argumentsJSON: String

    var jsonObject: [String: Any] { ["name": name, "arguments": argumentsJSON] }
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
    /// 模型这一轮填好的工具参数。空数组表示它选择用正文回答——页面据此
    /// 回落到原来的解析路径，而不是把一次正常的提问当成失败。
    var toolCalls: [AgentPluginAIToolCall] = []
}

nonisolated struct AgentPluginImageRequest: Equatable, Sendable {
    let prompt: String
    let model: String
    let size: String
    /// 参照图的**本地绝对路径**，由宿主负责上传换 URL。页面递路径而不是
    /// 字节：一张脸 2 MB，base64 之后近 3 MB，走 WebKit 桥来回抄一遍纯属
    /// 浪费，而这些文件本来就在宿主自己的生成目录里。视频生成那条路早就
    /// 是这么做的（referenceImagePath）。空数组即纯文生图。
    let referenceImagePaths: [String]

    static let allowedModels = ["gpt-image-2", "nano-banana-2"]
    /// 页面能要的画幅。**第一个是默认值**（页面不传 size 时用它），所以
    /// 1024x1024 必须留在最前面——换个顺序就等于悄悄改掉所有不传尺寸的插件。
    ///
    /// 前三档是 gpt-image 系自己支持的尺寸，后三档是竖屏短剧要用的：9:16
    /// （1080x1920）是手机短剧的标准画幅，红果、抖音都按它出片；3:4 和 16:9
    /// 补齐另外两个常见比例。加这三档的直接原因是短剧工坊插件——它出的首尾帧
    /// 要和随后那段视频同比例，而这张表里最竖的一档只到 2:3，比 9:16 宽 17%，
    /// 于是视频侧只能自己裁切首帧，人物位置和景别当场走样。
    ///
    /// 尺寸本身不经这里转换：`SomeIMClient.generateImage` 把它原样放进
    /// `/images/generations` 的 body，网关主路径整包透传。也就是说这张表是
    /// 整条链路上唯一的白名单，放开它就够。
    ///
    /// 注意 gpt-image 系出不了后三档——这里不按模型再拦一道，因为模型能力会
    /// 变而这张表不会跟着变；该由插件按自己用的模型收敛（短剧工坊就是这么做的），
    /// 真送错了上游会如实报错。
    static let allowedSizes = [
        "1024x1024", "1536x1024", "1024x1536",
        "1080x1920", "1080x1440", "1920x1080",
    ]
    static let maximumCharacters = 8_000
    /// 与网关一致的上限，见 `SomeIMClient.maximumReferenceImages`。
    static let maximumReferenceImages = 9

    init(prompt: String, model: String, size: String, referenceImagePaths: [String] = []) {
        self.prompt = prompt
        self.model = model
        self.size = size
        self.referenceImagePaths = referenceImagePaths
    }
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
    case tooManyTools
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
    case tooManyReferenceImages(Int)
    /// 参照图必须落在本插件自己的生成目录里。页面递的是路径，所以这道钳制
    /// 是唯一的边界：少了它，一个插件页就能让宿主去读任意文件并上传出去。
    case referenceImageOutsidePluginData(String)
    case tooManyImages(Int)
    case tooManyVideos(Int)
    /// 附件路径的钳制，判据同参照图。
    case mediaOutsidePluginData(String)
    case unreadableMedia(String)
    case mediaOnNonUserMessage
    /// 附了图片或视频，选的模型却不收图。宿主当场拒，而不是发出去等上游 400。
    case modelRejectsMedia(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "This plugin did not declare the ai.chat permission."
        case .imagePermissionDenied: return "This plugin did not declare the ai.image permission."
        case .skillPermissionDenied: return "This plugin did not declare the skills.read permission."
        case .tooManySkills: return "At most \(AgentPluginAIRequest.maximumSkills) skills can be attached to one request."
        case .tooManyTools: return "At most \(AgentPluginAIRequest.maximumTools) tools can be declared on one request."
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
        case .tooManyReferenceImages(let count):
            return "At most \(AgentPluginImageRequest.maximumReferenceImages) reference images are allowed, got \(count)."
        case .referenceImageOutsidePluginData(let path):
            return "Reference image is outside this plugin's generated-media folder: \(path)"
        case .tooManyImages(let count):
            return "At most \(AgentPluginAIMedia.maximumImages) images can be attached to one request, got \(count)."
        case .tooManyVideos(let count):
            return "At most \(AgentPluginAIMedia.maximumVideos) videos can be attached to one request, got \(count)."
        case .mediaOutsidePluginData(let path):
            return "Attached media is outside this plugin's generated-media folder: \(path)"
        case .unreadableMedia(let name):
            return "Attached media could not be read: \(name)"
        case .mediaOnNonUserMessage:
            return "Images and videos can only be attached to user messages."
        case .modelRejectsMedia(let model):
            return "The selected model does not accept image input: \(model)"
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
        let rawPaths = (raw["referenceImagePaths"] as? [Any] ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard rawPaths.count <= AgentPluginImageRequest.maximumReferenceImages else {
            return .failure(.tooManyReferenceImages(rawPaths.count))
        }
        return .success(AgentPluginImageRequest(
            prompt: prompt, model: model, size: size, referenceImagePaths: rawPaths
        ))
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
            var message = AgentPluginAIMessage(role: role, content: trimmed)
            // 只有 user 消息能带附件：system 与 assistant 在各家协议里都不
            // 一定收图。递上来就是页面写错了，当场拒，不静默丢——丢掉的话
            // 模型会在没看到图的情况下若无其事地给出结论。
            let images = mediaPaths(entry["imagePaths"])
            let videos = mediaPaths(entry["videoPaths"])
            if role == .user {
                message.imagePaths = images
                message.videoPaths = videos
            } else if !images.isEmpty || !videos.isEmpty {
                return .failure(.mediaOnNonUserMessage)
            }
            messages.append(message)
        }
        guard !messages.isEmpty else { return .failure(.emptyRequest) }
        guard messages.count <= AgentPluginAIRequest.maximumMessages else {
            return .failure(.tooManyMessages)
        }
        let imageCount = messages.reduce(0) { $0 + $1.imagePaths.count }
        guard imageCount <= AgentPluginAIMedia.maximumImages else { return .failure(.tooManyImages(imageCount)) }
        let videoCount = messages.reduce(0) { $0 + $1.videoPaths.count }
        guard videoCount <= AgentPluginAIMedia.maximumVideos else { return .failure(.tooManyVideos(videoCount)) }
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

        var tools: [AgentPluginAITool] = []
        for entry in raw["tools"] as? [[String: Any]] ?? [] {
            // 名字必须是模型侧合法的工具名。不合规的整条丢掉而不是修正：
            // 一个被改过名的工具，页面按原名去认返回值会认不到。
            guard let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, name.count <= 48,
                  name.allSatisfy({ $0.isLowercase && $0.isLetter || $0.isNumber || $0 == "_" }),
                  !tools.contains(where: { $0.name == name }) else { continue }
            let description = String(((entry["description"] as? String) ?? "").prefix(400))
            var parameters: [AgentPluginAITool.Parameter] = []
            for field in entry["parameters"] as? [[String: Any]] ?? [] {
                guard let fieldName = (field["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !fieldName.isEmpty, fieldName.count <= 48,
                      let type = AgentToolParameter.ParameterType(rawValue: (field["type"] as? String) ?? "string"),
                      !parameters.contains(where: { $0.name == fieldName }) else { continue }
                parameters.append(AgentPluginAITool.Parameter(
                    name: fieldName,
                    type: type,
                    description: String(((field["description"] as? String) ?? "").prefix(240)),
                    required: (field["required"] as? Bool) ?? false
                ))
            }
            guard !parameters.isEmpty,
                  parameters.count <= AgentPluginAIRequest.maximumToolParameters else { continue }
            tools.append(AgentPluginAITool(name: name, description: description, parameters: parameters))
        }
        guard tools.count <= AgentPluginAIRequest.maximumTools else { return .failure(.tooManyTools) }
        request.tools = tools
        return .success(request)
    }

    /// 去空、去重、截断超长路径。数量上限在调用方按整个请求算。
    private static func mediaPaths(_ value: Any?) -> [String] {
        var paths: [String] = []
        for entry in value as? [Any] ?? [] {
            guard let path = (entry as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty, path.count <= AgentPluginAIMedia.maximumPathCharacters,
                  !paths.contains(path) else { continue }
            paths.append(path)
        }
        return paths
    }
}

nonisolated private extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}

private actor AgentPluginAITextBuffer {
    private var text = ""
    private var calls: [AgentMessageToolCall] = []
    func append(_ delta: String) { text += delta }
    func value() -> String { text }
    func replaceToolCalls(_ next: [AgentMessageToolCall]) { calls = next }
    func toolCalls() -> [AgentMessageToolCall] { calls }
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
                // Discoveries, not bare ids: the catalogue carries each
                // model's own context window, and the local id-matching table
                // guesses. some.im publishes kimi-k3 at 1M where the guess
                // reads 128K, and that 87% undercount fires compression and
                // the ordered stop against a window that is barely touched.
                return try await AgentClient(configuration: entry.makeConfiguration(), session: session)
                    .fetchModelDiscoveries()
            } catch {
                // Preserve configured models when discovery is unavailable.
                NSLog("Plugin model discovery failed for provider %@", entry.providerID)
                return [AgentModelDiscovery]()
            }
        } }
        for (entry, discovery) in zip(entries, discoveries) {
            let found = await discovery.value
            let models = found.map(\.id)
            guard agentProviderLibrary.entries.contains(entry), !models.isEmpty else { continue }
            pluginDiscoveredModels[entry.id] = models
            // Make one good fetch durable. Without this the picker is only
            // ever as complete as this page load's network: a provider entry
            // carries one or two configured model ids, so a fetch that fails
            // or outruns its 15s cap left some.im offering
            // `someim-auto-flash` alone while the relay serves dozens.
            AgentSettingsStore.saveProviderModelCatalog(entryID: entry.id, models: models)
            recordFetchedAgentModelDiscoveries(found)
        }
        AgentSettingsStore.pruneProviderModelCatalogs(keeping: agentProviderLibrary.entries.map(\.id))
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

    /// Models a plugin page may offer for one provider.
    ///
    /// Three sources, in this order of preference: this launch's live
    /// discovery, the last successful discovery persisted for this entry, and
    /// the entry's own configured ids. The cached layer is what keeps the
    /// picker honest — a provider entry names one or two models, so a failed
    /// fetch used to leave the page showing just those, and some.im's entry
    /// names exactly one.
    ///
    /// Built-in execution profiles are included too. They are models this
    /// build already knows how to talk to through this provider, and there is
    /// no reason a plugin page should see fewer of them than the composer.
    private func modelList(for entry: AgentProviderEntry) -> [String] {
        let live = pluginDiscoveredModels[entry.id] ?? []
        let cached = live.isEmpty ? (AgentSettingsStore.loadProviderModelCatalogs()[entry.id] ?? []) : live
        return AgentExecutionProfileModelCatalog.models(for: entry, discoveredModels: cached)
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
        let carriesMedia = request.messages.contains(where: \.hasMedia)
        // 模型不收图就当场拒。发出去的话上游回的是一句难懂的 400（「unknown
        // variant image_url」），页面没法据此告诉用户该去换审核模型。
        if carriesMedia, !configuration.supportsImageInput {
            throw AgentPluginAIError.modelRejectsMedia(configuration.model)
        }
        // 技能正文另算预算，不占页面自己那 32000 字的额度，也不参与条数上限。
        var outbound = request.messages
        if let preamble = try await Self.pluginSkillPreamble(identifiers: request.skillIdentifiers) {
            outbound.insert(preamble, at: 0)
        }
        let mediaRoot = carriesMedia ? try AgentPluginGeneratedMediaResolver.directory(pluginID: pluginID) : nil
        var attachedImageCount = 0
        var attachedVideoCount = 0
        var messages: [AgentMessage] = []
        for entry in outbound {
            guard entry.hasMedia, let mediaRoot else {
                messages.append(AgentMessage(role: entry.role, content: entry.content))
                continue
            }
            var images: [AgentImageAttachment] = []
            for path in entry.imagePaths {
                let url = try AgentPluginAIMedia.clampedFileURL(path: path, mediaRoot: mediaRoot)
                images.append(try AgentPluginAIMedia.imageAttachment(at: url))
            }
            // 视频抽成的帧跟在直接附的图片后面，并在正文末尾写明哪几张是
            // 哪个视频的第几秒。只给一串图，模型分不清哪些是同一段视频、
            // 也不知道顺序就是时间顺序。
            var notes: [String] = []
            for (index, path) in entry.videoPaths.enumerated() {
                let url = try AgentPluginAIMedia.clampedFileURL(path: path, mediaRoot: mediaRoot)
                let frames = try await AgentPluginAIMedia.videoFrames(at: url)
                let first = images.count + 1
                images.append(contentsOf: frames.map(\.attachment))
                let times = frames.map { String(format: "%.1fs", $0.seconds) }.joined(separator: ", ")
                notes.append("Images \(first)-\(images.count) are frames of video \(index + 1) in time order (at \(times)).")
            }
            attachedImageCount += entry.imagePaths.count
            attachedVideoCount += entry.videoPaths.count
            let content = notes.isEmpty ? entry.content : entry.content + "\n\n[" + notes.joined(separator: " ") + "]"
            messages.append(AgentMessage(role: entry.role, content: content, images: images))
        }
        // 每次调用都留痕：在此之前插件问一次模型，耗时、token、花费一律
        // 无迹可寻，客户报「这个插件慢」时导出的诊断包是空的。
        let startedAt = Date()
        let promptCharacters = outbound.reduce(0) { $0 + $1.content.count }
        func record(outcome: String, responseCharacters: Int, toolCalls: [String], error: Error?) {
            AgentPluginAuditLog.recordAICall(AgentPluginAuditLog.AICall(
                recordedAt: Date(),
                pluginID: pluginID,
                providerID: configuration.providerID,
                model: configuration.model,
                seconds: Date().timeIntervalSince(startedAt),
                messageCount: outbound.count,
                promptCharacters: promptCharacters,
                skillCount: request.skillIdentifiers.count,
                declaredTools: request.tools.map(\.name),
                toolCalls: toolCalls,
                responseCharacters: responseCharacters,
                outcome: outcome,
                errorDescription: error.map { String($0.localizedDescription.prefix(240)) },
                attachedImages: attachedImageCount,
                attachedVideos: attachedVideoCount
            ))
        }

        let buffer = AgentPluginAITextBuffer()
        do {
        try await AgentClient(configuration: configuration).streamChat(
            messages: messages,
            tools: request.tools.map(\.descriptor)
        ) { event in
            switch event {
            case .textDelta(let delta):
                await buffer.append(delta)
                onDelta?(delta)
            case .reasoningDelta(let delta):
                // 只转发，不累进结果缓冲：思考不是模型交出的答案，混进正文
                // 会把它一起解析成结构化内容。
                onReasoning?(delta)
            case .toolCallsUpdated(let calls):
                // 累积事件：每次带的是到目前为止的**全量**，所以整份替换
                // 而不是追加，否则流式过程中同一个调用会攒出好几份。
                await buffer.replaceToolCalls(calls)
            default:
                break
            }
        }
        } catch {
            record(
                outcome: error is CancellationError ? "cancelled" : "failed",
                responseCharacters: 0, toolCalls: [], error: error
            )
            throw error
        }
        // 取消是正常收场，不是「模型什么也没回」。先认取消再判空，
        // 否则页面按停止键会收到一条误导性的 emptyResponse。
        do { try Task.checkCancellation() } catch {
            record(outcome: "cancelled", responseCharacters: 0, toolCalls: [], error: nil)
            throw error
        }
        let text = await buffer.value().trimmingCharacters(in: .whitespacesAndNewlines)
        let toolCalls = await buffer.toolCalls().map {
            AgentPluginAIToolCall(name: $0.toolName, argumentsJSON: $0.argumentsJSON)
        }
        // 填了工具参数就是给了答案，哪怕一个字的正文都没有——这是工具调用
        // 最常见的形状。只有两样都空才算模型什么也没回。
        guard !text.isEmpty || !toolCalls.isEmpty else {
            record(outcome: "failed", responseCharacters: 0, toolCalls: [], error: AgentPluginAIError.emptyResponse)
            throw AgentPluginAIError.emptyResponse
        }
        record(
            outcome: "succeeded",
            responseCharacters: text.count,
            toolCalls: toolCalls.map(\.name),
            error: nil
        )
        return AgentPluginAIResult(
            text: text,
            model: configuration.model,
            providerID: configuration.providerID,
            toolCalls: toolCalls
        )
    }

    /// 把页面递上来的参照图路径钳到本插件自己的生成目录里，再上传换 URL。
    ///
    /// 这道钳制是唯一的边界：页面递的是路径，少了它，一个插件页就能指使宿主
    /// 去读任意文件并**上传到公网**。判据和取图那条一致——规范化之后父目录
    /// 必须恰好等于本插件的媒体根，并且拒绝符号链接（否则根目录里放一个链接
    /// 就能指出去）。
    private func uploadedReferenceImages(
        pluginID: AgentPluginID,
        paths: [String],
        mediaRoot: URL
    ) async throws -> [String] {
        guard !paths.isEmpty else { return [] }
        let root = mediaRoot.standardizedFileURL.resolvingSymlinksInPath()
        var fileURLs: [URL] = []
        for path in paths {
            let candidate = URL(fileURLWithPath: path).standardizedFileURL
            guard candidate.isFileURL, candidate.path.hasPrefix("/") else {
                throw AgentPluginAIError.referenceImageOutsidePluginData(path)
            }
            let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values?.isSymbolicLink != true, values?.isRegularFile == true else {
                throw AgentPluginAIError.referenceImageOutsidePluginData(path)
            }
            let resolved = candidate.resolvingSymlinksInPath()
            guard resolved.deletingLastPathComponent() == root else {
                throw AgentPluginAIError.referenceImageOutsidePluginData(path)
            }
            fileURLs.append(resolved)
        }
        return try await SomeIMClient.uploadReferenceImages(fileURLs)
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
        let referenceURLs = try await uploadedReferenceImages(
            pluginID: pluginID,
            paths: request.referenceImagePaths,
            mediaRoot: outputDirectory
        )
        let image = try await SomeIMClient.generateImage(
            prompt: request.prompt,
            size: request.size,
            model: request.model,
            outputDirectory: outputDirectory,
            referenceImageURLs: referenceURLs
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
