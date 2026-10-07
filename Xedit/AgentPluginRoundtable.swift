//
//  AgentPluginRoundtable.swift
//  WillDeep
//
//  插件 MCP 进程反向请求宿主开一场专家圆桌(`willdeep/roundtable/run`,1.412.0-rc1)。
//
//  起因:短剧工坊的「专家席审稿」原本在插件里用 `willdeep/ai/complete` 自己问六位
//  专家再问主持人——结论有了,但用户看不见过程。宿主本来就有专家圆桌(准备室、
//  多轮发言、态势看板、终稿),只是专家写死在十位商业顾问里。这条反向请求让插件
//  带着自己的专家席来开会:名字、职责、人设、主持人规则、结论契约全由插件给,
//  宿主负责循环(模型调用、流式展示、落盘)并把终稿与按契约产出的结论交回去。
//
//  边界:
//  - 只对插件来源的 stdio 服务开放(同 `AgentMCPHostRequests`),权限同 `ai.chat`;
//  - 议题与专家人设有长度上限,超了当场拒,不静默截断——截断的人设会让专家
//    丢掉自己的规矩;
//  - 一次请求一场圆桌,无人值守(不等主持人答复、不在收敛处暂停),轮数 1～3。
//

import Foundation

nonisolated struct AgentPluginRoundtableExpert: Equatable, Sendable {
    var id: String
    var name: String
    var expertise: String
    var persona: String
}

nonisolated struct AgentPluginRoundtableRequest: Equatable, Sendable {
    /// 报告标题(圆桌主页列表里显示)。
    var title: String
    /// 被审读的材料:议题正文,所有专家与主持人都看同一份。
    var topic: String
    var experts: [AgentPluginRoundtableExpert]
    /// 调用方的主持人规则(可选),拼在开场、终稿、结论提示词的最前面。
    var chairPersona: String?
    /// 结构化结论的契约(可选);给了就在终稿之后再问一次主持人,原文交回。
    var verdictInstruction: String?
    /// 讨论轮数,1～`maximumRounds`。
    var rounds: Int
    /// 模型路由:同 `willdeep/ai/complete`,nil 跟随当前活跃 provider。
    var providerID: String?
    var model: String?

    static let minimumExperts = 2
    static let maximumExperts = 8
    static let maximumRounds = 3
    static let maximumTitleCharacters = 160
    static let maximumTopicCharacters = 60_000
    static let maximumPersonaCharacters = 12_000
    static let maximumNameCharacters = 80
    static let maximumExpertiseCharacters = 200
    static let maximumInstructionCharacters = 6_000
}

nonisolated struct AgentPluginRoundtableTranscriptEntry: Equatable, Sendable {
    var seatID: String
    var name: String
    var round: Int
    var content: String
    var stance: String?
    var isError: Bool

    var jsonObject: [String: Any] {
        var object: [String: Any] = ["seatID": seatID, "name": name, "round": round, "content": content, "isError": isError]
        if let stance { object["stance"] = stance }
        return object
    }
}

nonisolated struct AgentPluginRoundtableResult: Equatable, Sendable {
    var reportID: String
    var sessionID: String
    /// 主持人的终稿(Markdown)。
    var document: String
    /// 按契约产出的结论原文;没给契约时为 nil。
    var verdict: String?
    var transcript: [AgentPluginRoundtableTranscriptEntry]
    var model: String
    var providerID: String
    var rounds: Int

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "reportID": reportID,
            "sessionID": sessionID,
            "document": document,
            "transcript": transcript.map(\.jsonObject),
            "model": model,
            "providerID": providerID,
            "rounds": rounds,
        ]
        object["verdict"] = verdict ?? NSNull()
        return object
    }
}

