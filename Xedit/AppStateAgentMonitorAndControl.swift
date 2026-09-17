//
//  AppStateAgentMonitorAndControl.swift
//  WillDeep
//
//  Host side of the background-task contract's third batch (C2): `monitor`
//  events become kernel events, and the main Agent can message or stop the
//  background Workers it started (`send_agent_message` / `stop_agent`).
//  Contract: docs/BACKGROUND_TASK_CONTRACT.md「第三批」.
//

import Foundation
import OSLog

private let agentControlLog = Logger(subsystem: "com.willdeep.agent", category: "subagent-control")

/// `send_agent_message` / `stop_agent`. Main-conversation only: Worker tool
/// tables are allowlists that never contain these names.
enum AgentSubagentControlTools {
    static let sendName = "send_agent_message"
    static let stopName = "stop_agent"
    static let names: Set<String> = [sendName, stopName]

    static var descriptors: [AgentToolDescriptor] {
        [
            AgentToolDescriptor(
                name: sendName,
                description: "Send an additional instruction to a running background subagent that this session started with spawn_agent. It is delivered at the child's next turn boundary and does not interrupt its current step. The message may be at most 4000 characters; longer messages are rejected, never truncated. No approval is needed; every call is audited.",
                risk: .read,
                parameters: [
                    AgentToolParameter(name: "agent_id", type: .string, description: "The agent_xxxxxx handle returned by spawn_agent (the full UUID is also accepted).", required: true),
                    AgentToolParameter(name: "message", type: .string, description: "Instruction for the child, at most 4000 characters.", required: true)
                ]
            ),
            AgentToolDescriptor(
                name: stopName,
                description: "Stop a running background subagent that this session started with spawn_agent. Its report is still delivered. No approval is needed; every call is audited.",
                risk: .read,
                parameters: [
                    AgentToolParameter(name: "agent_id", type: .string, description: "The agent_xxxxxx handle returned by spawn_agent (the full UUID is also accepted).", required: true)
                ]
            )
        ]
    }
}

extension AppState {
    // MARK: monitor

    /// Read-only turns (planning-only, design gate, plan-progress
    /// reconciliation) reject `monitor` outright, whatever the command's risk.
    func denyMonitorInReadOnlyTurn(
        _ call: AgentMessageToolCall,
        messageID: UUID,
        arguments: [String: AgentJSONValue],
        runtime: AgentRuntime,
        planProgressReconciliation: Bool
    ) -> Bool {
        guard runtime.currentTurnPlanningOnly
                || runtime.specGateState.blocksExecution
                || planProgressReconciliation else { return false }
        var record = AgentToolCall(messageID: messageID, externalID: call.externalID, toolName: call.toolName,
            arguments: arguments, risk: .write, status: .denied)
        record.errorMessage = "monitor is unavailable in a read-only turn"
        runtime.toolCalls.append(record)
        appendToolMessage(for: runtime, toolCallID: call.externalID,
            payload: "Blocked: monitor starts a command and is unavailable while this turn is read-only. Do not ask for approval.",
            source: .systemNotice, outcomeStatus: .denied, errorMessage: record.errorMessage)
        return true
    }

    /// Kernel form of one monitor publication: host authority, tool
    /// provenance, a unique dedupe key per batch (the 5s coalescing window
    /// must never merge two batches), and `.enqueue` for throttled batches so
    /// they wait for the next boundary instead of waking an idle session.
    nonisolated static func monitorKernelEvent(for publication: AgentMonitorSession.Publication) -> AgentKernelEvent {
        AgentKernelEvent(
            runtimeID: publication.runtimeID,
            source: .backgroundJob,
            kind: .hostNotice,
            priority: publication.isUrgent ? .urgent : .normal,
            interruptPolicy: publication.wakes ? .yieldAtBoundary : .enqueue,
            trust: .host,
            contentProvenance: .tool,
            audience: .model,
            title: publication.label,
            payload: publication.payload,
            metadata: [
                AgentMonitorNotice.contractMetadataKey: publication.contract,
                "handle": publication.handle
            ],
            dedupeKey: publication.dedupeKey
        )
    }

    func publishMonitorKernelEvent(_ publication: AgentMonitorSession.Publication) {
        guard runtime(for: publication.runtimeID) != nil else { return }
        publishAgentKernelEvent(Self.monitorKernelEvent(for: publication))
    }

    // MARK: send_agent_message / stop_agent

    /// No approval card: steering one's own Worker is changing one's mind
    /// about a subtask. Every call is audited (target and outcome only, never
    /// the message body); a delivered message also leaves a body-free receipt
    /// on the Worker's live activity.
    func executeSubagentControlToolCall(
        _ call: AgentMessageToolCall,
        recordID: AgentToolCall.ID,
        arguments: [String: AgentJSONValue],
        runtime: AgentRuntime
    ) {
        let reference = arguments["agent_id"]?.stringValue() ?? ""
        let outcome = Self.performSubagentControl(
            toolName: call.toolName,
            arguments: arguments,
            registry: agentSubagentRegistry,
            parentRuntimeID: runtime.id
        )
        let status: AgentToolCallStatus
        let payload: String
        switch outcome {
        case .success(let text):
            status = .succeeded
            payload = text
            agentControlLog.info("\(call.toolName, privacy: .public) target=\(reference, privacy: .public) parent=\(runtime.id.uuidString, privacy: .public) result=delivered")
        case .failure(let error):
            status = .failed
            payload = error.localizedDescription
            agentControlLog.info("\(call.toolName, privacy: .public) target=\(reference, privacy: .public) parent=\(runtime.id.uuidString, privacy: .public) result=refused reason=\(error.localizedDescription, privacy: .public)")
        }
        if let index = runtime.toolCalls.firstIndex(where: { $0.id == recordID }) {
            runtime.toolCalls[index].status = status
            if status == .succeeded {
                runtime.toolCalls[index].result = AgentToolResult(summary: payload, payload: payload)
            } else {
                runtime.toolCalls[index].errorMessage = payload
            }
        }
        appendToolMessage(for: runtime, toolCallID: call.externalID, payload: payload,
            source: .systemNotice, outcomeStatus: status,
            errorMessage: status == .failed ? payload : nil)
    }

    static func performSubagentControl(
        toolName: String,
        arguments: [String: AgentJSONValue],
        registry: AgentSubagentRegistry,
        parentRuntimeID: UUID
    ) -> Result<String, Error> {
        let reference = arguments["agent_id"]?.stringValue() ?? ""
        do {
            if toolName == AgentSubagentControlTools.sendName {
                let run = try registry.sendModelMessage(
                    to: reference,
                    message: arguments["message"]?.stringValue() ?? "",
                    parentRuntimeID: parentRuntimeID
                )
                return .success("Message queued for background agent \(run.displayHandle); it takes effect at the child's next turn boundary.")
            }
            let run = try registry.stopFromModel(reference, parentRuntimeID: parentRuntimeID)
            return .success("Stop requested for background agent \(run.displayHandle); its report will still be delivered (status: cancelled).")
        } catch {
            return .failure(error)
        }
    }
}
