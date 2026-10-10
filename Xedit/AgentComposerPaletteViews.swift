//
//  AgentComposerPaletteViews.swift
//  WillDeep
//
//  Slash command palette, @ attachment picker, $ skill picker, composer chips, and
//  compact session mode badges used by the Agent composer/sidebar.
//

import SwiftUI
import AppKit

nonisolated enum ComposerPaletteLayout {
    static let maximumListHeight: CGFloat = 440
    static let maximumAtListHeight: CGFloat = 252

    static func atListHeight(entryCount: Int) -> CGFloat {
        min(CGFloat(max(entryCount, 1)) * 42, maximumAtListHeight)
    }
}

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
    /// Extra slash-less names that resolve to this command. The palette
    /// filters on `id`/`title` substrings, so a command whose canonical name
    /// carries punctuation the user does not type (`/no-subagent` vs the
    /// `/noagent` people actually reach for) is unreachable without this —
    /// the query matches nothing and the palette looks empty.
    let aliases: [String]
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
        aliases: [String] = [],
        action: @escaping (_ args: String) -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.argumentMode = argumentMode
        self.aliases = aliases
        self.action = action
    }

    /// Every name this command answers to, slash-stripped and lowercased.
    var matchableNames: [String] {
        ([id, String(title.dropFirst())] + aliases).map { $0.lowercased() }
    }

    /// True when `name` (already slash-stripped) is one of this command's
    /// exact names. Used by `invocation(in:commands:)`, which must not match
    /// on prefixes — ordinary prose starting with `/` has to fall through.
    func answersTo(exactName name: String) -> Bool {
        matchableNames.contains(name.lowercased())
    }

    /// Names people actually type for the delegation switches. `/no-subagent`
    /// is the canonical title, but the hyphen is exactly the character a user
    /// in a hurry drops — before these existed, typing `/noagent` filtered the
    /// palette down to nothing and the feature read as missing.
    static let noSubagentAliases = ["noagent", "no-agent", "nosubagent", "solo"]
    static let subagentAliases = ["delegate", "subagents"]

    static func builtIn(state: AppState) -> [SlashCommand] {
        let core: [SlashCommand] = [
            SlashCommand(id: "goal", title: "/goal", subtitle: L10n.ToolCard.goalCommandSubtitle,
                         symbol: "target") { args in
                // The composer consumes the command before invoking this
                // action. Goal only changes the mode; retain the draft for
                // the user to edit and send explicitly.
                state.agentInput = args
                state.setAgentInteractionMode(.goal)
            },
            SlashCommand(id: "no-sandbox", title: "/no-sandbox", subtitle: L10n.SessionSandbox.disable,
                         symbol: "shield.slash", argumentMode: .optional(placeholder: L10n.SessionSandbox.prompt)) { args in
                state.setLocalSandboxDisabled(true, text: args)
            },
            SlashCommand(id: "sandbox", title: "/sandbox", subtitle: L10n.SessionSandbox.enable,
                         symbol: "shield", argumentMode: .optional(placeholder: L10n.SessionSandbox.prompt)) { args in
                state.setLocalSandboxDisabled(false, text: args)
            },
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
        let collaboration: [SlashCommand] = [
            SlashCommand(id: "sessions", title: "/sessions", subtitle: L10n.SessionHandoff.sessionsCommandSubtitle,
                         symbol: "rectangle.stack.badge.person.crop", aliases: ["peers"]) { _ in
                state.askAgentAboutPeerSessions()
            },
            SlashCommand(id: "handoff", title: "/handoff", subtitle: L10n.SessionHandoff.commandSubtitle,
                         symbol: "arrow.up.forward.app",
                         argumentMode: .optional(placeholder: L10n.SessionHandoff.commandPlaceholder)) { args in
                state.handoffActiveSessionToCLI(instructions: args)
            },
        ]
        // 委派开关：正文照常作为普通用户消息发送，只是这一回合带上
        // 明确的 delegation policy。`/no-subagent` 是硬保证（工具表里
        // 直接摘掉 spawn_agent），`/subagent` 是强指令 + 事后审计 ——
        // 两者不对称的原因见 AgentDelegationPolicy 的文件头注释。
        let delegationCommands: [SlashCommand] = [
            SlashCommand(
                id: "subagent",
                title: "/subagent",
                subtitle: L10n.AgentDelegation.subagentCommandSubtitle,
                symbol: "person.2.badge.gearshape",
                argumentMode: .required(placeholder: L10n.AgentDelegation.subagentCommandPlaceholder),
                aliases: SlashCommand.subagentAliases
            ) { args in
                state.sendAgentMessage(withDelegationPolicy: .required, text: args)
            },
            SlashCommand(
                id: "no-subagent",
                title: "/no-subagent",
                subtitle: L10n.AgentDelegation.noSubagentCommandSubtitle,
                symbol: "person.2.slash",
                argumentMode: .required(placeholder: L10n.AgentDelegation.noSubagentCommandPlaceholder),
                aliases: SlashCommand.noSubagentAliases
            ) { args in
                state.sendAgentMessage(withDelegationPolicy: .forbidden, text: args)
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
        return core + collaboration + delegationCommands + [designToCode] + workflows
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
            c.matchableNames.contains { $0.contains(query) }
        }
    }

    /// 从 composer 当前 input 切出 args 部分（第一个空白之后的内容）。
    /// workflow 命令用，core 命令忽略。
    static func argsForCommand(_ rawInput: String) -> String {
        let trimmed = rawInput.trimmingCharacters(in: .whitespaces)
        guard let spaceIdx = trimmed.firstIndex(where: { $0.isWhitespace }) else { return "" }
        return String(trimmed[trimmed.index(after: spaceIdx)...])
            .trimmingCharacters(in: .whitespaces)
    }

    /// 斜杠词写在句尾时，正文是「去掉那个词剩下的部分」。
    ///
    /// `/no-subagent` 这类命令的参数就是正文（它的 action 拿 args 当用户
    /// 消息发出去），所以旧规则要求「斜杠开头 + 后面跟正文」。但用户实际
    /// 想写的是「把这批测试跑一遍 /no-subagent」——正文在前、标记在后。
    /// 那种写法下按第一个空格切 args 会把整句连标记一起当成正文，于是
    /// 发出去的消息里带着一个没被消费掉的 `/no-subagent`。
    ///
    /// 这里按位置摘掉那一个 token，其余原样保留（包括中间的换行与多余
    /// 空格之外的排版）。
    static func argsByRemovingTrailingCommand(_ rawInput: String, token: String) -> String {
        guard let range = rawInput.range(of: token, options: .backwards) else {
            return rawInput.trimmingCharacters(in: .whitespaces)
        }
        let head = rawInput[..<range.lowerBound]
        let tail = rawInput[range.upperBound...]
        return (String(head) + String(tail))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 光标所在的斜杠 token 是不是写在正文中间（而不是整条消息的开头）。
    static func hasLeadingSlash(_ rawInput: String) -> Bool {
        rawInput.trimmingCharacters(in: .whitespaces).hasPrefix("/")
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
        let bareName = String(commandName.dropFirst())
        guard let command = commands.first(where: { $0.answersTo(exactName: bareName) }) else { return nil }
        return (command, argsForCommand(rawInput))
    }

    /// Several commands written back to back at the start of a message:
    /// `/no-sandbox /subagent 修一下登录`. Returns nil unless at least two
    /// leading tokens are exact commands — a single command keeps the
    /// `invocation(in:commands:)` behaviour unchanged.
    ///
    /// The text after the chain belongs to ONE command, never to several:
    /// `/no-sandbox` and `/subagent` both send their args as a message, so
    /// handing the text to both would send it twice. The consumer is the
    /// last command that requires arguments, else the last one that accepts
    /// them; the others run first with empty args, in written order. When no
    /// command takes the text it is sent as an ordinary message afterwards.
    static func invocationChain(
        in rawInput: String,
        commands: [SlashCommand]
    ) -> SlashCommandChain? {
        var remainder = Substring(rawInput)
        var matched: [SlashCommand] = []
        while true {
            let trimmed = remainder.drop { $0.isWhitespace }
            guard trimmed.hasPrefix("/") else { break }
            let token = trimmed.prefix { !$0.isWhitespace }
            let bareName = String(token.dropFirst())
            guard let command = commands.first(where: { $0.answersTo(exactName: bareName) }) else { break }
            matched.append(command)
            remainder = trimmed.dropFirst(token.count)
        }
        guard matched.count >= 2 else { return nil }
        return chain(matched: matched, text: String(remainder))
    }

    /// 把「一串已认出的命令 + 剩下的正文」排成执行顺序。串写在开头和写在
    /// 句中两种形态共用，保证正文只交给一个命令。
    static func chain(matched: [SlashCommand], text rawText: String) -> SlashCommandChain {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let consumerIndex = matched.lastIndex(where: { $0.argumentMode.requiresArguments })
            ?? matched.lastIndex(where: { $0.argumentMode.acceptsArguments })
        var steps: [SlashCommandChain.Step] = []
        for (index, command) in matched.enumerated() where index != consumerIndex {
            steps.append(.init(command: command, args: ""))
        }
        if let consumerIndex {
            steps.append(.init(command: matched[consumerIndex], args: text))
        }
        return SlashCommandChain(
            steps: steps,
            trailingMessage: consumerIndex == nil && !text.isEmpty ? text : nil
        )
    }
}

/// Resolved form of several leading slash commands. `steps` are already in
/// execution order.
struct SlashCommandChain {
    struct Step {
        let command: SlashCommand
        let args: String
    }

    let steps: [Step]
    /// Text no command consumed; the composer sends it as a normal message
    /// after every step ran.
    let trailingMessage: String?

    /// A required-argument command left without text would only surface its
    /// missing-arguments error after the earlier commands already ran.
    var missingRequiredArguments: SlashCommand? {
        steps.first { $0.command.argumentMode.requiresArguments && $0.args.isEmpty }?.command
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                                SlashCommandRow(command: command, isSelected: index == selection)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onPick(index) }
                                    .id(command.id)
                            }
                        }
                    }
                    .frame(maxHeight: ComposerPaletteLayout.maximumListHeight)
                    .onCompatibleChange(of: selection) { _, newSelection in
                        guard commands.indices.contains(newSelection) else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(commands[newSelection].id, anchor: .center)
                        }
                    }
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
                            .foregroundStyle(AgentComposerChrome.iconPrimary)
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
    /// `@terminal` / `@browser`：发送时才取快照，这里只显示「附了哪个面板」。
    var panelStateMentions: [AgentPanelStateMention.PanelKind] = []
    let files: [AgentFileAttachment]
    let onRemoveWorkspace: () -> Void
    var onRemovePanelStateMention: (AgentPanelStateMention.PanelKind) -> Void = { _ in }
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
                ForEach(panelStateMentions, id: \.self) { kind in
                    chip(
                        symbol: kind == .terminal ? "terminal" : "globe",
                        label: "@\(kind.id)",
                        help: kind == .terminal
                            ? L10n.PanelMention.terminalPurpose
                            : L10n.PanelMention.browserPurpose,
                        onRemove: { onRemovePanelStateMention(kind) }
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
                .foregroundStyle(AgentComposerChrome.iconPrimary)
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

/// 引用菜单是从哪里打开的：输入框里打 `@`，还是点 `+` 按钮。两者共用同一份
/// 候选源，只在条目取舍与分组顺序上不同。
enum AtMenuSource { case mention, plusButton }

/// One row in the `@` popover. Project files and the special `workspace`
/// shortcut are unified so the user can fuzzy-match across attachable
/// context references without mixing them with `$` skills.
enum AtPickerEntry: Identifiable, Equatable {
    case workspace
    case file(url: URL, relativePath: String)
    /// 点名一个工种去干这一回合的活。候选取 `publicBuiltIn`——那份清单的
    /// 定义就是「给人看的工种」，专家/裁判之类的内部分档已经在那里收拢过了。
    case worker(id: String, name: String, purpose: String)
    /// 把侧边栏面板此刻的状态作为**事实**附给这一轮（终端连在哪台机器、
    /// 浏览器停在哪个页面）。只是告知，用不用由模型判断——它不改工具集、
    /// 不改路由、不碰审批。设计文档：docs/PANEL_STATE_MENTION_DESIGN.md
    case panelState(kind: AgentPanelStateMention.PanelKind, detail: String)
    /// 会话级设置的快捷入口。只在 `+` 菜单出现，`@` 里不出现——`@` 的语义是
    /// 「这一轮」，而设置作用于整个会话，混在一起会让人以为它也是一次性的。
    case sessionSetting(SessionSetting)

    enum SessionSetting: String, Equatable {
        case goalMode
    }

    /// 菜单分组。条目性质并不相同：附件与面板事实作用于**这一轮**，会话设置
    /// 作用于**整个会话**，平铺在一张列表里会误导。
    enum Group: Int, Comparable {
        case attachThisTurn
        case approachThisTurn
        case sessionSettings

        static func < (lhs: Group, rhs: Group) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .attachThisTurn: return L10n.ComposerMenuGroups.attach
            case .approachThisTurn: return L10n.ComposerMenuGroups.approach
            case .sessionSettings: return L10n.ComposerMenuGroups.session
            }
        }
    }

    /// 按组排好。`@` 的主用途是点名工种，工种组排在前；`+` 主要是附加东西
    /// 和改会话设置，工种组排到最后。组内保持原有顺序（Swift 的 sort 不稳定，
    /// 不能直接按组 sort）。
    static func grouped(_ entries: [AtPickerEntry], source: AtMenuSource) -> [AtPickerEntry] {
        let order: [Group] = source == .plusButton
            ? [.attachThisTurn, .sessionSettings, .approachThisTurn]
            : [.attachThisTurn, .approachThisTurn, .sessionSettings]
        return order.flatMap { group in entries.filter { $0.group == group } }
    }

    /// 会话设置候选。首版只有目标模式，已是目标模式时不重复出现。
    ///
    /// `@` 与 `+` 都给（1.392.0-rc1 起）。原先只给 `+`，理由是 `@` 的语义是
    /// 「这一轮」、设置作用于整个会话；但用户习惯在输入框里打 `@` 找目标模式，
    /// 找不到就以为功能没了。`@` 菜单里它排在最后一组、组标题写明「会话设置」，
    /// 足以和一次性的附加项区分开。
    ///
    /// 英文 id 与本地化名双路匹配，和 `@worker` 同一做法：打 `@goal` 或
    /// `@目标` 都能命中，不必先切输入法。
    static func sessionSettingEntries(
        matching query: String,
        localizedGoalTitle: String,
        currentMode: AgentInteractionMode
    ) -> [AtPickerEntry] {
        guard currentMode != .goal else { return [] }
        let q = query.lowercased()
        guard q.isEmpty
            || localizedGoalTitle.lowercased().contains(q)
            || "goal".contains(q) else { return [] }
        return [.sessionSetting(.goalMode)]
    }

    var group: Group {
        switch self {
        case .workspace, .file, .panelState: return .attachThisTurn
        case .worker: return .approachThisTurn
        case .sessionSetting: return .sessionSettings
        }
    }

    var id: String {
        switch self {
        case .workspace: return "@workspace"
        case .file(let url, _): return "file:\(url.standardizedFileURL.path)"
        case .worker(let id, _, _): return "worker:\(id)"
        case .panelState(let kind, _): return "panel:\(kind.id)"
        case .sessionSetting(let setting): return "setting:\(setting.rawValue)"
        }
    }

    var symbol: String {
        switch self {
        case .workspace: return "folder"
        case .file: return "doc.text"
        case .worker: return "person.badge.shield.checkmark"
        case .panelState(let kind, _):
            switch kind {
            case .terminal: return "terminal"
            case .browser: return "globe"
            }
        case .sessionSetting(let setting):
            switch setting {
            case .goalMode: return "target"
            }
        }
    }

    var title: String {
        switch self {
        case .workspace: return "workspace"
        case .file(_, let rel): return rel
        case .worker(let id, let name, _): return "\(name) · @\(id)"
        // 英文 id 一并显示：`@` 之后要打字筛选，没有它用户不知道能打什么
        // 才不用切输入法。
        case .panelState(let kind, _): return "\(kind.localizedDisplayName) · @\(kind.id)"
        case .sessionSetting(let setting):
            switch setting {
            case .goalMode: return L10n.InteractionMode.goal
            }
        }
    }

    var subtitle: String {
        switch self {
        case .workspace: return "Attach the current workspace root + file list"
        case .file(let url, _): return url.deletingLastPathComponent().lastPathComponent
        case .worker(_, _, let purpose): return purpose
        // 副标题直接摆事实本身（主机 / URL），用户选之前就看得见要附什么。
        case .panelState(_, let detail): return detail
        case .sessionSetting(let setting):
            switch setting {
            case .goalMode: return L10n.ComposerMenuGroups.goalModeSubtitle
            }
        }
    }

    /// `@` is primarily the Worker mention entry point. Keep the five public
    /// responsibilities visible before the longer workspace/file result set.
    static func workersFirst(
        _ contextEntries: [AtPickerEntry],
        workers: [AtPickerEntry]
    ) -> [AtPickerEntry] {
        workers + contextEntries
    }
}

