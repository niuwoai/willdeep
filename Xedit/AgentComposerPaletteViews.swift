//
//  AgentComposerPaletteViews.swift
//  WillDeep
//
//  Slash command palette, @ attachment picker, $ skill picker, composer chips, and
//  compact session mode badges used by the Agent composer/sidebar.
//

import SwiftUI
import AppKit

// MARK: - Slash commands

/// A single command shown in the "/" palette. Pure local actions — no
/// network, no LLM round-trip. Each one runs synchronously against
/// AppState. The model-picker case opens the existing model picker
/// surface; the others call public AppState APIs directly.
enum SlashCommandArgumentMode: Equatable {
    case none
    case optional(placeholder: String)
    case required(placeholder: String)

    var placeholder: String? {
        switch self {
        case .none: return nil
        case .optional(let placeholder), .required(let placeholder): return placeholder
        }
    }

    var acceptsArguments: Bool {
        self != .none
    }

    var requiresArguments: Bool {
        if case .required = self { return true }
        return false
    }
}

struct SlashCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let argumentMode: SlashCommandArgumentMode
    /// 接收用户输入框里去掉 leading slash-command 后的 trailing args
    /// （已 trim 空白）。绝大多数命令忽略这个参数；workflow 类命令
    /// 把它当 query 转给 startWorkflow。
    let action: (_ args: String) -> Void

    init(
        id: String,
        title: String,
        subtitle: String,
        symbol: String,
        argumentMode: SlashCommandArgumentMode = .none,
        action: @escaping (_ args: String) -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.argumentMode = argumentMode
        self.action = action
    }

    static func builtIn(state: AppState) -> [SlashCommand] {
        let core: [SlashCommand] = [
            SlashCommand(id: "new", title: "/new", subtitle: "Start a fresh chat in this workspace", symbol: "square.and.pencil") { _ in
                state.startNewAgentSession()
            },
            SlashCommand(id: "clear", title: "/clear", subtitle: "Clear the current chat's messages", symbol: "eraser") { _ in
                state.clearAgentConversation()
            },
            SlashCommand(id: "compress", title: "/compress", subtitle: "Summarize older turns to free context", symbol: "rectangle.compress.vertical") { _ in
                state.compressAgentContext()
            },
            SlashCommand(id: "stop", title: "/stop", subtitle: "Stop the current response and workflows", symbol: "stop.circle") { _ in
                state.stopAgentResponse()
            },
            SlashCommand(id: "clear-queue", title: "/clear-queue", subtitle: "Drop any pending queued messages", symbol: "tray.2") { _ in
                state.clearAgentQueue()
            },
            SlashCommand(id: "copy-last", title: "/copy-last", subtitle: "Copy the last assistant message", symbol: "doc.on.doc") { _ in
                guard let last = state.agentMessages.last(where: { $0.role == .assistant }) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(last.content, forType: .string)
            },
        ]
        // 1.81.0-rc1：注册内置 workflow 为 slash 命令（/research,
        // /code-review, /bug-hunt, /competitor）。args 部分作为 query
        // 转给 startWorkflow，runtime 内起后台 task 跑 engine。
        let designToCode = SlashCommand(
            id: "screenshot-to-code",
            title: "/screenshot-to-code",
            subtitle: "Implement a UI screenshot, run it, and complete visual acceptance",
            symbol: "wand.and.stars",
            argumentMode: .required(placeholder: "<path> [framework=react] [context=\"where this screen lives\"]")
        ) { args in
            state.startDesignToCodeFromSlashArguments(args)
        }
        let workflows: [SlashCommand] = WorkflowRegistry.all
            .filter { $0.name != "screenshot-to-code" }
            .map { workflow in
            SlashCommand(
                id: "workflow-\(workflow.name)",
                title: workflow.slashCommand,
                subtitle: workflow.shortDescription,
                symbol: "wand.and.rays",
                argumentMode: workflow.allowsEmptyArgs
                    ? .optional(placeholder: workflow.argsPlaceholder)
                    : .required(placeholder: workflow.argsPlaceholder)
            ) { args in
                state.startWorkflow(slashCommand: workflow.slashCommand, args: args)
            }
        }
        return core + [designToCode] + workflows
    }

    /// Filters by fuzzy-ish prefix on the slash-stripped query. The text
    /// view passes `"/cl"` etc. — we strip the leading slash and match
    /// either the canonical id or the title prefix. Empty query (just
    /// `/`) lists everything.
    ///
    /// 1.81.0-rc1：workflow 命令带 args（`/research my topic`），所以
    /// 取第一个空格前的部分当命令名做 filter；之后的内容由
    /// `argsForCommand(_:)` 在 dispatch 时切出来传给 action。
    static func filter(_ rawInput: String, allCommands: [SlashCommand]) -> [SlashCommand] {
        let trimmed = rawInput.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return [] }
        let head: String
        if let spaceIdx = trimmed.firstIndex(of: " ") {
            head = String(trimmed[..<spaceIdx])
        } else {
            head = trimmed
        }
        let query = String(head.dropFirst()).lowercased()
        guard !query.isEmpty else { return allCommands }
        return allCommands.filter { c in
            c.id.lowercased().contains(query) || c.title.lowercased().contains(query)
        }
    }

    /// 从 composer 当前 input 切出 args 部分（第一个空格之后的内容）。
    /// workflow 命令用，core 命令忽略。
    static func argsForCommand(_ rawInput: String) -> String {
        let trimmed = rawInput.trimmingCharacters(in: .whitespaces)
        guard let spaceIdx = trimmed.firstIndex(of: " ") else { return "" }
        return String(trimmed[trimmed.index(after: spaceIdx)...])
            .trimmingCharacters(in: .whitespaces)
    }

    /// Finds an exact slash-command invocation in the composer. Arguments
    /// are deliberately excluded from matching so `/research topic` resolves
    /// to `/research`, while ordinary prose beginning with `/` falls through.
    static func invocation(
        in rawInput: String,
        commands: [SlashCommand]
    ) -> (command: SlashCommand, args: String)? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let commandName = String(trimmed.prefix { !$0.isWhitespace })
        guard let command = commands.first(where: { $0.title == commandName }) else { return nil }
        return (command, argsForCommand(rawInput))
    }
}

