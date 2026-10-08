//
//  AppStateAgentInputSuggestion.swift
//  WillDeep
//
//  回合结束后预测用户下一句。纯逻辑见 AgentInputSuggestion.swift。
//
//  时序不变量：预测是异步的，结果回来时世界可能已经变了。只有同时满足
//  「没在回复、输入框仍为空、最后一条消息没变、开关仍开」才落到 runtime，
//  否则静默丢弃——晚到的灰字盖住用户刚开始的新一轮，比不给更糟。
//

import Foundation

extension AppState {
    func requestAgentInputSuggestionIfNeeded(for runtime: AgentRuntime) {
        runtime.clearInputSuggestion()
        guard agentInputSuggestionsEnabled,
              !runtime.isResponding,
              runtime.lastTurnFailure == nil,
              // 定时任务拉起的会话没有人在输入框前面。
              runtime.session.originRoutineID == nil,
              runtime.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let lastMessageID = runtime.messages.last?.id else { return }

        let turns = runtime.messages.compactMap { message -> AgentInputSuggestion.Turn? in
            if message.isOperatorInput {
                return AgentInputSuggestion.Turn(isUser: true, text: message.userAuthoredText)
            }
            if message.role == .assistant {
                return AgentInputSuggestion.Turn(isUser: false, text: message.content)
            }
            return nil
        }
        guard let payload = AgentInputSuggestion.payload(from: turns) else { return }

        let baseConfiguration = auxiliaryBaseConfiguration(for: runtime)
        let modelID = baseConfiguration.titleSummaryModel()
        guard !modelID.isEmpty else { return }
        let configurations = titleSummaryConfigurationCandidates(remoteModelID: modelID, base: baseConfiguration)
        guard !configurations.isEmpty else { return }

        let runtimeID = runtime.id
        let epoch = runtime.inputSuggestionEpoch
        let startedAt = Date()
        runtime.recordFeedback("suggestion_requested")
        runtime.inputSuggestionTask = Task { [weak self, weak runtime] in
            let result = await AgentInputSuggestion.request(
                configurations: configurations,
                payload: payload
            )
            await MainActor.run {
                guard let self else { return }
                result.records.forEach { self.recordAuxiliaryModelRequest($0, runtimeID: runtimeID) }
                if let runtime {
                    runtime.recordFeedback(Task.isCancelled ? "suggestion_expired" : (result.suggestion == nil ? (result.records.contains(where: \.succeeded) ? "suggestion_none" : "suggestion_failed") : "suggestion_generated")) {
                        $0.elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
                        $0.provider = result.records.last?.providerID
                        $0.model = result.records.last?.modelID
                    }
                }
                guard !Task.isCancelled,
                      let runtime,
                      runtime.inputSuggestionEpoch == epoch,
                      let suggestion = result.suggestion,
                      self.agentInputSuggestionsEnabled,
                      !runtime.isResponding,
                      runtime.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      runtime.messages.last?.id == lastMessageID else { return }
                runtime.installInputSuggestion(suggestion, provider: result.records.last?.providerID, model: result.records.last?.modelID)
                runtime.inputSuggestionTask = nil
            }
        }
    }
}
