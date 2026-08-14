//
//  AgentConversationActivityOverlay.swift
//  WillDeep
//
//  Event-driven summaries that float over the conversation instead of
//  reserving a permanent task-monitor rail. Session artifacts and media stay
//  scoped to the active runtime; Dev Server state is shared by every session
//  bound to the same workspace root.
//

import AppKit
import SwiftUI

struct AgentConversationActivityOverlay: View {
    @EnvironmentObject private var appState: AppState
    @State private var dismissedCardKeys: Set<String> = []
    /// Floating plan card fold state — replaces the old transcript-inline
    /// `isCurrentPlanExpanded`. Collapsed by default and auto-expands while
    /// the plan is newly ready.
    @State private var isPlanExpanded = false

    private var snapshot: AgentConversationActivitySnapshot {
        AgentConversationActivitySnapshot.capture(from: appState)
    }

    /// The current plan is task progress, independent of conversation mode.
    private var visiblePlan: AgentPlan? {
        guard let plan = appState.agentCurrentPlan,
              AgentPlanCardExpansionPolicy.shouldDisplay(plan) else {
            return nil
        }
        return plan
    }

    var body: some View {
        let snapshot = snapshot
        let plan = visiblePlan
        let artifactKey = snapshot.artifactDismissalKey
        let mediaKey = snapshot.mediaDismissalKey
        let devServerKey = snapshot.devServerDismissalKey
        let showsArtifacts = artifactKey.map { !dismissedCardKeys.contains($0) } ?? false
        let showsMedia = mediaKey.map { !dismissedCardKeys.contains($0) } ?? false
        let showsDevServer = devServerKey.map { !dismissedCardKeys.contains($0) } ?? false
        if plan != nil || showsArtifacts || showsMedia || showsDevServer {
            VStack(alignment: .trailing, spacing: 6) {
                // Plan card sits on top as the task's visible progress.
                if let plan {
                    AgentPlanCard(
                        plan: plan,
                        isExpanded: $isPlanExpanded,
                        floating: true,
                        onOpenDetails: openPlanDetails
                    )
                        .frame(
                            width: isPlanExpanded
                                ? AgentConversationActivityDesign.planExpandedWidth
                                : AgentConversationActivityDesign.cardWidth,
                            alignment: .trailing
                        )
                        .onAppear {
                            isPlanExpanded =
                                AgentPlanCardExpansionPolicy.initiallyExpanded(for: plan.status)
                        }
                        .onCompatibleChange(of: plan.status) { _, newStatus in
                            if AgentPlanCardExpansionPolicy.initiallyExpanded(for: newStatus) {
                                isPlanExpanded = true
                            }
                        }
                        .onCompatibleChange(of: appState.agentPlanOverlayCollapseRequestToken) { _, _ in
                            withAnimation(.easeInOut(duration: 0.18)) { isPlanExpanded = false }
                        }
                }
                if showsArtifacts, let artifactKey {
                    AgentArtifactActivityCard(urls: snapshot.sessionArtifacts) {
                        dismissedCardKeys.insert(artifactKey)
                    }
                    .frame(width: AgentConversationActivityDesign.cardWidth)
                }
                if showsMedia, let mediaSummary = snapshot.mediaSummary, let mediaKey {
                    AgentMediaActivityCard(summary: mediaSummary) {
                        dismissedCardKeys.insert(mediaKey)
                    }
                    .frame(width: AgentConversationActivityDesign.cardWidth)
                }
                if showsDevServer, let devServerSummary = snapshot.devServerSummary, let devServerKey {
                    AgentDevServerActivityCard(summary: devServerSummary) {
                        dismissedCardKeys.insert(devServerKey)
                    }
                    .frame(width: AgentConversationActivityDesign.cardWidth)
                }
            }
            .frame(alignment: .trailing)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .animation(.easeOut(duration: 0.18), value: snapshot.identityDigest)
        }
    }

    private func openPlanDetails() {
        appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .plan)
    }
}

struct AgentConversationActivitySnapshot {
    let sessionID: UUID?
    let sessionArtifacts: [URL]
    let mediaSummary: AgentSessionMediaSummary?
    let devServerSummary: AgentWorkspaceDevServerSummary?

