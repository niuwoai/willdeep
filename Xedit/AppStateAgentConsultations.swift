//
//  AppStateAgentConsultations.swift
//  WillDeep
//
//  App wiring for multi-expert consultations: transcript card creation,
//  task lifetime, cancellation, persistence, and final chair response.
//

import Foundation

extension AppState {
    @discardableResult
    func startAgentConsultation(
        task rawTask: String,
        configuration: AgentConsultationConfiguration
    ) -> Bool {
        let taskText = rawTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskText.isEmpty else {
            agentErrorMessage = L10n.Consultation.taskRequired
            return false
        }
        guard configuration.isValid else {
            agentErrorMessage = L10n.Consultation.twoExpertsRequired
            return false
        }
        guard let runtime = activeRuntime else {
            agentErrorMessage = WorkflowError.noActiveRuntime.errorDescription
            return false
        }
        guard agentConsultationTasks.isEmpty else {
            agentErrorMessage = L10n.Consultation.alreadyRunning
            return false
        }

        let conversationContext = Self.consultationConversationContext(
            messages: runtime.messages
        )
        let consultation = AgentConsultationReport(
            task: taskText,
            configuration: configuration
        )
        let report = WorkflowReport(
            workflowName: configuration.mode == .groupChat
                ? "expert-group-chat"
                : "expert-consultation",
            displayTitle: configuration.mode == .groupChat
                ? L10n.Consultation.groupChatTitle
                : L10n.Consultation.title,
            args: taskText,
            status: .planning,
            consultation: consultation
        )

        runtime.messages.append(AgentMessage(role: .user, content: taskText))
        runtime.messages.append(
            AgentMessage(role: .workflowReport, content: "", workflowReport: report)
        )
        runtime.input = ""
        runtime.latestTurnRecall = nil
        persistAgentSession(runtime: runtime)

        let runtimeID = runtime.id
        let workspaceLocation = runtime.workspaceLocation
            ?? runtime.workspaceRootPath.map { .local(path: $0) }
        let workspaceURL = workspaceLocation?.localPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        let runtimeDescriptor = workspaceLocation?.remoteRuntimeID.flatMap {
            AgentRuntimeStore.descriptor(id: $0)
        }
        let turnConfiguration = configurationForCurrentTurn(for: runtime)
        let someIMContext: SomeIMRequestContext? = {
            guard turnConfiguration.providerID == AgentProviderPreset.someIMID else { return nil }
            let workspaceID = AgentWorkspaceIdentityStore.workspaceID(
                forWorkspaceKey: Self.managedWorkspaceKey(for: runtime)
            )
            return SomeIMRequestContext(sessionID: runtimeID.uuidString, workspaceID: workspaceID)
        }()

        let consultationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.updateWorkflowReport(id: report.id, runtimeID: runtimeID) { item in
                item.status = .running
            }
            self.persistWorkflowRuntime(runtimeID: runtimeID)

            let engine = AgentConsultationEngine(
                reportID: report.id,
                runtimeID: runtimeID,
                workspaceURL: workspaceURL,
                workspaceLocation: workspaceLocation,
                runtimeDescriptor: runtimeDescriptor,
                configuration: turnConfiguration,
                someIMContext: someIMContext,
                conversationContext: conversationContext,
                appState: self
            )

            do {
                let final = try await engine.run()
                guard !Task.isCancelled else { throw CancellationError() }
                self.updateWorkflowReport(id: report.id, runtimeID: runtimeID) { item in
                    item.status = .done
                    item.summary = final
                    item.finishedAt = Date()
                }
                if let liveRuntime = self.agentRuntimes[runtimeID] {
                    liveRuntime.messages.append(
                        AgentMessage(
                            role: .assistant,
                            content: final,
                            origin: .nativeModel,
                            originLabel: L10n.Consultation.chairName
                        )
                    )
                    self.persistAgentSession(runtime: liveRuntime)
                }
            } catch is CancellationError {
                self.updateWorkflowReport(id: report.id, runtimeID: runtimeID) { item in
                    item.status = .cancelled
                    item.finishedAt = Date()
                    if var detail = item.consultation {
                        detail.phase = .cancelled
                        item.consultation = detail
                    }
                }
                self.persistWorkflowRuntime(runtimeID: runtimeID)
            } catch {
                self.updateWorkflowReport(id: report.id, runtimeID: runtimeID) { item in
                    item.status = .failed
                    item.finishedAt = Date()
                    item.summary = L10n.Consultation.failed(error.localizedDescription)
                    if var detail = item.consultation {
                        detail.phase = .failed
                        item.consultation = detail
                    }
                }
                self.persistWorkflowRuntime(runtimeID: runtimeID)
            }
            self.agentConsultationTasks[report.id] = nil
        }
        agentConsultationTasks[report.id] = consultationTask
        return true
    }

    func stopAgentConsultation(reportID: UUID) {
        agentConsultationTasks[reportID]?.cancel()
    }

    var hasActiveAgentConsultation: Bool {
        !agentConsultationTasks.isEmpty
    }

    func workflowReport(id: UUID, runtimeID: UUID) -> WorkflowReport? {
        agentRuntimes[runtimeID]?.messages.first(where: {
            $0.role == .workflowReport && $0.workflowReport?.id == id
        })?.workflowReport
    }

    func persistWorkflowRuntime(runtimeID: UUID) {
        guard let runtime = agentRuntimes[runtimeID] else { return }
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
    }

    nonisolated static func consultationConversationContext(
        messages: [AgentMessage],
        maxMessages: Int = 8,
        maxCharacters: Int = 6_000
    ) -> String? {
        let relevant = messages.filter { $0.role == .user || $0.role == .assistant }
        let lines = relevant.suffix(maxMessages).map { message in
            let role = message.role == .user ? "USER" : "ASSISTANT"
            return "\(role): \(message.content)"
        }
        let text = lines.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.suffix(maxCharacters))
    }
}
