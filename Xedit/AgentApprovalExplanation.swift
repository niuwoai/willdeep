//
//  AgentApprovalExplanation.swift
//  WillDeep
//
//  Lightweight, in-card explanation for pending tool approvals.
//

import Foundation

struct AgentApprovalExplanationResult: Equatable {
    let text: String
    let model: String
}

private actor AgentApprovalExplanationTextBuffer {
    private var text = ""

    func append(_ delta: String) {
        text += delta
    }

    func value() -> String {
        text
    }
}

private struct AgentApprovalExplanationRoute {
    let configurations: [AgentConfiguration]
    let someIMContext: SomeIMRequestContext?
}

nonisolated enum AgentApprovalExplanationRouting {
    static func someIMModels(hasCodingPlan: Bool) -> [String] {
        guard hasCodingPlan else { return [SomeIMManagedModel.autoFlash] }
        return [SomeIMManagedModel.codingPlanLow, SomeIMManagedModel.autoFlash]
    }
}

extension AppState {
    func explainAgentToolApproval(_ call: AgentToolCall) async throws -> AgentApprovalExplanationResult {
        if isLocalPanelPreviewCall(id: call.id) {
            return AgentApprovalExplanationResult(
                text: L10n.ToolCard.localPreviewExplanation,
                model: L10n.ToolCard.localPreviewModel
            )
        }

        let route = await approvalExplanationRoute()
        let messages = [
            AgentMessage(role: .system, content: AgentApprovalExplanationPrompt.systemPrompt),
            AgentMessage(role: .user, content: AgentApprovalExplanationPrompt.userPayload(
                for: call,
                judgeMiss: safetyJudgeMiss(for: call)
            ))
        ]
        var lastError: Error?

        for configuration in route.configurations {
            let buffer = AgentApprovalExplanationTextBuffer()
            do {
                try await AgentClient(
                    configuration: configuration,
                    someIMContext: route.someIMContext
                ).streamChat(messages: messages) { event in
                    if case .textDelta(let delta) = event {
                        await buffer.append(delta)
                    }
                }
                let text = await buffer.value().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw AgentToolError.invalidArgument("解释模型返回了空内容。")
                }
                return AgentApprovalExplanationResult(text: text, model: configuration.model)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                lastError = error
            }
        }

        throw lastError ?? AgentToolError.invalidArgument("没有可用的审核解释模型。")
    }

    /// 只有命令型调用会经过裁判，账本也按裁判收到的原始命令记。
    private func safetyJudgeMiss(for call: AgentToolCall) -> AgentSafetyJudgeMiss? {
        guard let command = call.arguments["command"]?.stringValue() else { return nil }
        return safetyJudgeMisses.miss(toolName: call.toolName, command: command)
    }

    private func approvalExplanationRoute() async -> AgentApprovalExplanationRoute {
        let someIMAPIKey = SomeIMIntegrationStore.loadAPIKey()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !someIMAPIKey.isEmpty {
            let settings = SomeIMIntegrationStore.loadSettings().normalized
            let status = await refreshedSomeIMCodingPlanStatusIfNeeded()
            let configurations = AgentApprovalExplanationRouting
                .someIMModels(hasCodingPlan: status.isActiveNow)
                .map { model in
                    AgentConfiguration(
                        providerID: AgentProviderPreset.someIMID,
                        baseURL: settings.baseURL,
                        model: model,
                        flashModel: model,
                        proModel: model,
                        routingMode: .flash,
                        apiKey: someIMAPIKey
                    ).normalized
                }
            return AgentApprovalExplanationRoute(
                configurations: configurations,
                someIMContext: approvalExplanationSomeIMContext()
            )
        }

        var configuration = agentConfiguration.resolved(for: .compression)
        configuration.model = configuration.flashModel
        return AgentApprovalExplanationRoute(
            configurations: [configuration.normalized],
            someIMContext: nil
        )
    }

    private func approvalExplanationSomeIMContext() -> SomeIMRequestContext? {
        guard let runtime = activeRuntime else { return nil }
        let workspaceID = AgentWorkspaceIdentityStore.workspaceID(
            forWorkspaceKey: Self.managedWorkspaceKey(for: runtime)
        )
        return SomeIMRequestContext(sessionID: runtime.id.uuidString, workspaceID: workspaceID)
    }
}