    var hasVisibleCards: Bool {
        !sessionArtifacts.isEmpty || mediaSummary != nil || devServerSummary != nil
    }

    var artifactDismissalKey: String? {
        guard !sessionArtifacts.isEmpty else { return nil }
        return [
            "artifacts",
            sessionID?.uuidString ?? "no-session",
            sessionArtifacts.map(\.path).joined(separator: "|"),
        ].joined(separator: "::")
    }

    var mediaDismissalKey: String? {
        guard let mediaSummary else { return nil }
        return [
            "media",
            sessionID?.uuidString ?? "no-session",
            mediaSummary.dismissalDigest,
        ].joined(separator: "::")
    }

    var devServerDismissalKey: String? {
        guard let devServerSummary else { return nil }
        return [
            "dev-server",
            devServerSummary.workspaceRoot.path,
            devServerSummary.dismissalDigest,
        ].joined(separator: "::")
    }

    var identityDigest: String {
        [
            sessionID?.uuidString ?? "none",
            sessionArtifacts.map(\.path).joined(separator: "|"),
            mediaSummary?.identityDigest ?? "no-media",
            devServerSummary?.identityDigest ?? "no-dev-server",
        ].joined(separator: "::")
    }

    @MainActor
    static func capture(from appState: AppState) -> AgentConversationActivitySnapshot {
        let artifacts = AgentSessionArtifactScope.urls(from: appState)
        let media = AgentSessionMediaSummary.capture(from: appState)
        let devServer = AgentWorkspaceDevServerSummary.capture(from: appState)
        return AgentConversationActivitySnapshot(
            sessionID: appState.activeAgentSessionID,
            sessionArtifacts: artifacts,
            mediaSummary: media,
            devServerSummary: devServer
        )
    }
}

enum AgentSessionArtifactScope {
    @MainActor
    static func urls(from appState: AppState) -> [URL] {
        guard let runtime = appState.activeRuntime else { return [] }
        let workspaceURL = try? runtime.localWorkspaceURLForOptimisticUse()
        let repositoryURL = appState.agentWorktreeChanges.repositoryRoot ?? workspaceURL
        var urlsByPath: [String: URL] = [:]

        for path in runtime.agentArtifactPaths {
            guard let url = resolvedURL(path: path, root: workspaceURL), fileExists(url) else { continue }
            urlsByPath[url.path] = url
        }
        if let repositoryURL {
            // 只把「用户可消费的交付物」（白名单扩展名）当产物；普通源码变更
            // （.go/.swift/.ts 等）归入工作文件，不混进产物卡片。对齐
            // AgentTaskMonitorRail 的产物/工作文件划分。
            for change in appState.agentWorktreeChanges.files
            where AppState.isAgentSessionArtifactPath(change.path) {
                let url = repositoryURL.appendingPathComponent(change.path).standardizedFileURL
                guard fileExists(url) else { continue }
                urlsByPath[url.path] = url
            }
        }

        return urlsByPath.values.sorted { lhs, rhs in
            lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }
    }

    private static func resolvedURL(path: String, root: URL?) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }
        return root?.appendingPathComponent(trimmed).standardizedFileURL
    }

    private static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

struct AgentSessionMediaSummary {
    let tasks: [AgentMediaTask]
    let artifacts: [AgentMediaArtifact]
    let activeCount: Int
    let attentionCount: Int
    let imageCount: Int
    let videoCount: Int

    var identityDigest: String {
        tasks.map { task in
            "\(task.id.uuidString):\(task.status.rawValue):\(task.artifacts.count):\(Int(task.updatedAt.timeIntervalSince1970))"
        }.joined(separator: "|")
    }

    var dismissalDigest: String {
        tasks.map { task in
            "\(task.id.uuidString):\(task.status.rawValue):\(task.artifacts.map(\.filePath).joined(separator: ","))"
        }.joined(separator: "|")
    }