/// 操作员点名的工种，显示在输入框上方。它是「这一回合派给谁」的唯一可见处，
/// 也是唯一的反悔入口——`@` 选中即写入，发送即消费。
struct AgentComposerPinnedWorkerChip: View {
    let profileID: String
    let onRemove: () -> Void

    private var profile: AgentSubagentProfile? {
        AgentSubagentProfileCatalog.builtIn.first { $0.id == profileID }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.badge.shield.checkmark")
                .font(.system(size: 11, weight: .medium))
            Text(L10n.AgentDelegation.pinnedWorkerChip(profile?.localizedDisplayName ?? profileID))
                .font(.system(size: 11.5))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.AgentDelegation.pinnedWorkerRemove)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(profile?.localizedPurpose ?? "")
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
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                // 组标题只在该组第一行之前插一次。刻意不改
                                // `entries` 的平铺结构——selection 与键盘导航
                                // 都按索引走，引入嵌套会把那套逻辑一起复杂化。
                                if index == 0 || entries[index - 1].group != entry.group {
                                    Text(entry.group.title)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 12)
                                        .padding(.top, index == 0 ? 2 : 8)
                                        .padding(.bottom, 2)
                                }
                                AtPickerRow(entry: entry, isSelected: index == selection)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onPick(index) }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(entry.id)
                            }
                        }
                    }
                    // A max-only frame lets the surrounding composer squeeze
                    // ScrollView down to roughly three rows. Give it a real
                    // content-derived height, capped at six 42pt rows, so the
                    // Worker list is visible without covering most of the chat.
                    .frame(height: ComposerPaletteLayout.atListHeight(entryCount: entries.count))
                    .onCompatibleChange(of: selection) { _, newSelection in
                        guard entries.indices.contains(newSelection) else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(entries[newSelection].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 6)
        .frame(width: 540, alignment: .leading)
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
    static let minimumVisibleRowCount = 5
    static let rowHeight: CGFloat = 38

    static func minimumListHeight(entryCount: Int) -> CGFloat {
        CGFloat(min(max(entryCount, 0), minimumVisibleRowCount)) * rowHeight
    }
}

