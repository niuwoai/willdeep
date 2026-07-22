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
        if isLocalConfirmationPreviewCall(id: call.id) {
            return AgentApprovalExplanationResult(
                text: L10n.ToolCard.localPreviewExplanation,
                model: L10n.ToolCard.localPreviewModel
            )
        }

        let route = await approvalExplanationRoute()
        let messages = [
            AgentMessage(role: .system, content: AgentApprovalExplanationPrompt.systemPrompt),
            AgentMessage(role: .user, content: AgentApprovalExplanationPrompt.userPayload(for: call))
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

private enum AgentApprovalExplanationPrompt {
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

        不要执行命令，不要声称已经检查了本地文件，不要输出密钥或隐私。
        只输出最多 5 条短要点。
        \(AppLocale.systemPromptDirective)
        """
    }

    static func userPayload(for call: AgentToolCall) -> String {
        let arguments = call.arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.displaySummary)" }
            .joined(separator: "\n")
        return """
        工具: \(AgentToolDisplay.nameWithRawID(for: call.toolName))
        风险等级: \(riskLabel(call.risk))
        当前状态: \(statusLabel(call.status))

        参数:
        \(arguments.isEmpty ? "(无)" : arguments)
        """
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