    @MainActor
    static func capture(from appState: AppState) -> AgentSessionMediaSummary? {
        let tasks = scopedTasks(
            appState.agentMediaTaskRegistry.tasks,
            runtimeID: appState.activeRuntime?.id
        )
        guard !tasks.isEmpty else { return nil }

        var artifactsByPath: [String: AgentMediaArtifact] = [:]
        for artifact in tasks.flatMap(\.artifacts) {
            artifactsByPath[URL(fileURLWithPath: artifact.filePath).standardizedFileURL.path] = artifact
        }
        let artifacts = artifactsByPath.values.sorted { lhs, rhs in
            lhs.createdAt > rhs.createdAt
        }
        return AgentSessionMediaSummary(
            tasks: tasks,
            artifacts: artifacts,
            activeCount: tasks.filter(\.isActive).count,
            attentionCount: tasks.filter(\.needsAttention).count,
            imageCount: artifacts.filter(isImageArtifact).count,
            videoCount: artifacts.filter(isVideoArtifact).count
        )
    }

    static func scopedTasks(_ tasks: [AgentMediaTask], runtimeID: UUID?) -> [AgentMediaTask] {
        guard let runtimeID else { return [] }
        return tasks
            .filter { task in
                task.runtimeID == runtimeID
                    && (task.isActive || task.needsAttention || task.status == .succeeded)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func isImageArtifact(_ artifact: AgentMediaArtifact) -> Bool {
        AgentConversationActivityFileKind.isImage(artifact.filePath, mimeType: artifact.mimeType)
    }

    private static func isVideoArtifact(_ artifact: AgentMediaArtifact) -> Bool {
        AgentConversationActivityFileKind.isVideo(artifact.filePath, mimeType: artifact.mimeType)
    }
}

struct AgentWorkspaceDevServerSummary {
    let workspaceRoot: URL
    let jobs: [AgentBackgroundJob]
    let previewURL: URL?

    var identityDigest: String {
        jobs.map { "\($0.id.uuidString):\($0.status.rawValue):\($0.outputByteCount)" }
            .joined(separator: "|") + (previewURL?.absoluteString ?? "")
    }

    var dismissalDigest: String {
        jobs.map { "\($0.id.uuidString):\($0.status.rawValue)" }
            .joined(separator: "|") + (previewURL?.absoluteString ?? "")
    }

    var portLabel: String? {
        previewURL?.port.map { ":\($0)" }
    }

    @MainActor
    static func capture(from appState: AppState) -> AgentWorkspaceDevServerSummary? {
        guard let root = AgentWorkspaceDevServerSupport.workspaceRootURL(from: appState) else { return nil }
        let jobs = AgentWorkspaceDevServerSupport.runningServerJobs(
            in: appState.agentJobRegistry,
            workspaceRoot: root
        )
        guard !jobs.isEmpty else { return nil }
        let previewURL = AgentWorkspaceDevServerSupport.previewURL(for: jobs) { job in
            appState.agentJobRegistry.output(id: job.id, tailLines: 120)
        }
        return AgentWorkspaceDevServerSummary(
            workspaceRoot: root,
            jobs: jobs,
            previewURL: previewURL
        )
    }
}

enum AgentWorkspaceDevServerSupport {
    @MainActor
    static func workspaceRootURL(from appState: AppState) -> URL? {
        if let path = appState.activeRuntime?.workspaceLocation?.localPath, !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        if let path = appState.activeRuntime?.workspaceRootPath, !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return appState.rootDirectory?.standardizedFileURL
    }

    @MainActor
    static func runningServerJobs(
        in registry: AgentJobRegistry,
        workspaceRoot: URL
    ) -> [AgentBackgroundJob] {
        registry.jobs(inWorkspaceRoot: workspaceRoot).filter { job in
            job.isAlive && looksLikeDevServerCommand(job.command) && !looksLikeTailCommand(job.command)
        }
    }

    static func looksLikeTailCommand(_ command: String) -> Bool {
        command.lowercased().contains("tail -f")
    }

    static func looksLikeDevServerCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        let needles = [
            "yarn dev", "yarn start", "yarn serve",
            "npm run dev", "npm start", "npm run serve",
            "pnpm dev", "pnpm start", "pnpm serve", "bun dev",
            "vite", "next dev", "react-scripts start", "vue-cli-service serve",
            "air", "gin --", "go run", "rails server", "rails s",
            "uvicorn", "fastapi", "nodemon", "python -m http.server",
            "python3 -m http.server",
        ]
        return needles.contains { lower.contains($0) }
    }

    static func previewURL(
        for jobs: [AgentBackgroundJob],
        output: (AgentBackgroundJob) -> String
    ) -> URL? {
        for job in jobs {
            if let url = URLDetector.firstLocalWebURL(in: output(job)) {
                return url
            }
        }
        for job in jobs {
            if let port = explicitPort(in: job.command) ?? defaultPort(for: job.command) {
                return URL(string: "http://127.0.0.1:\(port)")
            }
        }
        return nil
    }

    private static func explicitPort(in command: String) -> Int? {
        let patterns = [
            #"--port(?:=|\s+)(\d{2,5})"#,
            #"(?:^|\s)-p\s+(\d{2,5})(?:\s|$)"#,
            #"(?:localhost|127\.0\.0\.1|0\.0\.0\.0):(\d{2,5})"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(command.startIndex..<command.endIndex, in: command)
            guard let match = regex.firstMatch(in: command, range: range),
                  let portRange = Range(match.range(at: 1), in: command),
                  let port = Int(command[portRange]),
                  (1...65_535).contains(port) else { continue }
            return port
        }
        return nil
    }

    private static func defaultPort(for command: String) -> Int? {
        let lower = command.lowercased()
        if lower.contains("vite") || lower.contains("yarn dev") || lower.contains("pnpm dev") {
            return 5173
        }
        if lower.contains("next dev") || lower.contains("react-scripts start") || lower.contains("rails server") || lower.contains("rails s") {
            return 3000
        }
        if lower.contains("vue-cli-service serve") {
            return 8080
        }
        if lower.contains("uvicorn") || lower.contains("fastapi") || lower.contains("python -m http.server") || lower.contains("python3 -m http.server") {
            return 8000
        }
        return nil
    }
}

private enum URLDetector {
    static func firstLocalWebURL(in text: String) -> URL? {
        let pattern = #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(?::\d{1,5})(?:/[^\s\]\[\)\}"']*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else { return nil }
        let raw = String(text[matchRange])
            .replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
            .replacingOccurrences(of: "[::1]", with: "127.0.0.1")
        return URL(string: raw)
    }
}

enum AgentActivityCardChrome {
    static let artifactIcon = AgentComposerChrome.iconSecondary
    static let devServerIcon = AgentComposerChrome.iconSecondary
}

private struct AgentArtifactActivityCard: View {
    @EnvironmentObject private var appState: AppState
    let urls: [URL]
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: openPrimaryDestination) {
                AgentActivityCardLabel(
                    systemImage: "folder",
                    tint: AgentActivityCardChrome.artifactIcon,
                    title: "\(urls.count) 个产物",
                    subtitle: subtitle,
                    isSelected: isSelected
                )
            }
            .buttonStyle(.plain)
            .focusable(false)
            .cursor(.arrow)