struct SkillPickerMenu: View {
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
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                SkillPickerRow(entry: entry, isSelected: index == selection)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onPick(index) }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(entry.id)
                            }
                        }
                    }
                    .frame(
                        minHeight: SkillPickerLayout.minimumListHeight(entryCount: entries.count),
                        maxHeight: ComposerPaletteLayout.maximumListHeight
                    )
                    .onCompatibleChange(of: selection) { _, newSelection in
                        guard entries.indices.contains(newSelection) else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(entries[newSelection].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 6)
        .frame(width: 540, alignment: .leading)
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

/// One quiet, right-aligned progress summary for the session's active mode.
/// The current step remains available in the tooltip; keeping it out of a
/// second row preserves the sidebar's navigation rhythm. Only work that
/// needs attention receives an accent color.
struct AgentSessionModeBadges: View {
    let session: AgentSession
    var runtime: AgentRuntime? = nil
    var baseFontSize: CGFloat = AgentSettingsStore.chatBaseFontSizeDefault

    var body: some View {
        Group {
            if let runtime {
                ObservedAgentSessionModeBadges(
                    runtime: runtime,
                    baseFontSize: baseFontSize
                )
            } else {
                AgentSessionModeBadgeContent(
                    session: session,
                    baseFontSize: baseFontSize
                )
            }
        }
        // The sidebar reveals a fixed-width action cluster on row hover.
        // Keep mode badges at their intrinsic width so SwiftUI truncates the
        // session title instead of squeezing the SF Symbol and progress text.
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ObservedAgentSessionModeBadges: View {
    @ObservedObject var runtime: AgentRuntime
    let baseFontSize: CGFloat

    var body: some View {
        AgentSessionModeBadgeContent(
            session: runtime.session,
            baseFontSize: baseFontSize
        )
    }
}

private struct AgentSessionModeBadgeContent: View {
    let session: AgentSession
    let baseFontSize: CGFloat

    var body: some View {
        if let summary = AgentSessionTodoSummaryLogic.summary(for: session),
           summary.kind == .goal {
            badge(summary)
        }
    }

    private func badge(_ summary: AgentSessionTodoSummary) -> some View {
        // Plan mode no longer exists as a user-facing session mode, so a
        // legacy/transient currentPlan must not leave a checklist glyph in
        // conversation navigation. Goal remains a real mode and keeps its
        // quiet target badge, with progress available from the tooltip.
        Image(systemName: "target")
            .font(.system(size: max(11, baseFontSize), weight: .regular))
            .foregroundStyle(Color.primary.opacity(0.55))
            .help(summaryHelp(summary))
            .accessibilityLabel(Text(summaryHelp(summary)))
    }

    private func summaryHelp(_ summary: AgentSessionTodoSummary) -> String {
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
        if session.interactionMode == .goal,
           let goal = session.currentGoal,
           !goal.checklist.isEmpty {
            return goalSummary(goal)
        }
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
