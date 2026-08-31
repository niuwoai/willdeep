//
//  AgentSidePanel.swift
//  WillDeep
//
//  1.85.0-rc21：Agent 模式右侧的可切换辅助栏。AgentChatHeader
//  里的 Menu 选择哪类内容，这里负责把第三栏画出来。Background
//  tasks 复用现有 jobs registry；Diff 走 git diff HEAD；其余
//  Preview / Files / Plan 还在搭骨架，先画「Coming soon」占位。
//

import SwiftUI

/// One-shot intent from elsewhere in the UI (e.g. an inline file chip
/// click) to open a specific side panel and optionally point it at a
/// file. Carries a fresh `id` per request so observers can tell two
/// "show files for /foo.swift" calls apart even when the destination
/// happens to match.
struct AgentSidePanelOpenRequest: Equatable, Identifiable {
    let id: UUID
    let kind: AgentSidePanelKind
    let file: URL?
    let mediaTaskScope: AgentMediaTaskScope?
    /// When set (with `kind == .files`), the Files panel expands its tree down
    /// to this directory and selects it — used by a chat path reference that
    /// points at a folder inside the current workspace.
    let revealFolder: URL?

    init(
        kind: AgentSidePanelKind,
        file: URL? = nil,
        mediaTaskScope: AgentMediaTaskScope? = nil,
        revealFolder: URL? = nil,
        id: UUID = UUID()
    ) {
        self.kind = kind
        self.file = file
        self.mediaTaskScope = mediaTaskScope
        self.revealFolder = revealFolder
        self.id = id
    }
}

nonisolated enum AgentSidePanelKind: String, CaseIterable, Identifiable, Codable {
    case preview
    case diff
    case files
    case terminal
    case devServer
    case backgroundTasks
    case mediaTasks
    case shortDrama
    case embeddedBrowser
    case widget
    case imageEditor
    case plan

    var id: String { rawValue }

    /// Panels with live processes, embedded web content, or large editing
    /// canvases should not keep resources forever after their owning
    /// session has gone unviewed. Dev Server is intentionally excluded:
    /// those jobs are workspace-level resources because they occupy ports.
    var releasesResourcesWhenUnviewed: Bool {
        switch self {
        case .terminal, .embeddedBrowser, .widget, .imageEditor:
            return true
        case .preview, .diff, .files, .devServer, .backgroundTasks, .mediaTasks, .shortDrama, .plan:
            return false
        }
    }

    var requiredExpert: AgentExpert? {
        switch self {
        case .shortDrama:
            return .shortDrama
        case .devServer:
            return .webCoding
        default:
            // The embedded browser is deliberately NOT gated. Opening a LAN
            // address that came up in the chat is plain browsing, and making
            // the user activate Browser Ops first only hid the panel behind
            // a switch they had no reason to look for. The expert still
            // gates the browser *tools* (screenshot, click, fill, Chrome
            // tabs) — that is agent capability, which is a different thing
            // from the user opening a page.
            return nil
        }
    }

    func isAvailable(activeExperts: Set<AgentExpert>) -> Bool {
        guard let requiredExpert else { return true }
        return activeExperts.contains(requiredExpert)
    }

    var title: String {
        switch self {
        case .preview: return L10n.AgentSidePanel.preview
        case .diff: return L10n.AgentSidePanel.diff
        case .files: return L10n.AgentSidePanel.files
        case .terminal: return L10n.AgentSidePanel.terminal
        case .devServer: return "Dev Server"
        case .backgroundTasks: return L10n.AgentJobs.managerTitle
        case .mediaTasks: return "媒体任务"
        case .shortDrama: return "短剧"
        case .embeddedBrowser: return L10n.AgentSidePanel.embeddedBrowser
        case .widget: return "网页组件"
        case .imageEditor: return "图片编辑"
        case .plan: return L10n.AgentSidePanel.plan
        }
    }

    /// SF Symbol used in both menu items and panel header. Picked so
    /// the row is recognizable at a glance without depending on text.
    var systemImage: String {
        switch self {
        case .preview: return "play.rectangle"
        case .diff: return "rectangle.split.2x1.fill"
        case .files: return "folder"
        case .terminal: return "terminal"
        case .devServer: return "server.rack"
        // A clock wrapped by a progress arrow reads as ongoing/background
        // work at rail size. The previous meshing gears looked like Settings,
        // which made the task manager hard to recognize at a glance.
        case .backgroundTasks: return "clock.arrow.circlepath"
        case .mediaTasks: return "photo.stack"
        case .shortDrama: return "rectangle.stack.badge.play"
        case .embeddedBrowser: return "globe"
        case .widget: return "safari"
        case .imageEditor: return "paintbrush.pointed"
        case .plan: return "checklist"
        }
    }
}

/// 侧栏宿主与「分离窗口」（AgentDetachedPanelWindow）共用的面板内容
/// 分发。terminal 也在列 —— 侧栏宿主因常驻挂载策略在 ZStack 里单独
/// 处理 terminal，分离窗口则直接经由本视图挂载。
struct AgentSidePanelKindContent: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.agentPanelScope) private var inheritedPanelScope
    private var panelScope: AgentPanelScope {
        inheritedPanelScope ?? AgentPanelScope(appState: appState, runtime: appState.activeRuntime)
    }
    let kind: AgentSidePanelKind
    @Binding var kindSelection: AgentSidePanelKind?
    @Binding var selectedFile: URL?
    var layoutWidth: CGFloat

    var body: some View {
        switch kind {
        case .backgroundTasks:
            AgentBackgroundTasksPanel(width: layoutWidth)
        case .mediaTasks:
            AgentMediaTasksPanel(width: layoutWidth)
        case .devServer:
            AgentDevServerPanel(width: layoutWidth)
        case .shortDrama:
            AgentShortDramaPanel(store: appState.agentShortDramaStore, width: layoutWidth)
        case .embeddedBrowser:
            AgentEmbeddedBrowserPanel(
                runtimeID: panelScope.runtime?.id,
                width: layoutWidth
            )
        case .widget:
            AgentSidePanelWidgetView(width: layoutWidth)
        case .imageEditor:
            AgentImageEditPanel(width: layoutWidth)
        case .diff:
            AgentSidePanelDiffView()
        case .files:
            AgentSidePanelFilesView(selectedFile: $selectedFile, kind: $kindSelection)
        case .terminal:
            AgentSidePanelTerminalView()
        case .plan:
            AgentSidePanelPlanView()
        case .preview:
            AgentSidePanelPreviewView(selectedFile: $selectedFile)
        }
    }
}

struct AgentSidePanelHost: View {
    @EnvironmentObject var appState: AppState
    @Binding var kind: AgentSidePanelKind?
    @Binding var selectedFile: URL?
    var width: CGFloat = 480
    var contentWidth: CGFloat?
    var owner: AgentRuntime?

