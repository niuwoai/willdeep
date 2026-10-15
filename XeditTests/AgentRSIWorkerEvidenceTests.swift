import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized) @MainActor struct AgentRSIWorkerEvidenceTests {
    @Test func foregroundAndBackgroundKeepActualVerifierAndRevisionReceipts() async throws {
        let golden = try AgentRSIOfflineRunner.golden()
        let package = try AgentPackageV1.decode(golden["candidate"]["baseline_package"].bytes)
        var profile = try #require(AgentDefinitionLibrary.project(package, binding: .inheritsParent).asSubagentProfile())
        profile.maxRounds = 4; profile.escalation = .none
        for mode in ["foreground_worker", "background_worker"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try Data((AgentRSIOfflineProvider.token + "\n").utf8).write(to: directory.appendingPathComponent("fixture.txt"))
            let rootID = UUID(), parentID = UUID(), host = UUID().uuidString.lowercased() + ".agent-rsi.invalid"
            let store = AgentExecutionEvidenceStore(root: directory.appendingPathComponent("events"))
            let trace = AgentExecutionTrace(store: store, seed: .init(runID: rootID, rootRunID: rootID, sessionID: parentID, mode: "root", kind: "started"))
            AgentRSIOfflineProvider.register(host: host, trace: trace)
            defer { AgentRSIOfflineProvider.unregister(host: host) }
            let transport = URLSessionConfiguration.ephemeral; transport.protocolClasses = [AgentRSIOfflineProvider.self]
            let session = URLSession(configuration: transport); defer { session.invalidateAndCancel() }
            let configuration = AgentConfiguration(providerID: "mock", baseURL: "https://" + host + "/v1", model: "fixture", routingMode: .flash, apiKey: "offline-placeholder")
            let workerID: UUID
            if mode == "foreground_worker" {
                workerID = UUID()
                let outcome = try await AgentExecutionTrace.$current.withValue(trace) {
                    try await AgentSubagentRunner.run(prompt: "Read fixture.txt", configuration: configuration, workspaceURL: directory,
                        profile: profile, verifierCommand: AgentRSIOfflineRunner.verifier, verifierMaxAttempts: 1,
                        evidenceRunID: workerID, session: session)
                }
                #expect(outcome.verifierPassed == true)
            } else {
                let registry = AgentSubagentRegistry()
                registry.runOperation = { prompt, configuration, workspace, _, _, _, _, profile, _, context, progress in
                    try await AgentSubagentRunner.run(prompt: prompt, configuration: configuration, workspaceURL: workspace,
                        profile: profile, verifierCommand: context.verifierCommand, verifierMaxAttempts: context.verifierMaxAttempts,
                        evidenceRunID: context.evidenceRunID, evidenceSessionID: context.evidenceSessionID, evidenceMode: "background_worker",
                        session: session, onProgress: progress)
                }
                var context = AgentSubagentRegistry.BackgroundExecutionContext()
                context.verifierCommand = AgentRSIOfflineRunner.verifier; context.verifierMaxAttempts = 1
                let run = try AgentExecutionTrace.$current.withValue(trace) {
                    try registry.startBackground(prompt: "Read fixture.txt", label: "offline fixture", configuration: configuration,
                        workspaceURL: directory, parentRuntimeID: parentID, profile: profile, executionContext: context)
                }
                workerID = run.id
                defer { registry.cancelAll(forParentRuntime: parentID) }
                for _ in 0..<250 {
                    if registry.run(withID: workerID)?.status != .running { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(registry.run(withID: workerID)?.status == .completed)
                for _ in 0..<250 {
                    if AgentSubagentTranscriptStore.load(runID: workerID) != nil { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let transcript = try #require(AgentSubagentTranscriptStore.load(runID: workerID))
                #expect(transcript.verifierPassed == true && transcript.attemptCount == 1)
                #expect(transcript.verifierCommand == AgentRSIOfflineRunner.verifier)
                AgentSubagentTranscriptStore.delete(runID: workerID)
            }
            let events = try store.events().filter { $0.runID == workerID }
            #expect(events.first { $0.kind == "started" }?.definition?.revision == package.sha256)
            #expect(events.first { $0.kind == "started" }?.rootRunID == rootID)
            #expect(events.last { $0.kind == "finished" }?.verifierPassed == true)
            #expect(events.last { $0.kind == "finished" }?.status == "unverified")
            #expect(events.contains { $0.kind == "tool_receipt" && $0.toolSucceeded == true })
        }
    }
}