            Menu {
                if let htmlURL {
                    Button("预览 \(htmlURL.lastPathComponent)") {
                        openPreview(htmlURL)
                    }
                }
                Button("查看全部文件") {
                    openFiles()
                }
                Divider()
                ForEach(urls.prefix(6), id: \.path) { url in
                    Menu {
                        AgentArtifactFileContextMenu(fileURL: url)
                    } label: {
                        Text(url.lastPathComponent)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 42)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .agentQuietMenuChrome()
            .focusable(false)
            .help("选择产物")
            .cursor(.arrow)

            AgentActivityCardDismissButton(action: onDismiss)
        }
        .agentActivityCardSurface(isSelected: isSelected)
        .contextMenu {
            if urls.count == 1, let url = urls.first {
                AgentArtifactFileContextMenu(fileURL: url)
            } else {
                ForEach(urls.prefix(12), id: \.path) { url in
                    Menu(url.lastPathComponent) {
                        AgentArtifactFileContextMenu(fileURL: url)
                    }
                }
            }
        }
        .cursor(.arrow)
    }

    private var isSelected: Bool {
        appState.agentSidePanelKind == .files ||
            appState.agentSidePanelKind == .preview ||
            appState.agentSidePanelKind == .diff
    }

    private var htmlURL: URL? {
        urls.first { ["html", "htm"].contains($0.pathExtension.lowercased()) }
    }