    var body: some View {
        Group {
            if let runtime = owner ?? appState.activeRuntime {
                AgentPanelWorkspaceView(runtime: runtime, onHide: { kind = nil })
                    .onAppear {
                        if let kind, runtime.sidePanelState.kind != kind || runtime.sidePanelState.selectedTab == nil {
                            appState.openPanelTab(kind, file: selectedFile, runtime: runtime)
                        }
                    }
                    .onCompatibleChange(of: kind) { _, newKind in
                        if let newKind, runtime.sidePanelState.selectedTab?.kind != newKind {
                            appState.openPanelTab(newKind, file: selectedFile, runtime: runtime)
                        }
                    }
            }
        }
        .frame(width: contentWidth ?? width)
        .frame(width: width, alignment: .trailing)
        .clipped()
        .focusable(false)
    }
}

/// The Agent remains useful without a project (chat, terminal, browser, and
/// preview), while Files and Diff require a filesystem root. Make that
/// boundary explicit and provide the shortest path instead of a dead end.
struct AgentSidePanelWorkspaceRequiredView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.agentPanelScope) private var inheritedPanelScope
    private var panelScope: AgentPanelScope {
        inheritedPanelScope ?? AgentPanelScope(appState: appState, runtime: appState.activeRuntime)
    }

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 22))
                .foregroundStyle(.secondary.opacity(0.6))
            Text(L10n.AgentSidePanel.noWorkspace)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(L10n.AgentSidePanel.noWorkspaceDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.AgentSidePanel.chooseWorkspace) {
                appState.openFolderAndStartAgentSession()
            }
            .controlSize(.small)
            .focusable(false)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

// MARK: - Widget panel

/// Memoizes the message-derived widget list across `body` evaluations —
/// same pattern as `AgentTranscriptMinimapCache`: the panel used to walk
/// every runtime message (`reversed().compactMap(\.widget)`) on each `body`
/// pass. Widgets ride in as freshly appended `.widget` messages, so
/// message count + last id is a sufficient identity for the walk's input.
///
/// Reference type parked in `@State` on purpose: recomputing during a
/// `body` evaluation must NOT invalidate the view.
final class AgentSidePanelWidgetCache {
    private var fingerprint: Int?
    private var cached: [AgentWidget] = []

    func widgets(
        fingerprint incoming: Int,
        rebuild: () -> [AgentWidget]
    ) -> [AgentWidget] {
        if incoming == fingerprint { return cached }
        let fresh = rebuild()
        fingerprint = incoming
        cached = fresh
        return fresh
    }
}

