//
//  AgentSubagentControlToolTests.swift
//  XeditTests
//
//  `send_agent_message` / `stop_agent` 与界面插话的超长拒绝。合同见
//  docs/BACKGROUND_TASK_CONTRACT.md「第三批 · C·二」。
//

import Testing
import Foundation
@testable import WillDeep

@Suite
@MainActor
struct AgentSubagentControlToolTests {
    private static let configuration = AgentConfiguration(
        providerID: "deepseek",
        baseURL: "https://api.deepseek.com",
        model: "deepseek-chat",
        flashModel: "",
        proModel: "",
        routingMode: .pro,
        apiKey: ""
    )

    /// A Worker that runs until a parent instruction arrives (or it is
    /// cancelled), then drains it at the next round like the real runner and
    /// reports the provider-facing message it would have injected.
    private final class Probe {
        var drained: [AgentSubagentInterventionSubmission] = []
        var events: [AgentSubagentInterventionEvent] = []
    }

    private static func registry(probe: Probe, finishOnMessage: Bool = true) -> AgentSubagentRegistry {
        let registry = AgentSubagentRegistry()
        registry.onRunIntervention = { _, event in probe.events.append(event) }
        registry.runOperation = { _, _, _, _, _, _, _, _, channel, _, _ in
            channel?.beginRound(1)
            while true {
                try Task.checkCancellation()
                if finishOnMessage, let channel, channel.hasPendingSubmission {
                    let submissions = channel.drainPending(effectiveRound: 2)
                    probe.drained.append(contentsOf: submissions)
                    return AgentSubagentRunner.Outcome(
                        report: AgentSubagentRunner.interventionMessage(submissions),
                        usageTokens: 0, roundCount: 2, toolInvocationCount: 0)
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        return registry
    }

    private static func start(_ registry: AgentSubagentRegistry, parent: UUID) throws -> AgentSubagentRun {
        try registry.startBackground(prompt: "work", label: "child", configuration: configuration,
                                     workspaceURL: nil, parentRuntimeID: parent)
    }

    private static func waitForReport(_ registry: AgentSubagentRegistry, parent: UUID) async throws -> AgentSubagentRun? {
        for _ in 0..<500 {
            if let report = registry.consumePendingReports(forParentRuntime: parent).first { return report }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    @Test("消息按句柄或 UUID 投递，下一轮生效，回执不存正文")
    func messagesReachTheNextRoundByHandleOrUUID() async throws {
        let probe = Probe()
        let registry = Self.registry(probe: probe)
        let parent = UUID()
        let run = try Self.start(registry, parent: parent)

        let result = AppState.performSubagentControl(
            toolName: "send_agent_message",
            arguments: ["agent_id": .string(run.displayHandle), "message": .string("also check docs/")],
            registry: registry, parentRuntimeID: parent)
        let text = try result.get()
        #expect(text.contains(run.displayHandle) && text.contains("next turn boundary"))

        let report = try #require(try await Self.waitForReport(registry, parent: parent))
        #expect(report.status == .completed)
        #expect(probe.drained.map(\.text) == ["also check docs/"])
        #expect(probe.drained.first?.mode == .nextRound)
        #expect(probe.drained.first?.origin == .parentAgent)
        #expect(report.report.contains("[next-round, from the main agent] also check docs/"))

        var activity = AgentSubagentLiveActivity(
            profileID: "generalist", workerName: "w", model: "m", round: 1, maximumRounds: 8,
            completedToolInvocations: 0, activityText: "", startedAt: Date(), isBackground: true)
        for event in probe.events { activity.recordIntervention(event) }
        #expect(activity.interventionReceipts.count == 1)
        #expect(activity.interventionReceipts.first?.origin == .parentAgent)
        #expect(activity.interventionReceipts.first?.text.contains("also check") == false)

        // UUID form reaches a second running child the same way.
        let second = try Self.start(registry, parent: parent)
        #expect(throws: Never.self) {
            try registry.sendModelMessage(to: second.id.uuidString, message: "go", parentRuntimeID: parent)
        }
        _ = try await Self.waitForReport(registry, parent: parent)
    }

    @Test("别的会话起的、编造的 id 一律找不到")
    func foreignAndUnknownAgentsAreNotFound() async throws {
        let probe = Probe()
        let registry = Self.registry(probe: probe, finishOnMessage: false)
        let parent = UUID()
        let foreign = try Self.start(registry, parent: UUID())
        for reference in [foreign.displayHandle, foreign.id.uuidString, UUID().uuidString, "agent_zzzzzz", "job_abc123"] {
            let send = AppState.performSubagentControl(
                toolName: "send_agent_message",
                arguments: ["agent_id": .string(reference), "message": .string("hijack")],
                registry: registry, parentRuntimeID: parent)
            #expect(throws: AgentSubagentRegistry.ModelControlError.self) { try send.get() }
            #expect((try? send.get()) == nil)
            if case .failure(let error) = send {
                #expect(error.localizedDescription.hasPrefix("background agent not found"))
            }
            let stop = AppState.performSubagentControl(
                toolName: "stop_agent", arguments: ["agent_id": .string(reference)],
                registry: registry, parentRuntimeID: parent)
            #expect((try? stop.get()) == nil)
        }
        #expect(probe.events.isEmpty)
        #expect(registry.run(withID: foreign.id)?.status == .running)
        registry.cancelAll(forParentRuntime: foreign.parentRuntimeID)
    }

    @Test("超过 4000 字符的消息直接报错、不截断；恰好 4000 字符照常投递")
    func overLengthMessagesAreRejectedNotTruncated() async throws {
        let probe = Probe()
        let registry = Self.registry(probe: probe)
        let parent = UUID()
        let run = try Self.start(registry, parent: parent)
        let exact = String(repeating: "字", count: 4_000)
        let over = AppState.performSubagentControl(
            toolName: "send_agent_message",
            arguments: ["agent_id": .string(run.displayHandle), "message": .string(exact + "!")],
            registry: registry, parentRuntimeID: parent)
        guard case .failure(let error) = over else {
            Issue.record("over-length message was accepted")
            return
        }
        #expect(error.localizedDescription.contains("4001 characters"))
        #expect(error.localizedDescription.contains("never truncated"))
        #expect(probe.events.isEmpty)

        try registry.sendModelMessage(to: run.displayHandle, message: exact, parentRuntimeID: parent)
        _ = try await Self.waitForReport(registry, parent: parent)
        #expect(probe.drained.map(\.text) == [exact])
    }

    @Test("stop_agent 停下子 Agent 且报告照常投回；已结束的目标报「已结束」")
    func stoppingDeliversTheReportAndAFinishedChildSaysSo() async throws {
        let probe = Probe()
        let registry = Self.registry(probe: probe, finishOnMessage: false)
        let parent = UUID()
        let run = try Self.start(registry, parent: parent)
        let stopped = try AppState.performSubagentControl(
            toolName: "stop_agent", arguments: ["agent_id": .string(run.displayHandle)],
            registry: registry, parentRuntimeID: parent).get()
        #expect(stopped.contains("report will still be delivered"))

        let report = try #require(try await Self.waitForReport(registry, parent: parent))
        #expect(report.id == run.id)
        #expect(report.status == .cancelled)

        for tool in ["stop_agent", "send_agent_message"] {
            let again = AppState.performSubagentControl(
                toolName: tool,
                arguments: ["agent_id": .string(run.displayHandle), "message": .string("late")],
                registry: registry, parentRuntimeID: parent)
            guard case .failure(let error) = again else {
                Issue.record("\(tool) on a finished child succeeded")
                continue
            }
            #expect(error.localizedDescription.contains("already finished (status: cancelled)"))
        }
    }

    @Test("界面插话仍是 1000 字：显示剩余字数，超长拒绝提交而不是截断")
    func userInterventionRejectsOverLengthDrafts() throws {
        let exact = String(repeating: "改", count: 1_000)
        #expect(AgentSubagentInterventionDraftPolicy.remainingCharacters("") == 1_000)
        #expect(AgentSubagentInterventionDraftPolicy.remainingCharacters("  改一下  ") == 997)
        #expect(AgentSubagentInterventionDraftPolicy.canSubmit(exact))
        #expect(AgentSubagentInterventionDraftPolicy.remainingCharacters(exact + "!") == -1)
        #expect(!AgentSubagentInterventionDraftPolicy.canSubmit(exact + "!"))
        #expect(!AgentSubagentInterventionDraftPolicy.canSubmit("   "))

        let channel = AgentSubagentInterventionChannel()
        #expect(throws: AgentSubagentInterventionError.tooLong(characters: 1_001, limit: 1_000)) {
            try channel.submit(text: exact + "!", mode: .nextRound)
        }
        #expect(!channel.hasPendingSubmission)
        #expect(try channel.submit(text: exact, mode: .nextRound).text == exact)
        // The model channel is wider, and still refuses rather than truncates.
        #expect(try channel.submit(text: exact + "!", mode: .nextRound, origin: .parentAgent).text == exact + "!")
    }
}