    private var subtitle: String {
        let htmlCount = urls.filter { ["html", "htm"].contains($0.pathExtension.lowercased()) }.count
        let preview = urls.prefix(2).map(\.lastPathComponent).joined(separator: " · ")
        if htmlCount > 0 {
            return "\(preview) · \(htmlCount) 个 HTML"
        }
        return preview
    }

    private func openPrimaryDestination() {
        if let first = urls.first {
            open(first)
        } else {
            openFiles()
        }
    }

    private func open(_ url: URL) {
        appState.revealAgentArtifactFileInSidePanel(url)
    }

    private func openPreview(_ url: URL) {
        appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .preview, file: url)
    }

    private func openFiles() {
        let first = urls.first
        appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .files, file: first)
    }
}

private struct AgentMediaActivityCard: View {
    @EnvironmentObject private var appState: AppState
    let summary: AgentSessionMediaSummary
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: openMediaTasks) {
                HStack(spacing: 9) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if summary.artifacts.isEmpty {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            HStack(spacing: 4) {
                                ForEach(summary.artifacts.prefix(3)) { artifact in
                                    AgentActivityMediaThumbnail(artifact: artifact)
                                }
                                Text(subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 4)
                }
                .padding(.leading, 11)
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .cursor(.arrow)

            AgentActivityCardDismissButton(action: onDismiss)
        }
        .agentActivityCardSurface(isSelected: isSelected)
        .cursor(.arrow)
        .contextMenu {
            Button("打开媒体任务") {
                openMediaTasks()
            }
        }
    }

    private var isSelected: Bool {
        appState.agentSidePanelKind == .mediaTasks || appState.agentSidePanelKind == .imageEditor
    }

    private var tint: Color {
        if summary.attentionCount > 0 { return .orange }
        return .purple
    }

    private var title: String {
        if summary.attentionCount > 0 {
            return "\(summary.attentionCount) 个媒体需处理"
        }
        if summary.activeCount > 0 {
            return "\(summary.activeCount) 个媒体生成中"
        }
        return "\(summary.artifacts.count) 个媒体"
    }

    private var subtitle: String {
        if summary.artifacts.isEmpty {
            return "任务已提交，等待产物"
        }
        var parts: [String] = []
        if summary.imageCount > 0 { parts.append("\(summary.imageCount) 图") }
        if summary.videoCount > 0 { parts.append("\(summary.videoCount) 视频") }
        return parts.joined(separator: " · ")
    }

    private func openMediaTasks() {
        appState.agentMediaTaskPanelScope = nil
        appState.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .mediaTasks)
    }
}