enum AgentApprovalExplanationPrompt {
    /// 解释模型拿到的每个参数值的上限。它曾经吃的是审批卡的 80 字摘要，
    /// 一条长 ssh 命令只剩开头，模型就把「看不全」当成头号风险劝用户
    /// 拒绝——越长的命令越被推给最不会细看它的人。16k 字足以覆盖真实的
    /// 长命令，又不会让一个巨型写入内容把解释请求撑爆。
    static let argumentValueCharacterLimit = 16_000

    /// Computed so the reply language follows the user's locale (plus their
    /// global/project language rules) instead of hardcoding 简体中文 for
    /// every user regardless of system language.
    static var systemPrompt: String {
        """
        你是 WillDeep 的工具审核解释助手。用户正在决定是否允许一个工具调用。
        你的任务是给出简短、可靠、非夸张的解释：
        1. 这次调用准备做什么。
        2. 主要风险是什么。
        3. 用户可以怎样处理：允许、拒绝、或先让 Agent 改用更安全的方式。

        参数给的是完整原文，只有带「\(truncationMarkerPrefix)」标记的地方才被程序截断过。
        不要因为命令长就说内容看不全；请逐段读完再下结论。
        如果载荷写明自动安全检查没有给出结论，要照实告诉用户：这次需要人工确认是因为检查没有完成，
        不代表命令有问题；风险仍然只按命令本身评估。
        不要执行命令，不要声称已经检查了本地文件，不要输出密钥或隐私。
        只输出最多 5 条短要点。
        \(AppLocale.systemPromptDirective)
        """
    }

    static let truncationMarkerPrefix = "[程序截断"

    static func userPayload(for call: AgentToolCall, judgeMiss: AgentSafetyJudgeMiss? = nil) -> String {
        let arguments = fullArgumentsText(for: call.arguments)
        var payload = """
        工具: \(AgentToolDisplay.nameWithRawID(for: call.toolName))
        风险等级: \(riskLabel(call.risk))
        当前状态: \(statusLabel(call.status))
        """
        if let judgeMiss {
            payload += "\n自动安全检查: \(judgeMissLabel(judgeMiss))"
        }
        payload += """


        参数:
        \(arguments.isEmpty ? "(无)" : arguments)
        """
        return payload
    }

    /// 与审批卡同序同名，但字符串给原文：保留换行、只脱敏凭据，超长时由
    /// 程序显式标注截断，而不是让模型从一个省略号里猜。
    static func fullArgumentsText(for arguments: [String: AgentJSONValue]) -> String {
        AgentToolDisplay.approvalArguments(for: arguments)
            .map { argument in
                guard case .string(let raw) = argument.value else {
                    return "\(argument.label)：\(AgentToolDisplay.approvalValueSummary(argument.value))"
                }
                let value = fullStringValue(raw)
                return value.contains("\n")
                    ? "\(argument.label)：\n\(value)"
                    : "\(argument.label)：\(value)"
            }
            .joined(separator: "\n")
    }

    private static func fullStringValue(_ raw: String) -> String {
        let redacted = AgentInjectionDefense.redactedCommandForSafetyJudge(raw)
        guard redacted.count > argumentValueCharacterLimit else { return redacted }
        let omitted = redacted.count - argumentValueCharacterLimit
        return String(redacted.prefix(argumentValueCharacterLimit))
            + "\n\(truncationMarkerPrefix)：以下 \(omitted) 字未提供]"
    }

    private static func judgeMissLabel(_ miss: AgentSafetyJudgeMiss) -> String {
        switch miss {
        case .unconfigured:
            return "未配置自动安全检查，因此需要用户确认。"
        case .unreachable:
            return "自动安全检查这次没有连上（服务暂时不可用），没有给出结论，因此需要用户确认；这与命令本身是否危险无关。"
        }
    }

    private static func riskLabel(_ risk: AgentToolRisk) -> String {
        switch risk {
        case .read: return "读取"
        case .write: return "写入"
        case .danger: return "高风险"
        case .userInput: return "需要用户输入"
        }
    }

    private static func statusLabel(_ status: AgentToolCallStatus) -> String {
        switch status {
        case .pendingApproval: return "等待允许"
        case .awaitingConfirm: return "等待高风险确认"
        case .awaitingUserAnswer: return "等待用户回答"
        case .running: return "运行中"
        case .succeeded: return "已完成"
        case .failed: return "失败"
        case .denied: return "已拒绝"
        }
    }
}
