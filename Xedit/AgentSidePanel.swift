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

    init(kind: AgentSidePanelKind, file: URL? = nil, id: UUID = UUID()) {
        self.kind = kind
        self.file = file
        self.id = id
    }
}

enum AgentSidePanelKind: String, CaseIterable, Identifiable {
    case preview
    case diff
    case files
    case terminal
    case backgroundTasks
    case plan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preview: return L10n.AgentSidePanel.preview
        case .diff: return L10n.AgentSidePanel.diff
        case .files: return L10n.AgentSidePanel.files
        case .terminal: return L10n.AgentSidePanel.terminal
        case .backgroundTasks: return "任务监控"
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
        case .backgroundTasks: return "list.bullet.rectangle"
        case .plan: return "checklist"
        }
    }
}

struct AgentSidePanelHost: View {
    @EnvironmentObject var appState: AppState
    @Binding var kind: AgentSidePanelKind?
    @Binding var selectedFile: URL?
    /// Width is driven by the draggable divider in AgentModeView.
    var width: CGFloat = 320

    var body: some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.hairline).frame(height: 1)
            content
        }
        .frame(width: width)
        .background(palette.panelFill)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let kind {
                Image(systemName: kind.systemImage)
                    .foregroundStyle(.secondary)
                Text(kind.title)
                    .font(AgentDesign.titleFont)
                    // 窄侧栏时标题先截断,不要把关闭按钮挤出可视区。
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            // rc10 用户反馈:`Image(systemName: "xmark")` + `.secondary`
            // 在浅色皮肤上颜色弱到几乎看不见,误以为没有关闭按钮。
            // 给一个 22pt 圆形 hit area + 13pt 加粗字号 + 主文本色,
            // 至少肉眼第一秒就能看到。窄侧栏时 layoutPriority 保证它
            // 永远先拿到空间、不被标题挤掉。
            Button {
                kind = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.78))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .layoutPriority(1)
            .help(L10n.AgentSidePanel.close)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: AgentDesign.headerHeight)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .backgroundTasks:
            AgentTaskMonitorRail()
        case .diff:
            AgentSidePanelDiffView()
        case .files:
            AgentSidePanelFilesView(selectedFile: $selectedFile, kind: $kind)
        case .terminal:
            AgentSidePanelTerminalView()
        case .plan:
            AgentSidePanelPlanView()
        case .preview:
            AgentSidePanelPreviewView(selectedFile: $selectedFile)
        case .none:
            comingSoonPlaceholder
        }
    }

    private var comingSoonPlaceholder: some View {
        VStack(spacing: 8) {
            Spacer()
            if let kind {
                Image(systemName: kind.systemImage)
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary.opacity(0.6))
                Text(kind.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(L10n.AgentSidePanel.comingSoon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }
}

// MARK: - Diff panel
//
// Resolves the workspace root the same way `loadAgentWorktreeDiffPreview`
// does (active runtime → app rootDirectory), then shells out to
// `git diff --no-ext-diff HEAD --`. State machine kept on the view
// because diff loading is per-instance and short-lived; no need to
// litter AppState with another @Published.

struct AgentSidePanelDiffView: View {
    @EnvironmentObject var appState: AppState
    @State private var state: LoadState = .idle
    @State private var refreshTick = 0

    enum LoadState {
        case idle
        case loading
        case loaded(diff: String, summaryDate: Date)
        case empty
        case noWorkspace
        case notRepo
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            body(for: state)
        }
        .task(id: refreshTick) {
            await reload()
        }
        .onCompatibleChange(of: appState.activeAgentSessionID) { _, _ in
            refreshTick &+= 1
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Group {
                switch state {
                case .loaded(_, let date):
                    Text(L10n.AgentSidePanel.diffSummary(Self.dateFormatter.string(from: date)))
                case .loading:
                    Text(L10n.AgentSidePanel.diffLoading)
                default:
                    Text(" ")
                }
            }
            .font(AgentDesign.captionFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)

            Spacer(minLength: 0)

            Button {
                refreshTick &+= 1
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help(L10n.AgentSidePanel.refresh)
            .disabled({ if case .loading = state { return true }; return false }())
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    @ViewBuilder
    private func body(for state: LoadState) -> some View {
        switch state {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let diff, _):
            ScrollView([.vertical, .horizontal]) {
                Text(diff)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        case .empty:
            placeholder(systemImage: "checkmark.seal", text: L10n.AgentSidePanel.diffEmpty)
        case .noWorkspace:
            placeholder(systemImage: "folder.badge.questionmark", text: L10n.AgentSidePanel.noWorkspace)
        case .notRepo:
            placeholder(systemImage: "exclamationmark.triangle", text: L10n.AgentSidePanel.diffNotRepo)
        }
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

    private func reload() async {
        let root = resolveWorkspaceRoot()
        guard let root else {
            await MainActor.run { state = .noWorkspace }
            return
        }
        await MainActor.run { state = .loading }

        let result: LoadState = await Task.detached(priority: .userInitiated) {
            let check = AppState.runGitCommand(
                arguments: ["rev-parse", "--is-inside-work-tree"],
                in: root,
                allowedExitStatuses: [0, 128]
            )
            guard check.succeeded,
                  check.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
                return .notRepo
            }
            let diff = AppState.runGit(
                arguments: ["diff", "--no-ext-diff", "HEAD", "--"],
                in: root
            )
            let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return .empty
            }
            return .loaded(diff: diff, summaryDate: Date())
        }.value

        await MainActor.run { state = result }
    }

    private func resolveWorkspaceRoot() -> URL? {
        if let path = appState.activeRuntime?.workspaceRootPath, !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return appState.rootDirectory?.standardizedFileURL
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
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
                    onOpenFile: openFileInEditor
                )
            } else {
                placeholderNoWorkspace
            }
        }
        .onAppear { rebuildIfNeeded() }
        .onCompatibleChange(of: appState.activeAgentSessionID) { _, _ in rebuildIfNeeded() }
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
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 22))
                .foregroundStyle(.secondary.opacity(0.6))
            Text(L10n.AgentSidePanel.noWorkspace)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func rebuildIfNeeded() {
        let resolved: URL? = {
            if let path = appState.activeRuntime?.workspaceRootPath, !path.isEmpty {
                return URL(fileURLWithPath: path).standardizedFileURL
            }
            return appState.rootDirectory?.standardizedFileURL
        }()
        let newPath = resolved?.path
        if newPath == rootPath { return }
        rootPath = newPath
        root = resolved.map { FileSystemNode(url: $0) }
    }

    private func openFileInEditor(_ url: URL) {
        let fallbackURL = appState.openedFileURL
        guard appState.openEditorFile(url, fallbackURL: fallbackURL) else { return }
        if !appState.showEditor() {
            openWindow(id: EditorWindowID.value)
        }
    }
}

