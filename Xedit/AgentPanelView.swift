//
//  AgentPanelView.swift
//  VeilWriter
//
//  Right-side chat panel for the project agent.
//

import SwiftUI

struct AgentPanelView: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .frame(minWidth: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) {
            Divider()
        }
        .onAppear {
            inputFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent")
                    .font(.system(size: 13, weight: .semibold))
                Text(appState.agentModelStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                appState.clearAgentConversation()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Clear Chat")
            .disabled(appState.agentMessages.isEmpty && appState.agentErrorMessage == nil && appState.agentToolCalls.isEmpty)

            Button {
                appState.isAgentPanelVisible = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close Agent")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if appState.agentMessages.isEmpty {
                        AgentEmptyState()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 44)
                    } else {
                        ForEach(visibleMessages) { message in
                            if shouldShowMessageBubble(message) {
                                AgentMessageBubble(message: message)
                                    .id(message.id)
                            }
                            let calls = toolCalls(for: message.id)
                            if !calls.isEmpty {
                                AgentToolCallGroup(calls: calls)
                                    .id(toolGroupScrollID(for: message.id))
                            }
                        }
                    }

                    if appState.shouldShowAgentThinkingIndicator {
                        AgentThinkingDivider()
                    }

                    if appState.isCompressingAgentContext {
                        AgentContextCompressionDivider()
                    }

                    if let error = appState.agentErrorMessage {
                        AgentErrorCard(message: error, details: appState.agentErrorDetails)
                    }

                    ForEach(appState.agentPatchProposals) { proposal in
                        AgentPatchProposalCard(proposal: proposal)
                    }

                    if appState.agentSessionDidEditFiles && !appState.agentWorktreeChanges.isEmpty {
                        AgentWorktreeChangeCard()
                    }
                }
                .padding(10)
            }
            .onChange(of: appState.agentMessages) { _, messages in
                guard let last = messages.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            .onChange(of: appState.agentToolCalls.count) { _, _ in
                guard let last = appState.agentToolCalls.last else { return }
                proxy.scrollTo(toolGroupScrollID(for: last.messageID), anchor: .bottom)
            }
        }
    }

    private var visibleMessages: [AgentMessage] {
        appState.agentMessages.filter { message in
            message.role != .tool && !isEmptyThinkingPlaceholder(message)
        }
    }

    private func toolCalls(for messageID: AgentMessage.ID) -> [AgentToolCall] {
        appState.agentToolCalls.filter { $0.messageID == messageID }
    }

    private func isEmptyThinkingPlaceholder(_ message: AgentMessage) -> Bool {
        message.role == .assistant && message.content.isEmpty && message.toolCalls.isEmpty
    }

    private func shouldShowMessageBubble(_ message: AgentMessage) -> Bool {
        !(message.role == .assistant && message.content.isEmpty && !message.toolCalls.isEmpty)
    }

    private func toolGroupScrollID(for messageID: AgentMessage.ID) -> String {
        "agent-tools-\(messageID.uuidString)"
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: appState.rootDirectory == nil ? "folder.badge.questionmark" : "folder")
                    .foregroundStyle(.secondary)
                Text(contextLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }

            TextEditor(text: $appState.agentInput)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .focused($inputFocused)
                .frame(minHeight: 64, maxHeight: 110)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Text(contextHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    appState.sendAgentMessage()
                } label: {
                    Label(appState.isAgentResponding ? "Sending" : "Send", systemImage: "paperplane.fill")
                }
                .disabled(appState.isAgentResponding || appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
    }

    private var contextLabel: String {
        if let openedFileURL = appState.openedFileURL {
            return openedFileURL.lastPathComponent
        }
        if let rootDirectory = appState.rootDirectory {
            return rootDirectory.lastPathComponent
        }
        return "No workspace"
    }

    private var contextHint: String {
        if appState.rootDirectory == nil {
            return "Open a folder to enable tools"
        }
        if appState.selectedCharacterCount > 0 {
            return "Selection included · Tools available"
        }
        return "Active file included · Tools available"
    }
}