struct AgentSidePanelWidgetView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.agentPanelScope) private var inheritedPanelScope
    private var panelScope: AgentPanelScope {
        inheritedPanelScope ?? AgentPanelScope(appState: appState, runtime: appState.activeRuntime)
    }
    @ObservedObject private var widgetRegistry = AgentWidgetRegistry.shared
    @State private var selectedWidgetID: UUID?
    @State private var expandedHandoffWidgetIDs: Set<UUID> = []
    @State private var messageWidgetCache = AgentSidePanelWidgetCache()
    var width: CGFloat

    private var widgets: [AgentWidget] {
        let runtime = panelScope.runtime
        var hasher = Hasher()
        hasher.combine(runtime?.id)
        hasher.combine(runtime?.messages.count ?? 0)
        hasher.combine(runtime?.messages.last?.id)
        let messageWidgets = messageWidgetCache.widgets(fingerprint: hasher.finalize()) {
            runtime?.messages.reversed().compactMap(\.widget) ?? []
        }
        // The registry side stays live (it is the @ObservedObject that
        // triggers this body in the first place); only the full message
        // walk above is memoized. The merge itself is a handful of items.
        var seen: Set<UUID> = []
        var result: [AgentWidget] = []
        for widget in messageWidgets + widgetRegistry.widgets(forRuntime: runtime?.id) {
            guard !seen.contains(widget.id) else { continue }
            seen.insert(widget.id)
            result.append(widget)
        }
        return result
    }

    private var selectedWidget: AgentWidget? {
        if let selectedWidgetID,
           let selected = widgets.first(where: { $0.id == selectedWidgetID }) {
            return selected
        }
        return widgets.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let widget = selectedWidget {
                    widgetList
                    widgetHeader(widget)
                    AgentWidgetCardView(widget: widget)
                } else {
                    emptyState
                }
            }
            .padding(12)
        }
        .frame(width: width)
        .onAppear {
            selectedWidgetID = selectedWidget?.id
        }
        .onCompatibleChange(of: widgets.map(\.id)) { _, ids in
            guard let first = ids.first else {
                selectedWidgetID = nil
                return
            }
            if selectedWidgetID == nil || !ids.contains(selectedWidgetID!) {
                selectedWidgetID = first
            }
        }
    }

    private var widgetList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "safari")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("最近网页组件")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(widgets.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(widgets) { widget in
                        Button {
                            selectedWidgetID = widget.id
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(widget.title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text(widget.sourceSummary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(Self.dateFormatter.string(from: widget.createdAt))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .frame(width: 132, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(widget.id == selectedWidget?.id ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(widget.id == selectedWidget?.id ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .help("查看网页组件：\(widget.title)")
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func widgetHeader(_ widget: AgentWidget) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(widget.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if widget.handoffActions.isEmpty, widget.recommendedAction != nil {
                    Button {
                        appendWidgetActionListToChat(widget)
                    } label: {
                        Label("动作清单", systemImage: "list.bullet.clipboard")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("把当前网页组件的推荐动作发送到聊天")
                }
                Button {
                    appendWidgetContextToChat(widget)
                } label: {
                    Label("发送到聊天", systemImage: "text.bubble")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help("把当前网页组件上下文发送到聊天")
            }
            Text("\(max(1, widget.byteCount / 1024)) KB · \(Self.dateFormatter.string(from: widget.createdAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
            AgentWidgetSourceRows(widget: widget)
            if let action = widget.recommendedAction {
                widgetRecommendedActionRow(action, widget: widget)
            }
            if !widget.handoffActions.isEmpty {
                widgetHandoffActionRows(widget.handoffActions, widget: widget)
            }
        }
    }

    private func widgetRecommendedActionRow(_ action: AgentWidgetRecommendedAction, widget: AgentWidget) -> some View {
        let handoffAction = recommendedHandoffAction(action)
        let presentation = widgetHandoffActionPresentation(handoffAction)
        return Button {
            openWidgetMediaTaskScopeIfAvailable(handoffAction)
            openWidgetMediaTaskListIfAvailable(handoffAction)
            openWidgetRemoteTaskRefreshIfAvailable(handoffAction)
            openWidgetRemoteTaskInspectIfAvailable(handoffAction)
            openWidgetProductionPackagePreviewIfAvailable(handoffAction)
            openWidgetReviewPanelIfAvailable(handoffAction)
            openWidgetImageEditorIfAvailable(handoffAction)
            openShortDramaWidgetIfAvailable(handoffAction)
            openGenericImageChoiceWidgetIfAvailable(handoffAction)
            openWidgetHTMLIfAvailable(handoffAction)
            appendWidgetRecommendedActionToChat(action, widget: widget)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: presentation.systemImage)
                    .font(.caption2)
                Text(presentation.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                if presentation.isLocalDirect {
                    Text("直达")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                }
                Text(action.tool)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                Text(action.displayArguments)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.message")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(presentation.help)
    }

    private func recommendedHandoffAction(_ action: AgentWidgetRecommendedAction) -> AgentWidgetHandoffAction {
        AgentWidgetHandoffAction(
            key: "recommended_tool",
            label: "建议工具",
            tool: action.tool,
            arguments: action.arguments
        )
    }

    private func widgetHandoffActionRows(_ actions: [AgentWidgetHandoffAction], widget: AgentWidget) -> some View {
        let isExpanded = expandedHandoffWidgetIDs.contains(widget.id)
        let visibleActions = isExpanded ? actions : Array(actions.prefix(6))
        let hiddenCount = max(0, actions.count - visibleActions.count)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("可用动作")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(actions.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    appendWidgetActionListToChat(widget)
                } label: {
                    Label("发送清单", systemImage: "list.bullet.clipboard")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help("把这个网页组件的推荐动作和全部可用动作发送到聊天")
                if actions.count > 6 {
                    Button {
                        toggleWidgetHandoffExpansion(widget.id)
                    } label: {
                        Label(
                            isExpanded ? "收起" : "展开全部",
                            systemImage: isExpanded ? "chevron.up" : "chevron.down"
                        )
                        .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help(isExpanded ? "收起网页组件动作列表" : "显示这个网页组件的全部可用动作")
                }
            }
            ForEach(visibleActions) { action in
                widgetHandoffActionRow(action, widget: widget)
            }
            if hiddenCount > 0 {
                Text("还有 \(hiddenCount) 个动作，点击“展开全部”查看。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }
        }
    }

    private func toggleWidgetHandoffExpansion(_ widgetID: UUID) {
        if expandedHandoffWidgetIDs.contains(widgetID) {
            expandedHandoffWidgetIDs.remove(widgetID)
        } else {
            expandedHandoffWidgetIDs.insert(widgetID)
        }
    }

    private func widgetHandoffActionRow(_ action: AgentWidgetHandoffAction, widget: AgentWidget) -> some View {
        let presentation = widgetHandoffActionPresentation(action)
        return Button {
            openWidgetMediaTaskScopeIfAvailable(action)
            openWidgetMediaTaskListIfAvailable(action)
            openWidgetRemoteTaskRefreshIfAvailable(action)
            openWidgetRemoteTaskInspectIfAvailable(action)
            openWidgetProductionPackagePreviewIfAvailable(action)
            openWidgetReviewPanelIfAvailable(action)
            openWidgetImageEditorIfAvailable(action)
            openShortDramaWidgetIfAvailable(action)
            openGenericImageChoiceWidgetIfAvailable(action)
            openWidgetHTMLIfAvailable(action)
            appendWidgetHandoffActionToChat(action, widget: widget)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: presentation.systemImage)
                    .font(.caption2)
                Text(presentation.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                if presentation.isLocalDirect {
                    Text("直达")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                }
                Text(action.tool)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                Text(action.displayArguments)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.message")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(presentation.help)
    }

    private func widgetHandoffActionPresentation(_ action: AgentWidgetHandoffAction) -> (title: String, systemImage: String, help: String, isLocalDirect: Bool) {
        switch action.tool {
        case "short_drama_open_media_tasks":
            return ("打开媒体任务", "list.bullet.rectangle", "打开对应范围的媒体任务侧栏，并把动作发送到聊天", true)
        case "short_drama_refresh_media_tasks":
            return ("刷新媒体任务", "arrow.clockwise", "打开对应范围的媒体任务侧栏，立即刷新运行中任务，并把动作发送到聊天", true)
        case "open_image_editor", "short_drama_open_image_editor":
            return ("打开蒙版", "paintbrush.pointed", "打开右侧图片蒙版编辑面板，并把动作发送到聊天", true)
        case "short_drama_show_storyboard_widget":
            return ("打开分镜看板", "rectangle.stack", "本地生成短剧分镜看板，并把动作发送到聊天", true)
        case "short_drama_show_image_choice_widget":
            return ("打开候选图", "photo.on.rectangle.angled", "本地生成候选图选择器，并把动作发送到聊天", true)
        case "show_image_choice_widget":
            return ("打开候选图", "photo.on.rectangle.angled", "本地生成通用候选图选择器，并把动作发送到聊天", true)
        case "show_widget":
            return ("打开网页组件", "safari", "从 html_path 本地打开 Skill/Ruby 生成的网页组件，并把动作发送到聊天", true)
        case "short_drama_resolve_review_item":
            return ("关闭检查项", "checkmark.circle", "把关闭短剧检查项动作发送到聊天", false)
        case "short_drama_generate_batch_media":
            return ("批量生成", "sparkles", "把短剧批量生成动作发送到聊天", false)
        case "short_drama_generate_shot_media":
            return ("生成分镜媒体", "photo", "把分镜图片或视频生成动作发送到聊天", false)
        case "short_drama_generate_asset_media":
            return ("生成资产参考", "person.crop.rectangle", "把人物或场景参考图生成动作发送到聊天", false)
        case "short_drama_upscale_shot_artifact", "upscale_image":
            return ("放大图片", "arrow.up.left.and.arrow.down.right", "把图片放大动作发送到聊天", false)
        case "generate_video_from_image":
            return ("图生视频", "film", "把图生视频动作发送到聊天", false)
        case "edit_image_with_mask":
            return ("提交蒙版编辑", "paintbrush", "把蒙版编辑提交动作发送到聊天", false)
        case "short_drama_select_shot_artifact":
            return ("设为主图", "star.square", "把候选图设为分镜主图的动作发送到聊天", false)
        case "short_drama_attach_asset_reference_image":
            return ("设为参考图", "paperclip", "把候选图设为人物或场景参考图的动作发送到聊天", false)
        case "short_drama_import_review_csv":
            return ("打开短剧审片", "checklist", "打开短剧侧栏查看审片上下文，并把 CSV 回写动作发送到聊天", true)
        case "import_media_manifest":
            return ("预览制作包", "square.and.arrow.down", "先打开制作包网页预览，再把 manifest 导入动作发送到聊天", true)
        case "short_drama_retry_media_task", "short_drama_retry_failed_media_tasks":
            return ("重试失败任务", "arrow.clockwise.circle", "把媒体任务重试动作发送到聊天", false)
        case "list_media_tasks":
            return ("查看媒体任务", "list.bullet.rectangle", "打开媒体任务侧栏，并把查询动作发送到聊天", true)
        case "replicate_poll_prediction", "some_im_poll_media_task":
            return ("刷新远端任务", "arrow.clockwise", "打开媒体任务侧栏并刷新匹配任务，再把远端任务刷新动作发送到聊天", true)
        case "replicate_cancel_prediction", "some_im_cancel_media_task":
            return ("查看取消任务", "xmark.circle", "打开媒体任务侧栏核对任务，再把取消动作发送到聊天确认", true)
        default:
            return (action.label, "arrow.triangle.2.circlepath", "把网页组件动作发送到聊天", false)
        }
    }

    private func openWidgetMediaTaskScopeIfAvailable(_ action: AgentWidgetHandoffAction) {
        guard action.tool == "short_drama_open_media_tasks" || action.tool == "short_drama_refresh_media_tasks",
              let scope = mediaTaskScope(from: action.arguments) else {
            return
        }
        panelScope.mediaScope = scope
        panelScope.request = AgentSidePanelOpenRequest(kind: .mediaTasks, mediaTaskScope: scope)
        if action.tool == "short_drama_refresh_media_tasks" {
            refreshWidgetMediaTaskScope(scope)
        }
    }

    private func openWidgetMediaTaskListIfAvailable(_ action: AgentWidgetHandoffAction) {
        guard action.tool == "list_media_tasks" else { return }
        let scope = mediaTaskScope(from: action.arguments)
        panelScope.mediaScope = scope
        panelScope.request = AgentSidePanelOpenRequest(kind: .mediaTasks, mediaTaskScope: scope)
    }

    private func openWidgetRemoteTaskRefreshIfAvailable(_ action: AgentWidgetHandoffAction) {
        guard action.tool == "replicate_poll_prediction" || action.tool == "some_im_poll_media_task" else { return }
        let provider: AgentMediaTaskProvider = action.tool == "replicate_poll_prediction" ? .replicate : .someIM
        let fields = commaSeparatedFields(action.arguments)
        guard let task = widgetMediaTask(from: fields, provider: provider) else {
            panelScope.mediaScope = nil
            panelScope.request = AgentSidePanelOpenRequest(kind: .mediaTasks)
            return
        }
        let scope = widgetMediaTaskScope(for: task)
        panelScope.mediaScope = scope
        panelScope.request = AgentSidePanelOpenRequest(kind: .mediaTasks, mediaTaskScope: scope)
        Task {
            await appState.agentMediaTaskPoller.refreshNow(
                taskID: task.id,
                registry: appState.agentMediaTaskRegistry
            )
        }
    }

    private func openWidgetRemoteTaskInspectIfAvailable(_ action: AgentWidgetHandoffAction) {
        guard action.tool == "replicate_cancel_prediction" || action.tool == "some_im_cancel_media_task" else { return }
        let provider: AgentMediaTaskProvider = action.tool == "replicate_cancel_prediction" ? .replicate : .someIM
        let fields = commaSeparatedFields(action.arguments)
        guard let task = widgetMediaTask(from: fields, provider: provider) else {
            panelScope.mediaScope = nil
            panelScope.request = AgentSidePanelOpenRequest(kind: .mediaTasks)
            return
        }
        let scope = widgetMediaTaskScope(for: task)
        panelScope.mediaScope = scope
        panelScope.request = AgentSidePanelOpenRequest(kind: .mediaTasks, mediaTaskScope: scope)
    }

    private func openWidgetProductionPackagePreviewIfAvailable(_ action: AgentWidgetHandoffAction) {
        guard action.tool == "import_media_manifest" else { return }
        let fields = commaSeparatedFields(action.arguments)
        if let previewPath = fields["widget_preview_path"], openWidgetPreview(path: previewPath, action: action, packageDirectory: fields["package_directory"]) {
            return
        }
        if let packageDirectory = fields["package_directory"],
           openWidgetPreview(packageDirectory: packageDirectory, action: action) {
            return
        }
        if let manifestPath = fields["manifest_path"] {
            let manifestPath = AgentWidgetPathResolver.normalize(manifestPath)
            let packageDirectory = (manifestPath as NSString).isAbsolutePath
                ? URL(fileURLWithPath: manifestPath).standardizedFileURL.deletingLastPathComponent().path
                : (manifestPath as NSString).deletingLastPathComponent
            _ = openWidgetPreview(packageDirectory: packageDirectory, action: action)
        }
    }

    private func openWidgetReviewPanelIfAvailable(_ action: AgentWidgetHandoffAction) {
        guard action.tool == "short_drama_import_review_csv" else { return }
        let fields = commaSeparatedFields(action.arguments)
        if let projectID = uuidField("project_id", in: fields) {
            appState.agentShortDramaStore.setActiveProject(id: projectID)
        }
        panelScope.request = AgentSidePanelOpenRequest(kind: .shortDrama)
    }

    private func openWidgetPreview(packageDirectory: String, action: AgentWidgetHandoffAction) -> Bool {
        let packagePath = AgentWidgetPathResolver.normalize(packageDirectory)
        let previewPath: String
        if (packagePath as NSString).isAbsolutePath {
            previewPath = URL(fileURLWithPath: packagePath)
                .appendingPathComponent("widget-preview.html", isDirectory: false)
                .standardizedFileURL
                .path
        } else {
            previewPath = (packagePath as NSString).appendingPathComponent("widget-preview.html")
        }
        return openWidgetPreview(path: previewPath, action: action, packageDirectory: packagePath)
    }

    private func openWidgetPreview(path: String, action: AgentWidgetHandoffAction, packageDirectory: String?) -> Bool {
        let previewPath = AgentWidgetPathResolver.normalize(path)
        guard let url = resolvedWidgetHTMLURL(previewPath) else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        var arguments = "title=短剧制作预览, html_path=\(previewPath), source_label=widget-side-panel, source_path=\(previewPath), recommended_tool=import_media_manifest, recommended_arguments=\(action.displayArguments)"
        if let packageDirectory, !packageDirectory.isEmpty {
            arguments += ", package_directory=\(AgentWidgetPathResolver.normalize(packageDirectory))"
        }
        let previewAction = AgentWidgetHandoffAction(
            key: "import_media_manifest_widget_preview",
            label: "制作包预览",
            tool: "show_widget",
            arguments: arguments
        )
        openWidgetHTMLIfAvailable(previewAction)
        return true
    }

    private func refreshWidgetMediaTaskScope(_ scope: AgentMediaTaskScope) {
        let taskIDs = appState.agentMediaTaskRegistry.tasks(forRuntime: panelScope.runtime?.id)
            .filter { task in
                scope.matches(task)
                    && task.isActive
                    && (
                        task.provider == .replicate
                            || task.provider == .someIM
                            || AgentGenericMediaStatusClient.canPoll(task)
                    )
            }
            .map(\.id)
        guard !taskIDs.isEmpty else { return }
        Task {
            for taskID in taskIDs {
                await appState.agentMediaTaskPoller.refreshNow(
                    taskID: taskID,
                    registry: appState.agentMediaTaskRegistry
                )
            }
        }
    }

    private func mediaTaskScope(from arguments: String?) -> AgentMediaTaskScope? {
        let fields = commaSeparatedFields(arguments)
        let scopeKind = fields["scope"] ?? (fields["project_id"] == nil ? "all" : "project")
        switch scopeKind {
        case "all":
            return AgentMediaTaskScope(label: "全部媒体任务")
        case "review_item":
            guard let projectID = fields["project_id"],
                  let reviewItemID = fields["review_item_id"] else {
                return nil
            }
            return AgentMediaTaskScope(
                label: "检查项媒体任务",
                projectID: projectID,
                episodeID: fields["episode_id"],
                shotID: fields["shot_id"],
                reviewItemID: reviewItemID
            )
        case "asset":
            guard let projectID = fields["project_id"],
                  let assetKind = fields["asset_kind"],
                  let assetID = fields["asset_id"] else {
                return nil
            }
            return AgentMediaTaskScope(
                label: "资产媒体任务",
                projectID: projectID,
                assetKind: assetKind,
                assetID: assetID
            )
        case "shot":
            guard let projectID = fields["project_id"],
                  let episodeID = fields["episode_id"],
                  let shotID = fields["shot_id"] else {
                return nil
            }
            return AgentMediaTaskScope(
                label: "分镜媒体任务",
                projectID: projectID,
                episodeID: episodeID,
                shotID: shotID
            )
        case "episode":
            guard let projectID = fields["project_id"],
                  let episodeID = fields["episode_id"] else {
                return nil
            }
            return AgentMediaTaskScope(label: "分集媒体任务", projectID: projectID, episodeID: episodeID)
        default:
            guard let projectID = fields["project_id"] else { return nil }
            return AgentMediaTaskScope(label: "项目媒体任务", projectID: projectID)
        }
    }

    private func commaSeparatedFields(_ arguments: String?) -> [String: String] {
        let raw = arguments?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, raw != "无额外参数" else { return [:] }
        var fields: [String: String] = [:]
        var activeArgumentKey: String?
        for part in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: "=") ?? trimmed.firstIndex(of: ":") else {
                appendWidgetArgumentFragment(trimmed, to: activeArgumentKey, fields: &fields)
                continue
            }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else {
                appendWidgetArgumentFragment(trimmed, to: activeArgumentKey, fields: &fields)
                continue
            }
            if let activeArgumentKey, !isWidgetHandoffTopLevelKey(key) {
                appendWidgetArgumentFragment(trimmed, to: activeArgumentKey, fields: &fields)
                continue
            }
            fields[key] = value
            activeArgumentKey = key.hasSuffix("_arguments") ? key : nil
        }
        return fields
    }

    private func appendWidgetArgumentFragment(_ fragment: String, to key: String?, fields: inout [String: String]) {
        guard let key, !fragment.isEmpty else { return }
        if let existing = fields[key], !existing.isEmpty {
            fields[key] = "\(existing), \(fragment)"
        } else {
            fields[key] = fragment
        }
    }

    private func isWidgetHandoffTopLevelKey(_ key: String) -> Bool {
        switch key {
        case "title",
             "html_path",
             "source_label",
             "source_path",
             "package_directory",
             "widget_preview_path",
             "widget_context",
             "recommended_tool",
             "recommended_arguments",
             "image_paths",
             "candidate_image_paths",
             "image_path",
             "artifact_path",
             "mask_path",
             "operation",
             "project_id",
             "episode_id",
             "shot_id",
             "asset_kind",
             "asset_id",
             "review_item_id",
             "scope",
             "task_id",
             "media_task_id",
             "prediction_id",
             "remote_task_id",
             "status_url",
             "cancel_url":
            return true
        default:
            return false
        }
    }

    private func widgetMediaTask(from fields: [String: String], provider: AgentMediaTaskProvider) -> AgentMediaTask? {
        let runtimeID = panelScope.runtime?.id
        for key in ["task_id", "media_task_id"] {
            if let handle = fields[key],
               let task = appState.agentMediaTaskRegistry.task(matchingHandle: handle, runtimeID: runtimeID) {
                return task
            }
        }
        let remoteValues = ["prediction_id", "remote_task_id", "status_url", "cancel_url"]
            .compactMap { fields[$0].map(cleanWidgetLookupValue) }
            .filter { !$0.isEmpty }
        guard !remoteValues.isEmpty else { return nil }
        return appState.agentMediaTaskRegistry.tasks(forRuntime: runtimeID).first { task in
            guard task.provider == provider else { return false }
            let taskValues = [
                task.remoteTaskID,
                task.statusURL,
                task.cancelURL
            ].compactMap { $0.map(cleanWidgetLookupValue) }
            return remoteValues.contains(where: { value in
                taskValues.contains(value)
            })
        }
    }

    private func widgetMediaTaskScope(for task: AgentMediaTask) -> AgentMediaTaskScope? {
        if let projectID = task.projectID ?? task.projectPath, let reviewItemID = task.reviewItemID {
            return AgentMediaTaskScope(
                label: "检查项媒体任务",
                projectID: projectID,
                episodeID: task.episodeID,
                shotID: task.shotID,
                reviewItemID: reviewItemID
            )
        }
        if let projectID = task.projectID ?? task.projectPath, let assetKind = task.assetKind, let assetID = task.assetID {
            return AgentMediaTaskScope(label: "资产媒体任务", projectID: projectID, assetKind: assetKind, assetID: assetID)
        }
        if let projectID = task.projectID ?? task.projectPath, let episodeID = task.episodeID, let shotID = task.shotID {
            return AgentMediaTaskScope(label: "分镜媒体任务", projectID: projectID, episodeID: episodeID, shotID: shotID)
        }
        if let projectID = task.projectID ?? task.projectPath, let episodeID = task.episodeID {
            return AgentMediaTaskScope(label: "分集媒体任务", projectID: projectID, episodeID: episodeID)
        }
        if let projectID = task.projectID ?? task.projectPath {
            return AgentMediaTaskScope(label: "项目媒体任务", projectID: projectID)
        }
        return nil
    }

    private func openWidgetImageEditorIfAvailable(_ action: AgentWidgetHandoffAction) {
        guard action.tool == "open_image_editor" || action.tool == "short_drama_open_image_editor" else { return }
        let fields = commaSeparatedFields(action.arguments)
        guard let imagePath = fields["image_path"] ?? fields["artifact_path"] else { return }
        panelScope.imageOperation = fields["operation"] == "erase" ? .erase : .inpaint
        panelScope.imageContext = AgentImageEditorContext(
            projectID: fields["project_id"],
            episodeID: fields["episode_id"],
            shotID: fields["shot_id"],
            assetKind: fields["asset_kind"],
            assetID: fields["asset_id"],
            reviewItemID: fields["review_item_id"]
        )
        panelScope.maskURL = fields["mask_path"].map { URL(fileURLWithPath: $0) }
        panelScope.imageURL = URL(fileURLWithPath: imagePath)
        panelScope.request = AgentSidePanelOpenRequest(kind: .imageEditor)
    }

    private func openShortDramaWidgetIfAvailable(_ action: AgentWidgetHandoffAction) {
        guard action.tool == "short_drama_show_storyboard_widget" || action.tool == "short_drama_show_image_choice_widget",
              let runtimeID = panelScope.runtime?.id else {
            return
        }
        let fields = commaSeparatedFields(action.arguments)
        guard let projectID = uuidField("project_id", in: fields),
              let project = appState.agentShortDramaStore.project(id: projectID) else {
            return
        }
        let mediaTasks = appState.agentMediaTaskRegistry.tasks(forRuntime: runtimeID)
        let widget: AgentWidget?
        if action.tool == "short_drama_show_image_choice_widget" {
            guard let episodeID = uuidField("episode_id", in: fields),
                  let shotID = uuidField("shot_id", in: fields),
                  let episode = project.episodes.first(where: { $0.id == episodeID }),
                  let shot = episode.shots.first(where: { $0.id == shotID }) else {
                return
            }
            widget = AgentShortDramaStoryboardWidgetBuilder.imageChoiceWidget(
                project: project,
                episode: episode,
                shot: shot,
                reviewItemID: fields["review_item_id"]
            )
        } else if let episodeID = uuidField("episode_id", in: fields),
                  let episode = project.episodes.first(where: { $0.id == episodeID }) {
            widget = AgentShortDramaStoryboardWidgetBuilder.widget(for: project, episode: episode, mediaTasks: mediaTasks)
        } else {
            widget = AgentShortDramaStoryboardWidgetBuilder.widget(for: project, mediaTasks: mediaTasks)
        }
        guard let widget else { return }
        AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
        panelScope.request = AgentSidePanelOpenRequest(kind: .widget)
    }

    private func openGenericImageChoiceWidgetIfAvailable(_ action: AgentWidgetHandoffAction) {
        guard action.tool == "show_image_choice_widget",
              let runtimeID = panelScope.runtime?.id else {
            return
        }
        let fields = commaSeparatedFields(action.arguments)
        let imagePaths = widgetImageChoicePaths(from: fields)
        guard !imagePaths.isEmpty else { return }
        let anchor = AgentImageChoiceWidgetBuilder.AnchorContext(
            projectID: fields["project_id"],
            episodeID: fields["episode_id"],
            shotID: fields["shot_id"],
            assetKind: fields["asset_kind"],
            assetID: fields["asset_id"],
            reviewItemID: fields["review_item_id"]
        )
        let widget = AgentImageChoiceWidgetBuilder.widget(
            title: fields["title"] ?? "图片候选选择",
            note: fields["note"],
            imagePaths: imagePaths,
            anchor: anchor,
            contextLines: widgetImageChoiceContextLines(action: action, fields: fields, imageCount: imagePaths.count)
        )
        AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
        panelScope.request = AgentSidePanelOpenRequest(kind: .widget)
    }

    private func widgetImageChoicePaths(from fields: [String: String]) -> [String] {
        let raw = fields["image_paths"] ?? fields["candidate_image_paths"] ?? fields["image_path"] ?? ""
        let separator: Character = raw.contains("|") ? "|" : ";"
        return raw
            .split(separator: separator, omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func widgetImageChoiceContextLines(
        action: AgentWidgetHandoffAction,
        fields: [String: String],
        imageCount: Int
    ) -> [String] {
        var lines = [
            "<widget-handoff-image-choice>",
            "action: show_image_choice_widget_from_widget_panel",
            "source_tool: \(action.tool)",
            "image_count: \(imageCount)"
        ]
        if let arguments = action.arguments?.trimmingCharacters(in: .whitespacesAndNewlines), !arguments.isEmpty {
            lines.append("source_arguments: \(arguments)")
        }
        for key in [
            "source_label",
            "source_path",
            "package_directory",
            "widget_context",
            "recommended_tool",
            "recommended_arguments",
            "project_id",
            "episode_id",
            "shot_id",
            "asset_kind",
            "asset_id",
            "review_item_id"
        ] {
            if let value = fields[key], !value.isEmpty {
                lines.append("\(key): \(value)")
            }
        }
        lines.append("</widget-handoff-image-choice>")
        return lines
    }

    private func openWidgetHTMLIfAvailable(_ action: AgentWidgetHandoffAction) {
        guard action.tool == "show_widget",
              let runtimeID = panelScope.runtime?.id else {
            return
        }
        let fields = commaSeparatedFields(action.arguments)
        guard let rawPath = fields["html_path"],
              let url = resolvedWidgetHTMLURL(rawPath) else {
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              ["html", "htm", "svg"].contains(url.pathExtension.lowercased()),
              let data = try? Data(contentsOf: url),
              data.count <= 1_048_576,
              let html = String(data: data, encoding: .utf8),
              !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let widget = AgentWidget(
            title: fields["title"] ?? url.deletingPathExtension().lastPathComponent,
            html: html,
            contextLines: widgetHTMLContextLines(action: action, fields: fields, url: url),
            sourceBaseURL: url.deletingLastPathComponent()
        )
        AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
        panelScope.request = AgentSidePanelOpenRequest(kind: .widget)
    }

    private func resolvedWidgetHTMLURL(_ rawPath: String) -> URL? {
        AgentWidgetPathResolver.resolve(rawPath, workspaceRoot: resolvedWorkspaceRoot())
    }

    private func widgetHTMLContextLines(
        action: AgentWidgetHandoffAction,
        fields: [String: String],
        url: URL
    ) -> [String] {
        var lines = [
            "<widget-handoff-show-widget>",
            "action: show_widget_from_widget_panel",
            "source_tool: \(action.tool)",
            "html_path: \(url.path)"
        ]
        if let arguments = action.arguments?.trimmingCharacters(in: .whitespacesAndNewlines), !arguments.isEmpty {
            lines.append("source_arguments: \(arguments)")
        }
        for key in [
            "source_label",
            "source_path",
            "package_directory",
            "widget_preview_path",
            "widget_context",
            "recommended_tool",
            "recommended_arguments",
            "project_id",
            "episode_id",
            "shot_id",
            "asset_kind",
            "asset_id",
            "review_item_id"
        ] {
            if let value = fields[key], !value.isEmpty {
                lines.append("\(key): \(value)")
            }
        }
        lines.append("</widget-handoff-show-widget>")
        return lines
    }

    private func cleanWidgetLookupValue(_ rawValue: String) -> String {
        AgentWidgetPathResolver.normalize(rawValue)
    }

    private func resolvedWorkspaceRoot() -> URL? {
        if let path = panelScope.runtime?.workspaceRootPath, !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return panelScope.workspaceRoot
    }

    private func uuidField(_ key: String, in fields: [String: String]) -> UUID? {
        fields[key].flatMap(UUID.init(uuidString:))
    }

    private func recordWidgetSidePanelToolAction(
        _ action: AgentWidgetHandoffAction,
        widget: AgentWidget,
        source: String
    ) {
        let note = [
            "source: \(source)",
            "side_panel_action_label: \(action.label)",
            "side_panel_action_hint: clicking this row already opened any safe local preview; still inspect arguments and preserve dry-run or user-confirmation requirements before executing provider or mutating tools."
        ].joined(separator: "\n")
        panelScope.runtime?.latestWidgetToolAction = AgentWidgetToolAction(
            widgetID: widget.id,
            widgetTitle: widget.title,
            actionKey: action.key,
            tool: action.tool,
            arguments: action.arguments,
            note: note,
            widgetContext: widget.contextBlock
        )
    }

    private func appendWidgetContextToChat(_ widget: AgentWidget) {
        let prompt = """
        请基于当前网页组件继续协作。

        <widget-panel-context>
        action: inspect_widget_from_side_panel
        widget_id: \(widget.id.uuidString)
        widget_title: \(widget.title)
        byte_count: \(widget.byteCount)
        created_at: \(Self.isoFormatter.string(from: widget.createdAt))
        source: widget_side_panel
        \(widget.contextBlock)
        follow_up: 如果这个 widget 内有 sendPrompt 按钮，按钮消息会附带 <widget-action> 来源上下文；如果需要继续操作，请结合当前聊天、媒体任务侧栏和网页组件内容给出下一步工具调用。
        </widget-panel-context>
        """
        let trimmedInput = panelScope.input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            panelScope.input = prompt
        } else if !panelScope.input.contains(widget.id.uuidString) {
            panelScope.input += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
    }

    private func appendWidgetHandoffActionToChat(_ action: AgentWidgetHandoffAction, widget: AgentWidget) {
        recordWidgetSidePanelToolAction(action, widget: widget, source: "widget_side_panel_handoff_action")
        let prompt = """
        请根据当前网页组件的可用动作继续操作。先检查参数是否需要 dry-run 或用户确认，再调用对应工具。

        <widget-handoff-action>
        action: run_widget_handoff_tool
        widget_id: \(widget.id.uuidString)
        widget_title: \(widget.title)
        handoff_key: \(action.key)
        handoff_tool: \(action.tool)
        handoff_arguments: \(action.displayArguments)
        source: widget_side_panel_handoff_action
        \(widget.contextBlock)
        </widget-handoff-action>
        """
        let trimmedInput = panelScope.input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            panelScope.input = prompt
        } else if !panelScope.input.contains("<widget-handoff-action>") || !panelScope.input.contains(action.key) || !panelScope.input.contains(widget.id.uuidString) {
            panelScope.input += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
    }

    private func appendWidgetActionListToChat(_ widget: AgentWidget) {
        var lines = [
            "请基于当前网页组件的动作清单继续协作。先判断哪些动作需要 dry-run 或用户确认，再选择合适工具执行。",
            "",
            "<widget-action-list>",
            "action: inspect_widget_action_list",
            "widget_id: \(widget.id.uuidString)",
            "widget_title: \(widget.title)",
            "handoff_action_count: \(widget.handoffActions.count)",
            "source: widget_side_panel_action_list"
        ]
        if let recommendedAction = widget.recommendedAction {
            let handoffAction = recommendedHandoffAction(recommendedAction)
            let presentation = widgetHandoffActionPresentation(handoffAction)
            lines.append("recommended_tool: \(recommendedAction.tool)")
            lines.append("recommended_arguments: \(recommendedAction.displayArguments)")
            lines.append("recommended_title: \(presentation.title)")
            lines.append("recommended_local_direct: \(presentation.isLocalDirect)")
            lines.append("recommended_help: \(presentation.help)")
        }
        if !widget.handoffActions.isEmpty {
            lines.append("handoff_actions:")
            for action in widget.handoffActions {
                let presentation = widgetHandoffActionPresentation(action)
                lines.append("- key=\(action.key) · label=\(action.label) · title=\(presentation.title) · local_direct=\(presentation.isLocalDirect) · tool=\(action.tool) · arguments=\(action.displayArguments) · help=\(presentation.help)")
            }
        }
        lines.append(widget.contextBlock)
        lines.append("</widget-action-list>")
        appendWidgetPromptToChat(lines.joined(separator: "\n"), duplicateGuard: "<widget-action-list>", widgetID: widget.id.uuidString)
    }

    private func appendWidgetRecommendedActionToChat(_ action: AgentWidgetRecommendedAction, widget: AgentWidget) {
        recordWidgetSidePanelToolAction(
            recommendedHandoffAction(action),
            widget: widget,
            source: "widget_side_panel_recommended_action"
        )
        let prompt = """
        请根据当前网页组件的推荐动作继续操作。先检查参数是否需要 dry-run 或用户确认，再调用对应工具。

        <widget-recommended-action>
        action: run_widget_recommended_tool
        widget_id: \(widget.id.uuidString)
        widget_title: \(widget.title)
        recommended_tool: \(action.tool)
        recommended_arguments: \(action.displayArguments)
        source: widget_side_panel_recommended_action
        \(widget.contextBlock)
        </widget-recommended-action>
        """
        let trimmedInput = panelScope.input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            panelScope.input = prompt
        } else if !panelScope.input.contains("<widget-recommended-action>") || !panelScope.input.contains(widget.id.uuidString) {
            panelScope.input += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
    }

    private func appendWidgetPromptToChat(_ prompt: String, duplicateGuard: String, widgetID: String) {
        let trimmedInput = panelScope.input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            panelScope.input = prompt
        } else if !panelScope.input.contains(duplicateGuard) || !panelScope.input.contains(widgetID) {
            panelScope.input += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "safari")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("还没有网页组件")
                .font(.system(size: 13, weight: .semibold))
            Text("Agent 或 Skill 调用 show_widget 后，最近生成的 HTML/SVG 组件会显示在这里。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

// MARK: - Files panel
//
// Reuses the editor's `FileTreeView` rooted at the active agent
// session's workspace path. Selection is kept local to the panel so
// clicking around here doesn't disturb the editor sidebar's own
// selection. Tree is rebuilt when the active session flips.

struct AgentSidePanelFilesView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.agentPanelScope) private var inheritedPanelScope
    private var panelScope: AgentPanelScope {
        inheritedPanelScope ?? AgentPanelScope(appState: appState, runtime: appState.activeRuntime)
    }
    @Environment(\.openWindow) private var openWindow
    @Binding var selectedFile: URL?
    @Binding var kind: AgentSidePanelKind?
    @State private var root: FileSystemNode?
    @State private var rootPath: String?
    @State private var selectedFolderURL: URL?

    var body: some View {
        Group {
            if let root {
                FileTreeView(
                    root: root,
                    selectedURL: $selectedFile,
                    selectedFolderURL: $selectedFolderURL,
                    onOpenFile: openFileInEditor,
                    onDoubleClickFile: { appState.revealInFinder($0) }
                )
            } else {
                placeholderNoWorkspace
            }
        }
        .onAppear {
            rebuildIfNeeded()
            if let target = panelScope.request?.revealFolder {
                revealFolder(target)
            }
        }
        .onCompatibleChange(of: panelScope.sessionID) { _, _ in rebuildIfNeeded() }
        .onCompatibleChange(of: panelScope.request) { _, request in
            guard let request, request.kind == .files, let target = request.revealFolder else { return }
            revealFolder(target)
        }
        .onCompatibleChange(of: selectedFile) { _, newValue in
            // 用户点的若是 markdown / html,顺手把面板切到 Preview,
            // 看效果不用再切菜单。其它文件类型保持在 Files 内,
            // 避免误切到 Preview 又显示「unsupported」。
            guard let url = newValue,
                  PreviewPaneCompatibility.supports(Language.fromURL(url)) else { return }
            kind = .preview
        }
    }

    private var placeholderNoWorkspace: some View {
        AgentSidePanelWorkspaceRequiredView()
    }

    private func rebuildIfNeeded() {
        let resolved: URL? = {
            if let path = panelScope.runtime?.workspaceRootPath, !path.isEmpty {
                return URL(fileURLWithPath: path).standardizedFileURL
            }
            return panelScope.workspaceRoot
        }()
        let newPath = resolved?.path
        if newPath == rootPath { return }
        rootPath = newPath
        root = resolved.map { FileSystemNode(url: $0) }
    }

    /// Expand the tree down to `target` and select it. Driven by a chat path
    /// reference that resolved to a folder inside this workspace.
    private func revealFolder(_ target: URL) {
        rebuildIfNeeded()
        guard let node = root?.expandToDescendant(target) else { return }
        selectedFolderURL = node.url
    }

    private func openFileInEditor(_ url: URL) {
        if AppState.isBinaryFile(at: url) {
            appState.revealInFinder(url)
            return
        }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Plan panel
//
// Surfaces the current `AgentPlan` of the active runtime as a wrapping,
// selectable Markdown document. The floating card is intentionally compact;
// this panel is where every step can be read without truncation.

struct AgentSidePanelPlanView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.agentPanelScope) private var inheritedPanelScope
    private var panelScope: AgentPanelScope {
        inheritedPanelScope ?? AgentPanelScope(appState: appState, runtime: appState.activeRuntime)
    }

    var body: some View {
        Group {
            if let plan = panelScope.runtime?.currentPlan {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(
                            Array(MarkdownPreviewParser.blocks(
                                from: AgentPlanMarkdownFormatter.markdown(from: plan)
                            ).enumerated()),
                            id: \.offset
                        ) { _, block in
                            MarkdownPreviewBlockView(block: block)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            } else {
                placeholderNoPlan
            }
        }
    }

    private var placeholderNoPlan: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "checklist")
                .font(.system(size: 22))
                .foregroundStyle(.secondary.opacity(0.6))
            Text(L10n.AgentSidePanel.planMissing)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

// MARK: - Preview panel
//
// Renders a markdown / HTML preview of a workspace file using the
// editor's `MarkdownPreviewParser` + `MarkdownPreviewBlockView` so the
// look matches the existing preview pane. Default file is the
// workspace README (any of `README.md` / `README` / `readme.md` cases);
// user can pick another via NSOpenPanel.

struct AgentSidePanelPreviewView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.agentPanelScope) private var inheritedPanelScope
    private var panelScope: AgentPanelScope {
        inheritedPanelScope ?? AgentPanelScope(appState: appState, runtime: appState.activeRuntime)
    }
    @Binding var selectedFile: URL?
    @State private var loadedURL: URL?
    @State private var content: String = ""
    @State private var language: Language?
    @State private var previewBlocks: [MarkdownPreviewBlock] = []
    @State private var loadError: String?

    private var previewTypography: MarkdownPreviewTypography {
        .agentAppearance(
            fontID: appState.agentChatFontID,
            baseFontSize: appState.agentChatBaseFontSize,
            lineHeightMultiple: appState.agentChatLineHeightMultiple
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            previewBody
        }
        .onAppear { syncFromBinding() }
        .onCompatibleChange(of: selectedFile) { _, _ in syncFromBinding() }
        .onCompatibleChange(of: panelScope.sessionID) { _, _ in
            selectedFile = nil
            loadedURL = nil
            content = ""
            previewBlocks = []
            syncFromBinding()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            if let currentURL = loadedURL {
                Text(currentURL.lastPathComponent)
                    .font(AgentDesign.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(" ")
                    .font(AgentDesign.captionFont)
            }
            Spacer(minLength: 0)
            Button {
                pickFile()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help(L10n.AgentSidePanel.previewChoose)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    @ViewBuilder
    private var previewBody: some View {
        if let loadError {
            placeholder(systemImage: "exclamationmark.triangle", text: loadError)
        } else if loadedURL == nil {
            placeholderWithPicker
        } else if PreviewPaneCompatibility.supports(language) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(previewBlocks.enumerated()), id: \.offset) { _, block in
                        MarkdownPreviewBlockView(
                            block: block,
                            typography: previewTypography
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else if !content.isEmpty {
            // Plain-text fallback:之前 md/html 之外的文件直接显示
            // 「unsupported」placeholder,用户点 chip 等于看了个空。
            // 现在用 mono ScrollView 渲染原始文本,至少能看到内容,
            // 高亮/格式化交给 editor 窗口。
            ScrollView([.vertical, .horizontal]) {
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            placeholder(systemImage: "doc.questionmark", text: L10n.AgentSidePanel.previewUnsupported)
        }
    }

    private static func blocks(for content: String, language: Language?) -> [MarkdownPreviewBlock] {
        switch language {
        case .html:
            return HTMLPreviewParser.blocks(from: content)
        default:
            return MarkdownPreviewParser.blocks(from: content)
        }
    }

    private var placeholderWithPicker: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "doc.richtext")
                .font(.system(size: 22))
                .foregroundStyle(.secondary.opacity(0.6))
            Text(L10n.AgentSidePanel.previewEmpty)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L10n.AgentSidePanel.previewChoose) {
                pickFile()
            }
            .controlSize(.small)
            .focusable(false)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func placeholder(systemImage: String, text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(.secondary.opacity(0.6))
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    /// 同步规则:
    /// 1. selectedFile 有值且 != loadedURL → 读它
    /// 2. selectedFile 为 nil 且 loadedURL 也是 nil → 尝试 workspace README
    /// 3. 其余情况 → 维持当前状态(不刷)
    private func syncFromBinding() {
        if let url = selectedFile, url != loadedURL {
            load(url: url)
            return
        }
        if selectedFile == nil, loadedURL == nil {
            autoSelectReadme()
        }
    }

    private func autoSelectReadme() {
        guard let root = resolvedWorkspaceRoot() else { return }
        for candidate in ["README.md", "Readme.md", "readme.md", "README", "README.markdown"] {
            let url = root.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: url.path) {
                selectedFile = url
                load(url: url)
                return
            }
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let root = resolvedWorkspaceRoot() {
            panel.directoryURL = root
        }
        if panel.runModal() == .OK, let url = panel.url {
            selectedFile = url
            load(url: url)
        }
    }

    private func load(url: URL) {
        loadError = nil
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if Self.looksBinary(data) {
                content = ""
                previewBlocks = []
                loadedURL = url
                language = nil
                loadError = L10n.AgentSidePanel.previewUnsupported
                return
            }
            // 200KB 之后截断,避免 SwiftUI Text 在超大文件上卡死;同时
            // 给用户一个明确的「还有更多」提示。
            let cap = 200_000
            if data.count > cap {
                let trimmed = data.prefix(cap)
                content = String(decoding: trimmed, as: UTF8.self) + "\n\n[Truncated — open in editor to view full file]"
            } else {
                content = String(decoding: data, as: UTF8.self)
            }
            loadedURL = url
            language = Language.fromURL(url)
            previewBlocks = PreviewPaneCompatibility.supports(language)
                ? Self.blocks(for: content, language: language)
                : []
        } catch {
            content = ""
            previewBlocks = []
            loadedURL = url
            language = nil
            loadError = error.localizedDescription
        }
    }

    /// Cheap binary sniff:扫前 4KB,看到 NUL 就当 binary。够 PDF /
    /// PNG / 视频 / SQLite 类文件这种「头几 KB 就有 0x00」的格式过滤
    /// 掉,文本文件(代码、JSON、Markdown、YAML)绝大多数不会触发。
    private static func looksBinary(_ data: Data) -> Bool {
        let window = data.prefix(4096)
        return window.contains(0)
    }

    private func resolvedWorkspaceRoot() -> URL? {
        if let path = panelScope.runtime?.workspaceRootPath, !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return panelScope.workspaceRoot
    }
}

/// Tiny shim so the side-panel preview view doesn't need to import
/// PreviewPane's full surface area just to ask "is this language
/// previewable?".
private enum PreviewPaneCompatibility {
    static func supports(_ language: Language?) -> Bool {
        language == .markdown || language == .html
    }
}