// MARK: - Plan panel
//
// Surfaces the current `AgentPlan` of the active runtime. Reuses the
// transcript-level `AgentPlanCard` so the side-panel view is in sync
// with whatever shows up inline once the plan is approved. The menu
// entry that opens this panel is hidden in `AgentChatHeader` when no
// plan exists, so the `nil` branch here is only a safety net for the
// case where the plan disappears while the panel is already open.

struct AgentSidePanelPlanView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if let plan = appState.agentCurrentPlan {
                ScrollView {
                    AgentPlanCard(plan: plan)
                        .padding(12)
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
    @Binding var selectedFile: URL?
    @State private var loadedURL: URL?
    @State private var content: String = ""
    @State private var language: Language?
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            previewBody
        }
        .onAppear { syncFromBinding() }
        .onCompatibleChange(of: selectedFile) { _, _ in syncFromBinding() }
        .onCompatibleChange(of: appState.activeAgentSessionID) { _, _ in
            selectedFile = nil
            loadedURL = nil
            content = ""
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
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        MarkdownPreviewBlockView(block: block)
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

    private var blocks: [MarkdownPreviewBlock] {
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
        } catch {
            content = ""
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
        if let path = appState.activeRuntime?.workspaceRootPath, !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return appState.rootDirectory?.standardizedFileURL
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