struct SlashCommandMenu: View {
    let commands: [SlashCommand]
    @Binding var selection: Int
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if commands.isEmpty {
                Text("No matching commands")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                    SlashCommandRow(command: command, isSelected: index == selection)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(index) }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
        .alignmentGuide(.top) { $0[.bottom] }
        .fixedSize()
    }
}

private struct SlashCommandRow: View {
    let command: SlashCommand
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: command.symbol)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Text(command.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
                if let placeholder = command.argumentMode.placeholder {
                    Text(placeholder)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.85))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor : Color.clear)
    }
}

// MARK: - @ picker and composer chips

/// Thin holder so the composer card can hand its coordinator reference
/// out to SwiftUI menu callbacks. NSViewRepresentable's `makeCoordinator`
/// is the canonical owner; we just need to surface a way to call
/// `replaceCurrentAtToken` from outside the text view's own delegate.
final class ComposerCoordinatorRef {
    weak var coordinator: ComposerTextEditor.Coordinator?
}

/// Chips of currently-attached skills, sitting above the text editor so
/// the user always sees what's about to ride along with the next send.
struct AgentComposerSkillStrip: View {
    let skills: [AgentSkillEntry]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(skills) { skill in
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                        Text("$\(skill.identifier)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                        Button {
                            onRemove(skill.identifier)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(Color.accentColor.opacity(0.10)))
                    .overlay(Capsule(style: .continuous).stroke(Color.accentColor.opacity(0.30), lineWidth: 1))
                    .help(skill.description)
                }
            }
        }
    }
}

