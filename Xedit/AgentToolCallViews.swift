//
//  AgentToolCallViews.swift
//  WillDeep
//
//  Tool call group and card views used by the agent transcript.
//

import SwiftUI
import AppKit

struct AgentToolCallGroup: View {
    @EnvironmentObject var appState: AppState
    let calls: [AgentToolCall]
    /// Optional codex-style headline ("已运行 3 条命令"). When set, it
    /// replaces the default "N tools" label and we also swap the icon
    /// to match the kind.
    var headline: String? = nil
    var headlineIcon: String? = nil
    @State private var isExpanded = false

    var body: some View {
        let status = statusSummary
        VStack(alignment: .leading, spacing: detailsVisible ? 8 : 0) {
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
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !status.isEmpty {
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if let previewSummary {
                        Text(previewSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer(minLength: 0)
                    }
                    Image(systemName: detailsVisible ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(canToggleDetails ? .secondary : Color.clear)
                        .frame(width: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canToggleDetails)
            .help(detailsVisible ? L10n.ToolCard.collapse : L10n.ToolCard.expand)

            if detailsVisible {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(calls) { call in
                        AgentToolCallCard(call: call)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, detailsVisible ? 8 : 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(groupBorderColor, lineWidth: 1)
        )
        // The expanded card paints padding above its title row. Give that
        // expanded chrome its own external breathing room so it never
        // visually climbs into the previous assistant bubble.
        .padding(.top, detailsVisible ? 8 : 0)
    }

    private var detailsVisible: Bool {
        // Interactive states (ask_user / pendingApproval / awaitingConfirm)
        // need the user's attention NOW — if the group stayed collapsed
        // the user would have to first hunt down the activity summary
        // header and click it to even see the question / approval prompt.
        // Force-expand whenever any inner call is interactive; respect
        // `isExpanded` otherwise so non-interactive bundles stay tidy.
        isExpanded || containsInteractiveCall
    }

    private var canToggleDetails: Bool {
        // While the group has an interactive call we lock it open. The
        // user can still collapse historic groups (no waiting calls)
        // freely.
        !calls.isEmpty && !containsInteractiveCall
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
        if let activityText = AgentToolActivitySummary(calls: calls).activityText {
            return activityText
        }
        if calls.count == 1, let first = calls.first {
            return "已调用 \(first.toolName)"
        }
        return "已调用 \(calls.count) 个工具"
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
        if succeeded == calls.count, waiting == 0, running == 0, failed == 0, denied == 0 {
            return ""
        }
        if waiting > 0 { parts.append("\(waiting) 待处理") }
        if running > 0 { parts.append("\(running) 运行中") }
        if failed > 0 { parts.append("\(failed) 失败") }
        if denied > 0 { parts.append("\(denied) 已拒绝") }
        if succeeded > 0 { parts.append("\(succeeded) 完成") }
        return parts.joined(separator: " · ")
    }

    private var previewSummary: String? {
        guard detailsVisible else { return nil }
        let previews = calls.prefix(3).map { call in
            var text = call.toolName
            if let summary = call.result?.summary, !summary.isEmpty {
                text += " \(summary)"
            } else if let compactArguments = compactArguments(for: call), !compactArguments.isEmpty {
                text += " \(compactArguments)"
            }
            return text
        }
        let suffix = calls.count > previews.count ? " · +\(calls.count - previews.count) more" : ""
        let summary = previews.joined(separator: " · ") + suffix
        return summary.isEmpty ? nil : summary
    }

    private func compactArguments(for call: AgentToolCall) -> String? {
        if call.toolName == "run_command", let command = call.arguments["command"]?.stringValue() {
            let cwd = call.arguments["cwd"]?.stringValue().map { "  cwd: \(trimmed($0, limit: 72))" } ?? ""
            return "command: \(trimmed(command, limit: 140))\(cwd)"
        }
        if call.toolName == "spawn_agent" {
            let label = call.arguments["label"]?.stringValue()
                ?? call.arguments["prompt"]?.stringValue()
                ?? ""
            return label.isEmpty ? nil : "task: \(trimmed(label, limit: 120))"
        }
        if ["claude_code", "codex_cli", "cursor_agent"].contains(call.toolName) {
            let prompt = call.arguments["prompt"]?.stringValue() ?? ""
            let mode = call.arguments["permission_mode"]?.stringValue().map { "  mode: \($0)" } ?? ""
            return prompt.isEmpty ? nil : "task: \(trimmed(prompt, limit: 120))\(mode)"
        }
        if let path = call.arguments["path"]?.stringValue() {
            return "path: \(trimmed(path, limit: 120))"
        }
        if let pattern = call.arguments["pattern"]?.stringValue() {
            return "pattern: \(trimmed(pattern, limit: 120))"
        }
        if let query = call.arguments["query"]?.stringValue() {
            return "query: \(trimmed(query, limit: 120))"
        }
        return nil
    }

    private func trimmed(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
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
        if containsInteractiveCall { return appState.editorSettings.interfaceSkin.palette.accent }
        return .secondary
    }

    private var groupBorderColor: Color {
        if containsInteractiveCall { return appState.editorSettings.interfaceSkin.palette.accent.opacity(0.28) }
        if calls.contains(where: { $0.status == .failed }) { return Color.orange.opacity(0.28) }
        return Color.primary.opacity(0.04)
    }
}

struct AgentToolCallCard: View {
    @EnvironmentObject var appState: AppState
    let call: AgentToolCall
    @State private var isExpanded = false
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
                    .help(isExpanded ? L10n.ToolCard.collapse : L10n.ToolCard.expand)
                }
            }
            .frame(minHeight: 20)
            .help("\(riskBadge): \(argumentsSummary)")

            if isExpanded {
                if !argumentsLines.isEmpty {
                    expandableBlock(title: L10n.ToolCard.arguments, text: argumentsLines)
                }
                if let payload = call.result?.payload, !payload.isEmpty {
                    expandableBlock(title: L10n.ToolCard.output, text: payload)
                }
                if let errorMessage = call.errorMessage, !errorMessage.isEmpty {
                    expandableBlock(title: L10n.ToolCard.error, text: errorMessage)
                }
            }

            if call.status == .pendingApproval {
                VStack(alignment: .leading, spacing: 6) {
                    approvalCommandBlock
                    // rc16:把 Deny 推到最左,Allow / Always Allow 在右侧簇集,
                    // 对齐 macOS「主操作右、负操作远离」防误触习惯。
                    HStack {
                        // 拒绝:空心(描边)按钮;允许:实心(高亮)主操作。
                        Button(L10n.ToolCard.deny) { appState.denyAgentToolCall(id: call.id) }
                            .buttonStyle(.bordered)
                        Spacer(minLength: 0)
                        if let signature = alwaysAllowSignature {
                            Button(L10n.ToolCard.alwaysAllow) { appState.alwaysAllowAgentToolCall(id: call.id) }
                                .buttonStyle(.bordered)
                                .help(L10n.ToolCard.alwaysAllowHelp(signature))
                        }
                        Button(L10n.ToolCard.allow) { appState.approveAgentToolCall(id: call.id) }
                            .buttonStyle(.borderedProminent)
                    }
                    .font(.caption)
                    .controlSize(.small)
                }
            } else if call.status == .awaitingConfirm {
                VStack(alignment: .leading, spacing: 6) {
                    approvalCommandBlock
                    Text(L10n.ToolCard.destructiveWarning)
                        .font(.caption2)
                        .foregroundStyle(destructiveAccentColor)
                    // rc16:同上,Deny 在左,Confirm Run 在右。
                    HStack {
                        Button(L10n.ToolCard.deny) {
                            appState.denyAgentToolCall(id: call.id)
                        }
                        Spacer(minLength: 0)
                        Button {
                            _ = appState.confirmAgentToolCall(id: call.id, typedConfirmation: "confirm")
                        } label: {
                            Text(L10n.ToolCard.confirmRun)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .foregroundStyle(destructiveAccentColor)
                                .background(Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(destructiveAccentColor.opacity(0.62), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.caption)
                }
            } else if call.status == .awaitingUserAnswer {
                askUserBody
            } else if call.toolName == "ask_user" {
                askUserResolvedRow
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
                Text(L10n.ToolCard.command)
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
        // rc3: option labels are LLM-authored. Defang first so the button
        // the user clicks shows the same string the model gets back as the
        // user's answer — and so options can't smuggle control characters
        // or `<system>` framing through the chat UI.
        let rawOptions = call.arguments["options"]?.stringArrayValue() ?? []
        let options = AgentInjectionDefense.sanitizeAskUserOptions(rawOptions)
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
            TextField(options.isEmpty ? L10n.ToolCard.askUserAnswerPlaceholder : L10n.ToolCard.askUserOtherAnswerPlaceholder,
                      text: $answerInput,
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .lineLimit(1...4)

            // rc16:Skip 在左、Send 在右,对齐「正向操作右、误触概率低」的
            // macOS 习惯。Send 的 disabled 状态自然把视觉重心保留在右侧。
            HStack(spacing: 6) {
                Button(L10n.ToolCard.askUserSkip) {
                    appState.denyAgentToolCall(id: call.id)
                    resetAskUserInputs()
                }
                Spacer(minLength: 0)
                Button(L10n.ToolCard.askUserSend) {
                    submitAnswer(options: options, isMultiSelect: isMultiSelect)
                }
                .disabled(!canSubmitAskUser(isMultiSelect: isMultiSelect))
            }
            .font(.caption)
        }
    }

    // After the question resolves the interactive card is gone, but the
    // chosen answer used to survive only inside the collapsed "output"
    // expander — so the transcript looked like the user's selection
    // vanished. Echo it back as an always-visible, clearly-attributed row
    // so the conversation reads coherently. (The model still receives the
    // answer via the `<user_answer>` tool message; this is render-only.)
    @ViewBuilder
    private var askUserResolvedRow: some View {
        let answer = (call.result?.payload ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if call.status == .succeeded, !answer.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(askUserSecondaryAccentColor.opacity(0.72))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.ToolCard.askUserAnswered)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(answer)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(askUserAccentColor.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(askUserAccentColor.opacity(0.28), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else if call.status == .denied {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.6))
                Text(L10n.ToolCard.askUserSkipped)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func singleSelectChoices(_ options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button {
                    appState.answerAgentToolCall(id: call.id, answer: option)
                    resetAskUserInputs()
                } label: {
                    HStack(spacing: 8) {
                        Text(option)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.turn.down.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(askUserSecondaryAccentColor.opacity(0.72))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.primary)
                    .background(askUserAccentColor.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(askUserAccentColor.opacity(0.28), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func multiSelectChoices(_ options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { option in
                Toggle(isOn: Binding(
                    get: { selectedOptions.contains(option) },
                    set: { isOn in
                        if isOn { selectedOptions.insert(option) }
                        else { selectedOptions.remove(option) }
                    }
                )) {
                    Text(option)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selectedOptions.contains(option) ? askUserAccentColor.opacity(0.10) : appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.58))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(selectedOptions.contains(option) ? askUserAccentColor.opacity(0.32) : appState.editorSettings.interfaceSkin.palette.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
        AgentToolAuthorization.signature(for: call)
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
        case .pendingApproval: return appState.editorSettings.interfaceSkin.palette.accent
        case .awaitingConfirm: return destructiveAccentColor
        case .awaitingUserAnswer: return askUserAccentColor
        case .running: return .secondary
        case .succeeded: return .secondary
        case .failed: return .orange
        case .denied: return .secondary
        }
    }

    private var statusColor: Color {
        switch call.status {
        case .pendingApproval: return appState.editorSettings.interfaceSkin.palette.accent
        case .awaitingConfirm: return destructiveAccentColor
        case .awaitingUserAnswer: return askUserAccentColor
        case .failed: return .orange
        case .running, .succeeded, .denied: return .secondary
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
        case .goalMode: return "GOAL"
        case .workspaceAccess: return "WORKSPACE"
        case .escalated: return "ESCALATED"
        case .trustedServer: return "TRUSTED"
        }
    }

    private var approvalSourceTooltip: String? {
        guard let source = call.approvalSource else { return nil }
        switch source {
        case .user: return nil
        case .alwaysAllowList: return "You pinned this command signature as always-allowed."
        case .staticAllowlist: return "Matched the built-in read-only allowlist (safe shell commands / read-style MCP tools)."
        case .llmJudge: return "An LLM judge classified this call as read-only / safe."
        case .goalMode: return "Auto-approved because this session is in Goal mode. Danger-tier commands still ask."
        case .workspaceAccess: return "Auto-approved by this session's Workspace Access approval mode. Danger-tier commands still ask."
        case .escalated: return "You approved this call to run outside the default sandbox boundary."
        case .trustedServer: return "You marked this MCP server as fully trusted — all its calls auto-run."
        }
    }

    private var cardBackground: Color {
        if isInteractive {
            return appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.72)
        }
        return appState.editorSettings.interfaceSkin.palette.controlFill.opacity(0.38)
    }

    private var statusText: String {
        switch call.status {
        case .pendingApproval: return L10n.ToolCard.statusAwaitingApproval
        case .awaitingConfirm: return L10n.ToolCard.statusConfirmRequired
        case .awaitingUserAnswer: return L10n.ToolCard.statusAskingYou
        case .running: return L10n.ToolCard.statusRunning
        case .succeeded:
            if let summary = call.result?.summary, !summary.isEmpty {
                return summary
            }
            return L10n.ToolCard.statusDone
        case .failed: return L10n.ToolCard.statusFailed
        case .denied: return L10n.ToolCard.statusDenied
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

    private var borderColor: Color {
        switch call.status {
        case .pendingApproval: return appState.editorSettings.interfaceSkin.palette.accent.opacity(0.4)
        case .awaitingConfirm: return destructiveAccentColor.opacity(0.42)
        case .awaitingUserAnswer: return askUserAccentColor.opacity(0.4)
        case .failed: return Color.orange.opacity(0.4)
        case .denied: return Color.secondary.opacity(0.3)
        default: return Color.clear
        }
    }

    private var destructiveAccentColor: Color {
        Color(red: 0.68, green: 0.16, blue: 0.16)
    }

    private var askUserAccentColor: Color {
        appState.editorSettings.interfaceSkin.palette.accent
    }

    private var askUserSecondaryAccentColor: Color {
        appState.editorSettings.interfaceSkin.palette.secondaryAccent
    }
}