private struct AgentDevServerActivityCard: View {
    @EnvironmentObject private var appState: AppState
    let summary: AgentWorkspaceDevServerSummary
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: openPrimaryDestination) {
                AgentActivityCardLabel(
                    systemImage: "server.rack",
                    tint: AgentActivityCardChrome.devServerIcon,
                    title: "Dev Server",
                    subtitle: devServerSubtitle,
                    isSelected: isSelected
                )
            }
            .buttonStyle(.plain)
            .focusable(false)
            .cursor(.arrow)

            Menu {
                if summary.previewURL != nil {
                    Button("预览页面") {
                        openPreview()
                    }
                }
                Button("管理 Dev Server") {
                    openManager()
                }
                Divider()
                Button("重新启动工作区服务") {
                    restartServers()
                }
                Button("停止工作区服务", role: .destructive) {
                    stopServers()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 42)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .agentQuietMenuChrome()
            .focusable(false)
            .help("预览或管理工作区 Dev Server")
            .cursor(.arrow)

            AgentActivityCardDismissButton(action: onDismiss)
        }
        .agentActivityCardSurface(isSelected: isSelected)
        .cursor(.arrow)
    }

    private var isSelected: Bool {
        appState.agentSidePanelKind == .devServer || appState.agentSidePanelKind == .embeddedBrowser
    }

    private var devServerSubtitle: String {
        let serviceText = summary.jobs.count == 1 ? "运行中" : "\(summary.jobs.count) 个服务运行中"
        guard let portLabel = summary.portLabel else { return "工作区共享 · \(serviceText)" }
        return "\(portLabel) · 工作区共享 · \(serviceText)"
    }

    private func openPrimaryDestination() {
        if summary.previewURL != nil {
            openPreview()
        } else {
            openManager()
        }
    }

    private func openPreview() {
        guard let url = summary.previewURL else {
            openManager()
            return
        }
        let controller = AgentEmbeddedBrowserController.controller(
            for: appState.activeRuntime?.id
        )
        controller.address = url.absoluteString
        if controller.isReady {
            try? controller.navigate(to: url.absoluteString)
        }
        appState.agentSidePanelKind = .embeddedBrowser
    }

    private func openManager() {
        appState.agentSidePanelKind = .devServer
    }

    private func stopServers() {
        summary.jobs.forEach { _ = appState.agentJobRegistry.kill(id: $0.id) }
    }

    private func restartServers() {
        let jobs = summary.jobs
        stopServers()
        let runtimeID = appState.activeRuntime?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            for job in jobs {
                restart(job, runtimeID: runtimeID ?? job.runtimeID)
            }
        }
    }

    private func restart(_ job: AgentBackgroundJob, runtimeID: UUID) {
        let workingDirectory = job.workingDirectoryPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        } ?? summary.workspaceRoot
        _ = try? appState.agentJobRegistry.start(
            command: job.command,
            workingDirectory: workingDirectory,
            additionalWorkspaceRoots: appState.activeRuntime.map {
                appState.agentWorkspaceRoots(for: $0.session)
            } ?? [],
            runtimeID: runtimeID,
            timeoutSeconds: nil,
            sandboxMode: .workspaceWriteNetwork,
            displayCommand: job.command
        )
    }
}

private struct AgentActivityCardLabel: View {
    let systemImage: String
    let tint: Color
    let title: String
    let subtitle: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
        }
        .padding(.leading, 11)
        .padding(.vertical, 9)
        // The whole artifact summary is a button, not selectable prose.
        // Disable inherited text selection so hovering its title/subtitle
        // never replaces the expected arrow with an I-beam cursor.
        .textSelection(.disabled)
        .cursor(.arrow)
    }
}

private struct AgentActivityCardDismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 22, height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("关闭摘要")
        .accessibilityLabel("关闭摘要")
        .cursor(.arrow)
    }
}

private struct AgentActivityMediaThumbnail: View {
    let artifact: AgentMediaArtifact
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: fallbackSystemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.04))
            }
        }
        .frame(width: 28, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .task(id: artifact.filePath) {
            guard AgentConversationActivityFileKind.isImage(artifact.filePath, mimeType: artifact.mimeType) else {
                thumbnail = nil
                return
            }
            thumbnail = await AgentThumbnailImageCache.image(
                forFileURL: URL(fileURLWithPath: artifact.filePath),
                targetPixels: 56
            )
        }
    }

    private var fallbackSystemImage: String {
        AgentConversationActivityFileKind.isVideo(artifact.filePath, mimeType: artifact.mimeType)
            ? "play.fill"
            : "photo"
    }
}

private enum AgentConversationActivityFileKind {
    static func isImage(_ path: String, mimeType: String?) -> Bool {
        if mimeType?.lowercased().hasPrefix("image/") == true { return true }
        return ["png", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "heic", "svg"]
            .contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    static func isVideo(_ path: String, mimeType: String?) -> Bool {
        if mimeType?.lowercased().hasPrefix("video/") == true { return true }
        return ["mp4", "mov", "m4v", "webm", "avi", "mkv"]
            .contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
}

private enum AgentConversationActivityDesign {
    static let cardWidth: CGFloat = 214
    /// Plan card widens when expanded so step text, approve/reject buttons and
    /// the replan row aren't crammed into the 214pt collapsed rail width.
    static let planExpandedWidth: CGFloat = 320
    static let borderColor = Color(nsColor: .separatorColor)
}

private extension View {
    func agentActivityCardSurface(isSelected: Bool) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        AgentConversationActivityDesign.borderColor.opacity(isSelected ? 0.82 : 0.58),
                        lineWidth: isSelected ? 1.25 : 1
                    )
            }
            .shadow(color: Color.black.opacity(0.055), radius: 7, x: 0, y: 2)
    }
}