nonisolated enum AgentPluginRoundtableError: Error, Equatable, LocalizedError {
    case permissionDenied
    case missingTitle
    case missingTopic
    case topicTooLong
    case tooFewExperts
    case tooManyExperts
    case invalidExpert(String)
    case personaTooLong(String)
    case instructionTooLong
    case invalidRounds
    case unknownProvider(String)
    case unavailable
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "This plugin does not have the ai.chat permission"
        case .missingTitle:
            return "title is required"
        case .missingTopic:
            return "topic is required"
        case .topicTooLong:
            return "topic exceeds \(AgentPluginRoundtableRequest.maximumTopicCharacters) characters"
        case .tooFewExperts:
            return "experts needs at least \(AgentPluginRoundtableRequest.minimumExperts) entries"
        case .tooManyExperts:
            return "experts may have at most \(AgentPluginRoundtableRequest.maximumExperts) entries"
        case .invalidExpert(let detail):
            return "invalid expert: \(detail)"
        case .personaTooLong(let name):
            return "persona of \(name) exceeds \(AgentPluginRoundtableRequest.maximumPersonaCharacters) characters"
        case .instructionTooLong:
            return "verdictInstruction exceeds \(AgentPluginRoundtableRequest.maximumInstructionCharacters) characters"
        case .invalidRounds:
            return "rounds must be between 1 and \(AgentPluginRoundtableRequest.maximumRounds)"
        case .unknownProvider(let providerID):
            return "Unknown provider: \(providerID)"
        case .unavailable:
            return "No model is available for the roundtable"
        case .failed(let message):
            return message
        case .cancelled:
            return "The roundtable was cancelled"
        }
    }
}

nonisolated enum AgentPluginRoundtableRequestValidator {
    static func request(from raw: [String: Any]) -> Result<AgentPluginRoundtableRequest, AgentPluginRoundtableError> {
        let title = (raw["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .failure(.missingTitle) }
        let topic = (raw["topic"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return .failure(.missingTopic) }
        guard topic.count <= AgentPluginRoundtableRequest.maximumTopicCharacters else { return .failure(.topicTooLong) }

        let rawExperts = raw["experts"] as? [[String: Any]] ?? []
        guard rawExperts.count >= AgentPluginRoundtableRequest.minimumExperts else { return .failure(.tooFewExperts) }
        guard rawExperts.count <= AgentPluginRoundtableRequest.maximumExperts else { return .failure(.tooManyExperts) }
        var experts: [AgentPluginRoundtableExpert] = []
        var seenIDs = Set<String>()
        for (index, entry) in rawExperts.enumerated() {
            let name = (entry["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= AgentPluginRoundtableRequest.maximumNameCharacters else {
                return .failure(.invalidExpert("experts[\(index)].name"))
            }
            let persona = (entry["persona"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !persona.isEmpty else { return .failure(.invalidExpert("experts[\(index)].persona")) }
            guard persona.count <= AgentPluginRoundtableRequest.maximumPersonaCharacters else { return .failure(.personaTooLong(name)) }
            let expertise = String(((entry["expertise"] as? String) ?? (entry["role"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(AgentPluginRoundtableRequest.maximumExpertiseCharacters))
            var id = (entry["id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty { id = "expert-\(index + 1)" }
            guard seenIDs.insert(id).inserted else { return .failure(.invalidExpert("duplicate id \(id)")) }
            experts.append(AgentPluginRoundtableExpert(id: id, name: name, expertise: expertise, persona: persona))
        }

        let chairPersona = (raw["chairPersona"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let chairPersona, chairPersona.count > AgentPluginRoundtableRequest.maximumPersonaCharacters {
            return .failure(.personaTooLong("chair"))
        }
        let instruction = (raw["verdictInstruction"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let instruction, instruction.count > AgentPluginRoundtableRequest.maximumInstructionCharacters {
            return .failure(.instructionTooLong)
        }
        let rounds: Int
        if let value = raw["rounds"] {
            guard let number = value as? Int ?? (value as? NSNumber)?.intValue ?? Int((value as? String) ?? ""),
                  number >= 1, number <= AgentPluginRoundtableRequest.maximumRounds else {
                return .failure(.invalidRounds)
            }
            rounds = number
        } else {
            rounds = 1
        }
        let providerID = (raw["provider"] as? String ?? raw["providerID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (raw["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(AgentPluginRoundtableRequest(
            title: String(title.prefix(AgentPluginRoundtableRequest.maximumTitleCharacters)),
            topic: topic,
            experts: experts,
            chairPersona: chairPersona.flatMap { $0.isEmpty ? nil : $0 },
            verdictInstruction: instruction.flatMap { $0.isEmpty ? nil : $0 },
            rounds: rounds,
            providerID: providerID.flatMap { $0.isEmpty ? nil : $0 },
            model: model.flatMap { $0.isEmpty ? nil : $0 }
        ))
    }
}