struct AgentContextCompressionDivider: View {
    var body: some View {
        AgentInlineStatusDivider(text: "正在自动压缩上下文")
    }
}

struct AgentThinkingDivider: View {
    var body: some View {
        AgentInlineStatusDivider(text: "正在思考")
    }
}

private struct AgentInlineStatusDivider: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.secondary.opacity(0.22))
                .frame(height: 1)
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.62)
                    .frame(width: 10, height: 10)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .fixedSize()
            Rectangle()
                .fill(Color.secondary.opacity(0.22))
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityLabel(text)
    }
}

struct AgentWorktreeChangeCard: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let change = appState.primaryAgentChangedFile {
                HStack(spacing: 7) {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("正在编辑")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    changedFileButton(change)
                    AgentLineStatsView(change: change)
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 8) {
                AgentWorktreeSummaryPill()
                Spacer(minLength: 0)
                Button {
                    appState.reviewAgentWorktreeChanges()
                } label: {
                    Text("审查")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .help("让 Agent 审查当前未提交改动")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func changedFileButton(_ change: AgentFileChangeSummary) -> some View {
        Button {
            appState.openAgentChangedFile(change.path)
        } label: {
            Text(change.fileName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .help(change.path)
    }
}

struct AgentWorktreeSummaryPill: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button {
            appState.reviewAgentWorktreeChanges()
        } label: {
            HStack(spacing: 6) {
                Text("\(appState.agentWorktreeChanges.fileCount) 个文件已更改")
                    .foregroundStyle(.secondary)
                Text("+\(appState.agentWorktreeChanges.totalAddedLines)")
                    .foregroundStyle(.green)
                Text("-\(appState.agentWorktreeChanges.totalDeletedLines)")
                    .foregroundStyle(.red)
            }
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("点击让 Agent 审查当前未提交改动")
    }
}

struct AgentLineStatsView: View {
    let change: AgentFileChangeSummary

    var body: some View {
        HStack(spacing: 4) {
            if change.hasKnownLineStats {
                Text("+\(change.addedLines)")
                    .foregroundStyle(.green)
                Text("-\(change.deletedLines)")
                    .foregroundStyle(.red)
            } else {
                Text(change.kind.rawValue)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .monospacedDigit()
    }
}

struct AgentToolCallGroup: View {
    let calls: [AgentToolCall]
    /// Optional codex-style headline ("已运行 3 条命令"). When set, it
    /// replaces the default "N tools" label and we also swap the icon
    /// to match the kind.
    var headline: String? = nil
    var headlineIcon: String? = nil
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: detailsVisible ? 5 : 0) {
            Button {
                if canToggleDetails {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: groupIconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(groupIconColor)
                        .frame(width: 14)
                    Text(titleText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(statusSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(previewSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: detailsVisible ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(canToggleDetails ? .secondary : Color.clear)
                        .frame(width: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canToggleDetails)
            .help(detailsVisible ? "Hide tool calls" : "Show tool calls")

            if detailsVisible {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(calls) { call in
                        AgentToolCallCard(call: call)
                    }
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(groupBorderColor, lineWidth: 1)
        )
    }

    private var detailsVisible: Bool {
        isExpanded || containsInteractiveCall
    }

    private var canToggleDetails: Bool {
        !containsInteractiveCall
    }

    private var containsInteractiveCall: Bool {
        calls.contains { call in
            switch call.status {
            case .pendingApproval, .awaitingConfirm, .awaitingUserAnswer:
                return true
            case .running, .succeeded, .failed, .denied:
                return false
            }
        }
    }

    private var titleText: String {
        if let headline, !headline.isEmpty { return headline }
        return calls.count == 1 ? "1 tool" : "\(calls.count) tools"
    }

    private var statusSummary: String {
        let waiting = calls.filter {
            $0.status == .pendingApproval || $0.status == .awaitingConfirm || $0.status == .awaitingUserAnswer
        }.count
        let running = calls.filter { $0.status == .running }.count
        let failed = calls.filter { $0.status == .failed }.count
        let denied = calls.filter { $0.status == .denied }.count
        let succeeded = calls.filter { $0.status == .succeeded }.count
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if running > 0 { parts.append("\(running) running") }
        if failed > 0 { parts.append("\(failed) failed") }
        if denied > 0 { parts.append("\(denied) denied") }
        if succeeded > 0 { parts.append("\(succeeded) done") }
        return parts.joined(separator: " · ")
    }

    private var previewSummary: String {
        let previews = calls.prefix(4).map { call in
            var text = call.toolName
            if let summary = call.result?.summary, !summary.isEmpty {
                text += " \(summary)"
            } else if let compactArguments = compactArguments(for: call), !compactArguments.isEmpty {
                text += " \(compactArguments)"
            }
            return text
        }
        let suffix = calls.count > previews.count ? " · +\(calls.count - previews.count) more" : ""
        return previews.joined(separator: " · ") + suffix
    }

    private func compactArguments(for call: AgentToolCall) -> String? {
        if call.toolName == "run_command", let command = call.arguments["command"]?.stringValue() {
            return "command=\(trimmed(command, limit: 34))"
        }
        if let path = call.arguments["path"]?.stringValue() {
            return "path=\(trimmed(path, limit: 34))"
        }
        if let pattern = call.arguments["pattern"]?.stringValue() {
            return "pattern=\(trimmed(pattern, limit: 34))"
        }
        return nil
    }

    private func trimmed(_ value: String, limit: Int) -> String {
        let normalized = value.replacingOccurrences(of: "\n", with: " ")
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<end]) + "…"
    }

    private var groupIconName: String {
        // Status-derived icons (failed / running / asking) take precedence
        // so the user can see a problem at a glance, even when the row is
        // collapsed. A static headline icon is only the calm-state default.
        if calls.contains(where: { $0.status == .failed }) { return "exclamationmark.triangle.fill" }
        if calls.contains(where: { $0.status == .running }) { return "hourglass" }
        if containsInteractiveCall { return "questionmark.circle" }
        if let headlineIcon, !headlineIcon.isEmpty { return headlineIcon }
        return "checkmark.circle.fill"
    }

    private var groupIconColor: Color {
        if calls.contains(where: { $0.status == .failed }) { return .orange }
        if calls.contains(where: { $0.status == .running }) { return .secondary }
        if containsInteractiveCall { return .blue }
        return .green
    }

    private var groupBorderColor: Color {
        if containsInteractiveCall { return Color.blue.opacity(0.28) }
        if calls.contains(where: { $0.status == .failed }) { return Color.orange.opacity(0.28) }
        return Color.primary.opacity(0.06)
    }
}

struct AgentToolCallCard: View {
    @EnvironmentObject var appState: AppState
    let call: AgentToolCall
    @State private var isExpanded = false
    @State private var confirmInput = ""
    @State private var answerInput = ""
    @State private var selectedOptions: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: isInteractive ? 6 : 3) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 14)
                Text(call.toolName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Text(argumentsSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let label = approvalSourceLabel {
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.12))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                        .help(approvalSourceTooltip ?? "")
                }
                if hasExpandableContent {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help(isExpanded ? "Collapse" : "Expand")
                }
            }
            .frame(minHeight: 20)
            .help("\(riskBadge): \(argumentsSummary)")

            if isExpanded {
                if !argumentsLines.isEmpty {
                    expandableBlock(title: "Arguments", text: argumentsLines)
                }
                if let payload = call.result?.payload, !payload.isEmpty {
                    expandableBlock(title: "Output", text: payload)
                }
                if let errorMessage = call.errorMessage, !errorMessage.isEmpty {
                    expandableBlock(title: "Error", text: errorMessage)
                }
            }

            if call.status == .pendingApproval {
                VStack(alignment: .leading, spacing: 6) {
                    approvalCommandBlock
                    HStack {
                        Button("Allow") { appState.approveAgentToolCall(id: call.id) }
                        if let signature = alwaysAllowSignature {
                            Button("Always Allow") { appState.alwaysAllowAgentToolCall(id: call.id) }
                                .help("Always allow future \(signature) commands")
                        }
                        Button("Deny") { appState.denyAgentToolCall(id: call.id) }
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                }
            } else if call.status == .awaitingConfirm {
                VStack(alignment: .leading, spacing: 4) {
                    approvalCommandBlock
                    Text("This is a destructive command. Type \"confirm\" to allow.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    HStack {
                        TextField("confirm", text: $confirmInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: 140)
                        Button("Run") {
                            _ = appState.confirmAgentToolCall(id: call.id, typedConfirmation: confirmInput)
                            confirmInput = ""
                        }
                        .disabled(confirmInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "confirm")
                        Button("Deny") {
                            appState.denyAgentToolCall(id: call.id)
                            confirmInput = ""
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                }
            } else if call.status == .awaitingUserAnswer {
                askUserBody
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, isInteractive ? 7 : 4)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var approvalCommandBlock: some View {
        if let command = fullCommand {
            VStack(alignment: .leading, spacing: 3) {
                Text("Command")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ScrollView([.horizontal, .vertical]) {
                    Text(command)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    @ViewBuilder
    private var askUserBody: some View {
        let question = call.arguments["question"]?.stringValue() ?? ""
        let options = call.arguments["options"]?.stringArrayValue() ?? []
        let isMultiSelect = call.arguments["multi_select"]?.boolValue() ?? false

        VStack(alignment: .leading, spacing: 8) {
            if !question.isEmpty {
                Text(question)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !options.isEmpty {
                if isMultiSelect {
                    multiSelectChoices(options)
                } else {
                    singleSelectChoices(options)
                }
            }

            // Free-form text input is always available — even with preset
            // options, the user may want to write "none of these".
            TextField(options.isEmpty ? "Your answer" : "Other answer (optional)",
                      text: $answerInput,
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .lineLimit(1...4)

            HStack(spacing: 6) {
                Button("Send") {
                    submitAnswer(options: options, isMultiSelect: isMultiSelect)
                }
                .disabled(!canSubmitAskUser(isMultiSelect: isMultiSelect))
                Button("Skip") {
                    appState.denyAgentToolCall(id: call.id)
                    resetAskUserInputs()
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
        }
    }

    private func singleSelectChoices(_ options: [String]) -> some View {
        // An adaptive grid gives us wrapping like a flow layout without
        // dragging in a third-party Layout implementation. Min item
        // width is generous so short options sit two-per-row at typical
        // panel widths.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button {
                    appState.answerAgentToolCall(id: call.id, answer: option)
                    resetAskUserInputs()
                } label: {
                    Text(option)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.purple.opacity(0.12))
                        .foregroundStyle(.primary)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.purple.opacity(0.35), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func multiSelectChoices(_ options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(options, id: \.self) { option in
                Toggle(isOn: Binding(
                    get: { selectedOptions.contains(option) },
                    set: { isOn in
                        if isOn { selectedOptions.insert(option) }
                        else { selectedOptions.remove(option) }
                    }
                )) {
                    Text(option).font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func canSubmitAskUser(isMultiSelect: Bool) -> Bool {
        if !answerInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if isMultiSelect { return !selectedOptions.isEmpty }
        return false
    }

    private func submitAnswer(options: [String], isMultiSelect: Bool) {
        // Free-form text wins if the user typed anything — gives them an
        // escape hatch from the preset options.
        let typed = answerInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer: String
        if !typed.isEmpty {
            answer = typed
        } else if isMultiSelect {
            // Preserve the order the model offered them so the
            // assistant can correlate.
            answer = options.filter { selectedOptions.contains($0) }.joined(separator: ", ")
        } else {
            return
        }
        appState.answerAgentToolCall(id: call.id, answer: answer)
        resetAskUserInputs()
    }

    private func resetAskUserInputs() {
        answerInput = ""
        selectedOptions = []
    }

    private func expandableBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 96)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private var argumentsSummary: String {
        guard !call.arguments.isEmpty else { return "(no arguments)" }
        return call.arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.displaySummary)" }
            .joined(separator: " · ")
    }

    private var argumentsLines: String {
        call.arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value.displaySummary)" }
            .joined(separator: "\n")
    }

    private var fullCommand: String? {
        guard call.toolName == "run_command",
              let command = call.arguments["command"]?.stringValue(),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return command
    }

    private var alwaysAllowSignature: String? {
        guard call.toolName == "run_command",
              let command = call.arguments["command"]?.stringValue() else {
            return nil
        }
        return AgentCommandAuthorization.signature(for: command)
    }

    private var iconName: String {
        switch call.status {
        case .pendingApproval, .awaitingConfirm: return "questionmark.circle"
        case .awaitingUserAnswer: return "bubble.left.and.text.bubble.right"
        case .running: return "hourglass"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .denied: return "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch call.status {
        case .pendingApproval, .awaitingConfirm: return .blue
        case .awaitingUserAnswer: return .purple
        case .running: return .secondary
        case .succeeded: return .green
        case .failed: return .orange
        case .denied: return .secondary
        }
    }

    private var statusColor: Color {
        switch call.status {
        case .pendingApproval, .awaitingConfirm: return .blue
        case .awaitingUserAnswer: return .purple
        case .failed: return .orange
        case .succeeded: return .green
        case .running, .denied: return .secondary
        }
    }

    private var isInteractive: Bool {
        switch call.status {
        case .pendingApproval, .awaitingConfirm, .awaitingUserAnswer:
            return true
        case .running, .succeeded, .failed, .denied:
            return isExpanded
        }
    }

    private var hasExpandableContent: Bool {
        !argumentsLines.isEmpty
        || !(call.result?.payload.isEmpty ?? true)
        || !(call.errorMessage?.isEmpty ?? true)
    }

    /// Show a small badge next to the status text when a write-tier
    /// tool call ran without the user clicking Allow, so it's auditable
    /// after the fact.
    private var approvalSourceLabel: String? {
        guard call.risk == .write,
              call.status == .running || call.status == .succeeded || call.status == .failed,
              let source = call.approvalSource else { return nil }
        switch source {
        case .user: return nil // explicit user clicks don't need a badge
        case .alwaysAllowList: return "ALWAYS"
        case .staticAllowlist: return "AUTO"
        case .llmJudge: return "AI OK"
        }
    }

    private var approvalSourceTooltip: String? {
        guard let source = call.approvalSource else { return nil }
        switch source {
        case .user: return nil
        case .alwaysAllowList: return "You pinned this command signature as always-allowed."
        case .staticAllowlist: return "Matched the built-in safe-command allowlist."
        case .llmJudge: return "An LLM judge classified this command as read-only / safe."
        }
    }

    private var cardBackground: Color {
        if isInteractive {
            return Color(nsColor: .controlBackgroundColor).opacity(0.72)
        }
        return Color(nsColor: .controlBackgroundColor).opacity(0.38)
    }

    private var statusText: String {
        switch call.status {
        case .pendingApproval: return "Awaiting approval"
        case .awaitingConfirm: return "Confirm required"
        case .awaitingUserAnswer: return "Asking you"
        case .running: return "Running…"
        case .succeeded:
            if let summary = call.result?.summary, !summary.isEmpty {
                return summary
            }
            return "Done"
        case .failed: return "Failed"
        case .denied: return "Denied"
        }
    }

    private var riskBadge: String {
        switch call.risk {
        case .read: return "READ"
        case .write: return "WRITE"
        case .danger: return "DANGER"
        case .userInput: return "ASK"
        }
    }

    private var riskBadgeColor: Color {
        switch call.risk {
        case .read: return .secondary
        case .write: return .blue
        case .danger: return .orange
        case .userInput: return .purple
        }
    }

    private var borderColor: Color {
        switch call.status {
        case .pendingApproval, .awaitingConfirm: return Color.blue.opacity(0.4)
        case .awaitingUserAnswer: return Color.purple.opacity(0.4)
        case .failed: return Color.orange.opacity(0.4)
        case .denied: return Color.secondary.opacity(0.3)
        default: return Color.clear
        }
    }
}

struct AgentErrorCard: View {
    let message: String
    let details: AgentErrorDetails?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.top, 1)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if details != nil {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Label(isExpanded ? "Hide Details" : "Details",
                              systemImage: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(isExpanded ? "Hide provider error details" : "Show provider error details")
                }
            }

            if isExpanded, let details {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(details.sections) { section in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            ScrollView([.horizontal, .vertical]) {
                                Text(section.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: section.title == "Request Body" ? 180 : 120)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.red.opacity(0.18), lineWidth: 1)
        )
    }
}

struct AgentPatchProposalCard: View {
    @EnvironmentObject var appState: AppState
    let proposal: AgentPatchProposal
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Hide Diff" : "Show Diff")
            }

            if isExpanded {
                ScrollView(.horizontal) {
                    Text(proposal.diff)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 180)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Button {
                    appState.applyAgentPatchProposal(id: proposal.id)
                } label: {
                    Label("Apply", systemImage: "checkmark.circle")
                }
                .disabled(proposal.status != .pending)

                Button {
                    appState.rejectAgentPatchProposal(id: proposal.id)
                } label: {
                    Label("Reject", systemImage: "xmark.circle")
                }
                .disabled(proposal.status != .pending)

                Spacer(minLength: 0)
            }
            .labelStyle(.titleAndIcon)
            .font(.caption)
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var iconName: String {
        switch proposal.status {
        case .pending:
            return "doc.text.magnifyingglass"
        case .applied:
            return "checkmark.circle.fill"
        case .rejected:
            return "xmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch proposal.status {
        case .pending:
            return .secondary
        case .applied:
            return .green
        case .rejected:
            return .secondary
        case .failed:
            return .orange
        }
    }

    private var statusText: String {
        proposal.statusMessage ?? proposal.status.rawValue.capitalized
    }
}

private struct AgentEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("Ask about this project")
                .font(.system(size: 14, weight: .semibold))
            Text("The agent can read files, search, list directories, run commands (with approval), and check Git status.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
    }
}

struct AgentMessageBubble: View {
    let message: AgentMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(displayContent)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !message.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(message.images) { image in
                            AgentImageThumbnail(image: image, size: 96, allowsRemoval: false, onRemove: nil)
                        }
                    }
                }
            }
        }
        .padding(9)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var displayContent: String {
        if message.content.isEmpty {
            if !message.toolCalls.isEmpty {
                return "Using tools…"
            }
            if !message.images.isEmpty {
                return ""
            }
            return "…"
        }
        return message.content
    }

    private var title: String {
        switch message.role {
        case .system: return "System"
        case .user: return "You"
        case .assistant: return "Agent"
        case .tool: return "Tool"
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .system:
            return Color(nsColor: .controlBackgroundColor).opacity(0.45)
        case .user:
            return Color.accentColor.opacity(0.12)
        case .assistant:
            return Color(nsColor: .controlBackgroundColor).opacity(0.75)
        case .tool:
            return Color(nsColor: .controlBackgroundColor).opacity(0.4)
        }
    }
}