/// Chips for non-skill attachments: workspace overview + per-file
/// references. Same removable pill design as the skill strip, but in a
/// distinct accent so users can tell at a glance which kind of context
/// is riding along this turn.
struct AgentComposerAttachmentStrip: View {
    let includeWorkspace: Bool
    let files: [AgentFileAttachment]
    let onRemoveWorkspace: () -> Void
    let onRemoveFile: (String) -> Void
    let onToggleFileSection: (String, String) -> Void
    let onSetAllFileSections: (String, Bool) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if includeWorkspace {
                    chip(
                        symbol: "folder",
                        label: "@workspace",
                        help: "Workspace root + file list will ride along",
                        onRemove: onRemoveWorkspace
                    )
                }
                ForEach(files) { file in
                    AgentComposerFileAttachmentChip(
                        file: file,
                        onRemove: { onRemoveFile(file.id) },
                        onToggleSection: { onToggleFileSection(file.id, $0) },
                        onSetAllSections: { onSetAllFileSections(file.id, $0) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func chip(symbol: String, label: String, help: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(Color.purple)
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(Color.purple.opacity(0.10)))
        .overlay(Capsule(style: .continuous).stroke(Color.purple.opacity(0.30), lineWidth: 1))
        .help(help)
    }
}

/// One row in the `@` popover. Project files and the special `workspace`
/// shortcut are unified so the user can fuzzy-match across attachable
/// context references without mixing them with `$` skills.
enum AtPickerEntry: Identifiable, Equatable {
    case workspace
    case file(url: URL, relativePath: String)

    var id: String {
        switch self {
        case .workspace: return "@workspace"
        case .file(let url, _): return "file:\(url.standardizedFileURL.path)"
        }
    }

    var symbol: String {
        switch self {
        case .workspace: return "folder"
        case .file: return "doc.text"
        }
    }

    var title: String {
        switch self {
        case .workspace: return "workspace"
        case .file(_, let rel): return rel
        }
    }

    var subtitle: String {
        switch self {
        case .workspace: return "Attach the current workspace root + file list"
        case .file(let url, _): return url.deletingLastPathComponent().lastPathComponent
        }
    }
}

/// One row in the `$` popover. `$` is reserved for reusable capability
/// packs / skills, matching the product convention that `/` is an action
/// command and `@` is an object reference.
enum SkillPickerEntry: Identifiable, Equatable {
    case skill(AgentSkillEntry)

    var id: String {
        switch self {
        case .skill(let skill): return "skill:\(skill.identifier)"
        }
    }

    var symbol: String { "wand.and.stars" }

    var title: String {
        switch self {
        case .skill(let skill): return skill.identifier
        }
    }

    var subtitle: String {
        switch self {
        // Localized description so a zh user sees the skill explained in
        // Chinese instead of the raw English SKILL.md frontmatter. The
        // title stays the raw `$identifier` because that is the literal
        // invocation token the user types.
        case .skill(let skill): return AgentSkillLocalization.displayDescription(for: skill)
        }
    }
}

struct AtPickerMenu: View {
    private enum Metrics {
        static let width: CGFloat = 540
        static let maxListHeight: CGFloat = 340
    }

    let entries: [AtPickerEntry]
    @Binding var query: String
    @Binding var selection: Int
    let onPick: (Int) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(L10n.Composer.atPickerSearchPlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(L10n.AgentSidePanel.close)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .padding(.horizontal, 8)
            .padding(.top, 8)

            if entries.isEmpty {
                Text(L10n.Composer.atPickerNoMatches)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            AtPickerRow(entry: entry, isSelected: index == selection)
                                .contentShape(Rectangle())
                                .onTapGesture { onPick(index) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: Metrics.maxListHeight)
            }
        }
        .padding(.bottom, 6)
        .frame(width: Metrics.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
    }
}

private struct AtPickerRow: View {
    let entry: AtPickerEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.symbol)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor : Color.clear)
    }
}

nonisolated enum SkillPickerLayout {
    static let minimumVisibleRowCount = 3
    static let rowHeight: CGFloat = 38
    static let maximumListHeight: CGFloat = 340

    static func minimumListHeight(entryCount: Int) -> CGFloat {
        CGFloat(min(max(entryCount, 0), minimumVisibleRowCount)) * rowHeight
    }
}

struct SkillPickerMenu: View {
    private enum Metrics {
        static let width: CGFloat = 540
    }

    let entries: [SkillPickerEntry]
    @Binding var query: String
    @Binding var selection: Int
    let onPick: (Int) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(L10n.Composer.skillPickerSearchPlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(L10n.AgentSidePanel.close)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .padding(.horizontal, 8)
            .padding(.top, 8)

            if entries.isEmpty {
                Text(L10n.Composer.skillPickerNoMatches)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            SkillPickerRow(entry: entry, isSelected: index == selection)
                                .contentShape(Rectangle())
                                .onTapGesture { onPick(index) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(
                    minHeight: SkillPickerLayout.minimumListHeight(entryCount: entries.count),
                    maxHeight: SkillPickerLayout.maximumListHeight
                )
            }
        }
        .padding(.bottom, 6)
        .frame(width: Metrics.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
    }
}

private struct SkillPickerRow: View {
    let entry: SkillPickerEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.symbol)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("$\(entry.title)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minHeight: SkillPickerLayout.rowHeight)
        .background(isSelected ? Color.accentColor : Color.clear)
    }
}

// MARK: - Sidebar session mode badges

/// Tiny right-aligned indicators on each session row that summarise the
/// session's plan/goal progress at a glance. Plan badge shows
/// `done/total`; goal badge shows `done/total` of the checklist. Skipped
/// here for sessions in Normal mode or with empty plan/goal so we don't
/// add visual noise to ordinary chats.
struct AgentSessionModeBadges: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 4) {
            if let plan = session.currentPlan, !plan.steps.isEmpty {
                badge(
                    symbol: "list.number",
                    color: planBadgeColor(plan),
                    text: planProgress(plan),
                    help: planHelp(plan)
                )
            }
            if let goal = session.currentGoal, !goal.checklist.isEmpty {
                let doneCount = goal.checklist.filter(\.done).count
                badge(
                    symbol: "target",
                    color: doneCount == goal.checklist.count ? .green : .accentColor,
                    text: "\(doneCount)/\(goal.checklist.count)",
                    help: goal.statement.isEmpty ? "Goal progress" : goal.statement
                )
            }
        }
    }

    @ViewBuilder
    private func badge(symbol: String, color: Color, text: String, help: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
            Text(text)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule(style: .continuous))
        .help(help)
    }

    private func planProgress(_ plan: AgentPlan) -> String {
        let done = plan.steps.filter { $0.status == .done }.count
        return "\(done)/\(plan.steps.count)"
    }

    private func planBadgeColor(_ plan: AgentPlan) -> Color {
        switch plan.status {
        case .proposed, .rejected: return .orange
        case .approved, .executing: return .accentColor
        case .done: return .green
        }
    }

    private func planHelp(_ plan: AgentPlan) -> String {
        switch plan.status {
        case .proposed: return "Plan awaiting approval"
        case .approved: return "Plan approved, not started"
        case .executing: return "Plan executing"
        case .done: return "Plan complete"
        case .rejected: return "Plan rejected"
        }
    }
}

