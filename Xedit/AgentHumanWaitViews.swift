import SwiftUI

nonisolated enum AgentHumanWaitText {
    static let stageFailed = String(localized: "human-wait.stage-failed", defaultValue: "Could not save the independent task. The message remains queued.", table: "HumanWait")
    static let runIndependent = String(localized: "human-wait.run-independent", defaultValue: "Run as independent work (permissions unchanged)", table: "HumanWait")
    static let parked = String(localized: "human-wait.parked", defaultValue: "Pending confirmation or input — request retained", table: "HumanWait")
    static let independent = String(localized: "human-wait.independent", defaultValue: "Independent task while waiting", table: "HumanWait")
    static let running = String(localized: "human-wait.running", defaultValue: "Processing", table: "HumanWait")
    static let completed = String(localized: "human-wait.completed", defaultValue: "Task record", table: "HumanWait")
    static let blocked = String(localized: "human-wait.blocked", defaultValue: "Dependent or uncertain messages remain queued. No confirmation or answer has been inferred.", table: "HumanWait")
}

struct AgentHumanGateContainer<Content: View>: View {
    @ObservedObject var runtime: AgentRuntime
    let callID: UUID
    let isBlocking: Bool
    @ViewBuilder let content: () -> Content
    @State private var expanded = false
    var body: some View {
        if isBlocking && runtime.parkedGateIDs.contains(callID) {
            DisclosureGroup(AgentHumanWaitText.parked, isExpanded: $expanded) { content() }
                .padding(8)
                .onAppear { expanded = false }
        } else { content() }
    }
}

struct AgentDeferredTasksView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var root: AgentRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(root.deferredChildren) { child in
                AgentDeferredTaskCard(runtime: child)
            }
            if !root.queuedMessages.isEmpty && !root.deferredDependencyChecks.isEmpty {
                Text(AgentHumanWaitText.blocked).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { appState.restoreDeferredChildren(for: root) }
    }
}

private struct AgentDeferredTaskCard: View {
    @ObservedObject var runtime: AgentRuntime
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(runtime.messages.filter { $0.isOperatorInput || $0.role == .assistant }) { message in
                    if !message.content.isEmpty { Text(message.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
                ForEach(runtime.toolCalls.filter { $0.status.isBlockingForUserDecision }) { call in
                    AgentToolCallCard(call: call)
                }
                if let error = runtime.errorMessage { Text(error).foregroundStyle(.red) }
            }
        } label: {
            Label(runtime.isResponding ? AgentHumanWaitText.running : AgentHumanWaitText.completed, systemImage: "arrow.triangle.branch")
            Text(AgentHumanWaitText.independent).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
