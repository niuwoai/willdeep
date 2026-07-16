//
//  AgentDevServerPanel.swift
//  WillDeep
//
//  Web-programming side panel for project dev servers and live log jobs.
//  It reuses AgentJobRegistry so AI-started and user-started Vite/Next,
//  backend, and tail -f jobs stay visible and controllable in one place.
//

import SwiftUI
import Combine

struct AgentDevServerPanel: View {
    @EnvironmentObject var appState: AppState
    var width: CGFloat = 320

    @State private var logPath: String = ""
    @State private var refreshTick = Date()
    @State private var discoveredCommands: [DevServerCommandCandidate] = []
    @State private var lastError: String?

    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let palette = appState.editorSettings.interfaceSkin.palette
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                projectCommandsSection
                logTailBox
                jobsSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
        }
        .frame(width: width)
        .background(palette.panelFill)
        .onAppear(perform: refreshCommands)
        .onReceive(appState.$activeAgentSessionID) { _ in refreshCommands() }
        .onReceive(timer) { value in
            refreshTick = value
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Dev Server")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(runningServerJobs.count) running")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if previewURL != nil {
                    Button(action: openPreview) {
                        Image(systemName: "safari")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("在侧栏预览工作区页面")
                }
                if !runningServerJobs.isEmpty {
                    Button(action: restartAllServers) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("重启工作区 Dev Server")
                    Button(action: stopAllServers) {
                        Image(systemName: "stop.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("停止工作区 Dev Server")
                }
            }
            Text("绑定当前工作区的前端、后端和 tail -f 日志任务。AI 或你在这里启动的后台任务都会出现在同一个列表里。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let workspaceRootURL {
                Text(workspaceRootURL.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("当前 Agent 会话还没有绑定本地工作区。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let lastError {
                Text(lastError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var projectCommandsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("项目命令")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: refreshCommands) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help("重新扫描工作区脚本")
            }

            roleSection(.frontend)
            roleSection(.backend)

            if discoveredCommands.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("没有自动发现可启动的 dev 命令。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        appendPrompt("请激活 Web 编程专家流程，扫描当前工作区的前端和后端启动方式；优先用 yarn，必要时分别启动前端与后端 dev server，并把可预览 URL 打开在预览侧栏。")
                    } label: {
                        Label("让 AI 识别", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
    }

    private func roleSection(_ role: DevServerRole) -> some View {
        let commands = discoveredCommands.filter { $0.role == role }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: role.iconName)
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                Text(role.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            if commands.isEmpty {
                Text(role.emptyText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(commands) { candidate in
                        DevServerCommandCard(
                            candidate: candidate,
                            runningJobs: matchingJobs(for: candidate),
                            start: { start(candidate) },
                            restart: { restart(candidate) },
                            stop: { stop(candidate) }
                        )
                    }
                }
            }
        }
    }

    private var logTailBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tail 日志")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("logs/dev.log 或 /tmp/app.log", text: $logPath)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            HStack(spacing: 8) {
                Button {
                    startTail()
                } label: {
                    Label("开始 tail", systemImage: "text.alignleft")
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .disabled(logPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.activeRuntime?.id == nil)

                Button {
                    appendPrompt("请根据当前前端/后端 dev server 输出，判断应该 tail -f 哪个日志文件；如果有明确日志文件，请直接启动 tail -f；如果没有日志文件，就用 get_job_output 读取后台任务输出。")
                } label: {
                    Label("让 AI 选择", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderless)
                .focusable(false)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
    }

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("运行中 / 最近")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !devJobs.isEmpty {
                    Text(refreshTick, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            if devJobs.isEmpty {
                Text("还没有 dev server 或 tail -f 任务。启动前端、后端或日志后，这里会显示句柄、状态、停止按钮和输出尾部。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(devJobs) { job in
                        DevServerJobCard(
                            job: job,
                            output: appState.agentJobRegistry.output(id: job.id, tailLines: 60),
                            inspect: { appState.prefillAgentJobInspectionPrompt(for: job) },
                            restart: { restart(job) },
                            kill: { _ = appState.agentJobRegistry.kill(id: job.id) }
                        )
                    }
                }
            }
        }
    }

    private var workspaceRootURL: URL? {
        AgentWorkspaceDevServerSupport.workspaceRootURL(from: appState)
    }

    private var devJobs: [AgentBackgroundJob] {
        guard let workspaceRootURL else { return [] }
        return appState.agentJobRegistry.jobs(inWorkspaceRoot: workspaceRootURL)
            .filter { job in
                job.isAlive || Self.looksLikeDevServerCommand(job.command)
            }
    }

    private var runningServerJobs: [AgentBackgroundJob] {
        devJobs.filter { job in
            job.isAlive
                && Self.looksLikeDevServerCommand(job.command)
                && !Self.looksLikeTailCommand(job.command)
        }
    }

    private var previewURL: URL? {
        AgentWorkspaceDevServerSupport.previewURL(for: runningServerJobs) { job in
            appState.agentJobRegistry.output(id: job.id, tailLines: 120)
        }
    }

    private func refreshCommands() {
        guard let root = workspaceRootURL else {
            discoveredCommands = []
            return
        }
        discoveredCommands = DevServerCommandDiscoverer.discover(root: root)
        lastError = nil
    }

    private func start(_ candidate: DevServerCommandCandidate) {
        runCommand(
            candidate.command,
            workingDirectory: candidate.directory,
            sandboxMode: .workspaceWriteNetwork,
            displayCommand: candidate.command
        )
    }

    private func restart(_ candidate: DevServerCommandCandidate) {
        stop(candidate)
        start(candidate)
    }

    private func stop(_ candidate: DevServerCommandCandidate) {
        matchingJobs(for: candidate).forEach { _ = appState.agentJobRegistry.kill(id: $0.id) }
    }

    private func restart(_ job: AgentBackgroundJob) {
        _ = appState.agentJobRegistry.kill(id: job.id)
        let directory = job.workingDirectoryPath.map { URL(fileURLWithPath: $0).standardizedFileURL } ?? workspaceRootURL
        runCommand(
            job.command,
            workingDirectory: directory,
            sandboxMode: Self.looksLikeTailCommand(job.command) ? .readOnly : .workspaceWriteNetwork,
            displayCommand: job.command
        )
    }

    private func startTail() {
        let trimmed = logPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let command = "tail -f \(devServerShellQuoted(trimmed))"
        runCommand(
            command,
            workingDirectory: workspaceRootURL,
            sandboxMode: .readOnly,
            displayCommand: command
        )
    }

    private func openPreview() {
        guard let previewURL else { return }
        let controller = AgentEmbeddedBrowserController.shared
        controller.address = previewURL.absoluteString
        if controller.isReady {
            try? controller.navigate(to: previewURL.absoluteString)
        }
        appState.agentSidePanelKind = .embeddedBrowser
    }

    private func restartAllServers() {
        runningServerJobs.forEach(restart)
    }

    private func stopAllServers() {
        runningServerJobs.forEach { _ = appState.agentJobRegistry.kill(id: $0.id) }
    }

    private func runCommand(
        _ command: String,
        workingDirectory: URL?,
        sandboxMode: AgentSandboxMode,
        displayCommand: String
    ) {
        guard let runtimeID = appState.activeRuntime?.id else {
            lastError = "没有可用的 Agent 会话，无法启动后台任务。"
            return
        }
        do {
            _ = try appState.agentJobRegistry.start(
                command: command,
                workingDirectory: workingDirectory,
                runtimeID: runtimeID,
                timeoutSeconds: nil,
                sandboxMode: sandboxMode,
                displayCommand: displayCommand
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func matchingJobs(for candidate: DevServerCommandCandidate) -> [AgentBackgroundJob] {
        devJobs.filter { job in
            guard job.isAlive else { return false }
            let sameCommand = normalizedCommand(job.command) == normalizedCommand(candidate.command)
            let sameDirectory = job.workingDirectoryPath == nil || job.workingDirectoryPath == candidate.directory.path
            return sameCommand && sameDirectory
        }
    }

    private func appendPrompt(_ prompt: String) {
        let trimmedInput = appState.agentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedInput.isEmpty {
            appState.agentInput = prompt
        } else {
            appState.agentInput += "\n\n\(prompt)"
        }
        appState.agentComposerFocusRevision += 1
    }

    private static func looksLikeTailCommand(_ command: String) -> Bool {
        AgentWorkspaceDevServerSupport.looksLikeTailCommand(command)
    }

    private static func looksLikeDevServerCommand(_ command: String) -> Bool {
        AgentWorkspaceDevServerSupport.looksLikeDevServerCommand(command)
            || AgentWorkspaceDevServerSupport.looksLikeTailCommand(command)
    }

    private func normalizedCommand(_ command: String) -> String {
        command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
            .lowercased()
    }
}

private enum DevServerRole: String {
    case frontend
    case backend

    var title: String {
        switch self {
        case .frontend: return "前端 Dev Server"
        case .backend: return "后端 Dev Server"
        }
    }

    var iconName: String {
        switch self {
        case .frontend: return "rectangle.on.rectangle"
        case .backend: return "server.rack"
        }
    }

    var emptyText: String {
        switch self {
        case .frontend: return "未发现 Vite / Next / React / Vue 等前端 dev 脚本。"
        case .backend: return "未发现后端 dev 脚本或常见 Go/Rails/FastAPI 入口。"
        }
    }
}

private struct DevServerCommandCandidate: Identifiable, Equatable {
    let role: DevServerRole
    let title: String
    let command: String
    let directory: URL
    let source: String

    var id: String {
        "\(role.rawValue)|\(directory.path)|\(command)"
    }
}

private struct DevServerCommandCard: View {
    let candidate: DevServerCommandCandidate
    let runningJobs: [AgentBackgroundJob]
    let start: () -> Void
    let restart: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(runningJobs.isEmpty ? Color.secondary.opacity(0.45) : Color.green)
                    .frame(width: 7, height: 7)
                Text(candidate.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if runningJobs.isEmpty {
                    Button(action: start) {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("启动")
                } else {
                    Button(action: restart) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("重启")
                    Button(action: stop) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("停止")
                }
            }
            Text(candidate.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text("\(candidate.source) · \(candidate.directory.path)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !runningJobs.isEmpty {
                Text(runningJobs.map(\.displayHandle).joined(separator: ", "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.green)
                    .lineLimit(1)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.035)))
    }
}

private struct DevServerJobCard: View {
    let job: AgentBackgroundJob
    let output: String
    let inspect: () -> Void
    let restart: () -> Void
    let kill: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(job.displayHandle)
                    .font(.caption.weight(.semibold).monospaced())
                Text(job.status.rawValue)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: inspect) {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help("读取输出")
                Button(action: restart) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help("按原命令重启")
                Button(action: kill) {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .disabled(!job.isAlive)
                .help("停止任务")
            }
            Text(job.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            ScrollView(.vertical, showsIndicators: true) {
                Text(output.isEmpty ? "(no output captured yet)" : output)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.82))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 78, maxHeight: 170)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.08)))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
    }

    private var statusColor: Color {
        switch job.status {
        case .running: return .green
        case .completed: return .blue
        case .failed, .launchFailed, .timedOut: return .red
        case .killed: return .orange
        }
    }
}

private enum DevServerCommandDiscoverer {
    static func discover(root: URL) -> [DevServerCommandCandidate] {
        let directories = candidateDirectories(root: root.standardizedFileURL)
        var candidates: [DevServerCommandCandidate] = []
        for directory in directories {
            candidates += packageCandidates(in: directory)
            candidates += goCandidates(in: directory)
            candidates += rubyCandidates(in: directory)
            candidates += pythonCandidates(in: directory)
            candidates += staticHTMLCandidates(in: directory)
        }
        return unique(candidates)
    }

    private static func candidateDirectories(root: URL) -> [URL] {
        let fileManager = FileManager.default
        var directories: [URL] = [root]
        let commonRelativePaths = [
            "web", "frontend", "client", "app", "ui",
            "apps/web", "apps/frontend", "packages/web", "packages/frontend",
            "server", "backend", "api", "cmd/server"
        ]
        for relative in commonRelativePaths {
            let url = root.appendingPathComponent(relative).standardizedFileURL
            if isDirectory(url, fileManager: fileManager) {
                directories.append(url)
            }
        }

        if let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for child in children where isScannableDirectory(child, fileManager: fileManager) {
                if hasProjectMarker(in: child, fileManager: fileManager) {
                    directories.append(child.standardizedFileURL)
                }
                if let grandchildren = try? fileManager.contentsOfDirectory(
                    at: child,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for grandchild in grandchildren where isScannableDirectory(grandchild, fileManager: fileManager) {
                        if hasProjectMarker(in: grandchild, fileManager: fileManager) {
                            directories.append(grandchild.standardizedFileURL)
                        }
                    }
                }
            }
        }

        var seen = Set<String>()
        return directories.filter { directory in
            let path = directory.standardizedFileURL.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    private static func packageCandidates(in directory: URL) -> [DevServerCommandCandidate] {
        let packageURL = directory.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let scripts = object["scripts"] as? [String: Any] ?? [:]
        guard !scripts.isEmpty else { return [] }
        let dependencies = dependencyNames(from: object)
        let manager = packageManager(for: directory, package: object)
        var candidates: [DevServerCommandCandidate] = []

        for key in scripts.keys.sorted() {
            guard let body = scripts[key] as? String else { continue }
            let role = scriptRole(name: key, body: body, dependencies: dependencies)
            guard let role else { continue }
            let command = scriptCommand(manager: manager, script: key)
            let title = "\(role == .frontend ? "前端" : "后端") · \(key)"
            candidates.append(
                DevServerCommandCandidate(
                    role: role,
                    title: title,
                    command: command,
                    directory: directory.standardizedFileURL,
                    source: "package.json"
                )
            )
        }
        return candidates
    }

    private static func goCandidates(in directory: URL) -> [DevServerCommandCandidate] {
        let goMod = directory.appendingPathComponent("go.mod")
        guard FileManager.default.fileExists(atPath: goMod.path) else { return [] }
        let cmdServer = directory.appendingPathComponent("cmd/server")
        let command: String
        if isDirectory(cmdServer, fileManager: .default) {
            command = "go run ./cmd/server"
        } else if let singleCommand = firstGoCommand(in: directory) {
            command = "go run ./cmd/\(singleCommand)"
        } else {
            command = "go run ."
        }
        return [
            DevServerCommandCandidate(
                role: .backend,
                title: "后端 · Go",
                command: command,
                directory: directory.standardizedFileURL,
                source: "go.mod"
            )
        ]
    }

    private static func rubyCandidates(in directory: URL) -> [DevServerCommandCandidate] {
        let gemfile = directory.appendingPathComponent("Gemfile")
        guard let text = try? String(contentsOf: gemfile), text.lowercased().contains("rails") else {
            return []
        }
        return [
            DevServerCommandCandidate(
                role: .backend,
                title: "后端 · Rails",
                command: "bundle exec rails server",
                directory: directory.standardizedFileURL,
                source: "Gemfile"
            )
        ]
    }

    private static func pythonCandidates(in directory: URL) -> [DevServerCommandCandidate] {
        let fileManager = FileManager.default
        let requirementFiles = ["requirements.txt", "pyproject.toml", "Pipfile"]
        let hasPythonProject = requirementFiles.contains { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }
        guard hasPythonProject else { return [] }
        let searchableText = requirementFiles.compactMap {
            try? String(contentsOf: directory.appendingPathComponent($0))
        }.joined(separator: "\n").lowercased()
        guard searchableText.contains("fastapi") || searchableText.contains("uvicorn") else { return [] }
        let module = ["main.py", "app.py"].first { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }?
            .replacingOccurrences(of: ".py", with: "") ?? "main"
        return [
            DevServerCommandCandidate(
                role: .backend,
                title: "后端 · FastAPI",
                command: "uvicorn \(module):app --reload",
                directory: directory.standardizedFileURL,
                source: "Python"
            )
        ]
    }

    private static func staticHTMLCandidates(in directory: URL) -> [DevServerCommandCandidate] {
        let index = directory.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: index.path),
              !FileManager.default.fileExists(atPath: directory.appendingPathComponent("package.json").path) else {
            return []
        }
        return [
            DevServerCommandCandidate(
                role: .frontend,
                title: "前端 · 静态 HTML",
                command: "python3 -m http.server 5173",
                directory: directory.standardizedFileURL,
                source: "index.html"
            )
        ]
    }

    private static func dependencyNames(from package: [String: Any]) -> Set<String> {
        var names = Set<String>()
        for key in ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"] {
            guard let dependencies = package[key] as? [String: Any] else { continue }
            names.formUnion(dependencies.keys.map { $0.lowercased() })
        }
        return names
    }

    private static func packageManager(for directory: URL, package: [String: Any]) -> String {
        let declared = (package["packageManager"] as? String)?.lowercased() ?? ""
        if declared.hasPrefix("yarn") { return "yarn" }
        if declared.hasPrefix("pnpm") { return "pnpm" }
        if declared.hasPrefix("npm") { return "npm" }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("yarn.lock").path) { return "yarn" }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("pnpm-lock.yaml").path) { return "pnpm" }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("package-lock.json").path) { return "npm" }
        return "yarn"
    }

    private static func scriptCommand(manager: String, script: String) -> String {
        switch manager {
        case "npm":
            return script == "start" ? "npm start" : "npm run \(devServerShellQuoted(script))"
        case "pnpm":
            return "pnpm \(devServerShellQuoted(script))"
        default:
            return "yarn \(devServerShellQuoted(script))"
        }
    }

    private static func scriptRole(name: String, body: String, dependencies: Set<String>) -> DevServerRole? {
        let lowerName = name.lowercased()
        let lowerBody = body.lowercased()
        let frontendMarkers = [
            "vite", "next dev", "react-scripts start", "vue-cli-service serve",
            "astro dev", "nuxt dev", "svelte-kit dev", "remix vite:dev"
        ]
        let backendMarkers = [
            "nodemon", "tsx watch", "ts-node", "nest start",
            "fastify", "hono", "express", "node server", "node ./server"
        ]
        let frontendDependencies = [
            "vite", "next", "react", "react-dom", "vue", "nuxt",
            "astro", "svelte", "@sveltejs/kit", "@vitejs/plugin-react"
        ]
        let backendDependencies = [
            "express", "fastify", "koa", "hono", "@nestjs/core", "nodemon", "tsx"
        ]

        if frontendMarkers.contains(where: { lowerBody.contains($0) }) {
            return .frontend
        }
        if backendMarkers.contains(where: { lowerBody.contains($0) }) {
            return .backend
        }
        if lowerName.contains("frontend") || lowerName.contains("web") || lowerName.contains("client") {
            return .frontend
        }
        if lowerName.contains("backend") || lowerName.contains("server") || lowerName.contains("api") {
            return .backend
        }
        if ["dev", "start", "serve"].contains(lowerName) {
            if frontendDependencies.contains(where: { dependencies.contains($0) }) {
                return .frontend
            }
            if backendDependencies.contains(where: { dependencies.contains($0) }) {
                return .backend
            }
        }
        return nil
    }

    private static func firstGoCommand(in directory: URL) -> String? {
        let cmd = directory.appendingPathComponent("cmd")
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: cmd,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let names = children
            .filter { isDirectory($0, fileManager: .default) }
            .map(\.lastPathComponent)
            .sorted()
        return names.first
    }

    private static func hasProjectMarker(in directory: URL, fileManager: FileManager) -> Bool {
        ["package.json", "go.mod", "Gemfile", "requirements.txt", "pyproject.toml", "index.html"].contains {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    private static func isScannableDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard isDirectory(url, fileManager: fileManager) else { return false }
        let skipped = [
            ".git", ".next", ".turbo", ".venv", "node_modules", "dist", "build",
            "DerivedData", "Pods", ".build", "coverage", "vendor"
        ]
        return !skipped.contains(url.lastPathComponent)
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func unique(_ candidates: [DevServerCommandCandidate]) -> [DevServerCommandCandidate] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            guard !seen.contains(candidate.id) else { return false }
            seen.insert(candidate.id)
            return true
        }
    }
}

private func devServerShellQuoted(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
}