nonisolated struct AgentSessionTodoSummary: Equatable {
    enum Kind: Equatable { case plan, goal }

    let kind: Kind
    let completed: Int
    let total: Int
    let text: String
    let isBlocked: Bool
    let isComplete: Bool
}

enum AgentSessionTodoSummaryLogic {
    static func summary(for session: AgentSession) -> AgentSessionTodoSummary? {
        if let plan = session.currentPlan,
           !plan.steps.isEmpty,
           plan.status != .rejected {
            return planSummary(plan)
        }
        if let goal = session.currentGoal,
           !goal.checklist.isEmpty {
            return goalSummary(goal)
        }
        return nil
    }

    private static func planSummary(_ plan: AgentPlan) -> AgentSessionTodoSummary? {
        let completed = plan.steps.filter { $0.status == .done || $0.status == .skipped }.count
        let current = plan.steps.first { $0.status == .inProgress }
            ?? plan.steps.first { $0.status == .pending }
            ?? plan.steps.first { $0.status == .failed }
            ?? plan.steps.last
        guard let current else { return nil }
        return AgentSessionTodoSummary(
            kind: .plan,
            completed: completed,
            total: plan.steps.count,
            text: current.text,
            isBlocked: plan.status == .proposed || plan.steps.contains(where: { $0.status == .failed }),
            isComplete: plan.status == .done || completed == plan.steps.count
        )
    }

    private static func goalSummary(_ goal: AgentGoal) -> AgentSessionTodoSummary? {
        let completed = goal.checklist.filter(\.done).count
        let current = goal.checklist.first { !$0.done } ?? goal.checklist.last
        guard let current else { return nil }
        return AgentSessionTodoSummary(
            kind: .goal,
            completed: completed,
            total: goal.checklist.count,
            text: current.text,
            isBlocked: false,
            isComplete: completed == goal.checklist.count
        )
    }
}

struct AgentSessionTodoSummaryRow: View {
    let summary: AgentSessionTodoSummary

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 12)
            Text("\(summary.completed)/\(summary.total)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(summary.text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, 20)
        .help(helpText)
        .accessibilityLabel(Text(helpText))
    }

    private var iconName: String {
        if summary.isComplete { return "checkmark.circle.fill" }
        if summary.isBlocked { return "exclamationmark.circle.fill" }
        switch summary.kind {
        case .plan: return "circle.dotted"
        case .goal: return "target"
        }
    }

    private var tint: Color {
        if summary.isComplete { return .green }
        if summary.isBlocked { return .orange }
        switch summary.kind {
        case .plan: return .accentColor
        case .goal: return .purple
        }
    }

    private var helpText: String {
        switch summary.kind {
        case .plan:
            return L10n.Sidebar.sessionTodoPlanTooltip(
                "\(summary.completed)",
                "\(summary.total)",
                summary.text
            )
        case .goal:
            return L10n.Sidebar.sessionTodoGoalTooltip(
                "\(summary.completed)",
                "\(summary.total)",
                summary.text
            )
        }
    }
}

struct AgentSessionTodoSummaryContainer: View {
    let session: AgentSession
    let runtime: AgentRuntime?
    let fallbackSummary: AgentSessionTodoSummary

    var body: some View {
        if let runtime {
            ObservedAgentSessionTodoSummaryRow(
                runtime: runtime,
                fallbackSummary: fallbackSummary
            )
        } else {
            AgentSessionTodoSummaryRow(summary: fallbackSummary)
        }
    }
}

private struct ObservedAgentSessionTodoSummaryRow: View {
    @ObservedObject var runtime: AgentRuntime
    let fallbackSummary: AgentSessionTodoSummary

    var body: some View {
        AgentSessionTodoSummaryRow(
            summary: AgentSessionTodoSummaryLogic.summary(for: runtime.session) ?? fallbackSummary
        )
    }
}
