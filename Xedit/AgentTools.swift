//
//  AgentTools.swift
//  WillDeep
//
//  Built-in tools exposed to the project agent: search, read, list,
//  run command, and git status. Each tool declares a risk tier so the
//  AppState can decide whether to auto-allow, prompt, or require an
//  explicit confirm word before executing.
//

import Foundation
import Darwin

enum AgentProcessSupport {
    static func waitUntilExit(_ process: Process) async {
        let waiter = Waiter()
        process.terminationHandler = { _ in waiter.resume() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter.setContinuation(continuation)
            if !process.isRunning {
                waiter.resume()
            }
        }
        process.terminationHandler = nil
    }

    private nonisolated final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var didResume = false

        func setContinuation(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            if didResume {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func resume() {
            lock.lock()
            guard !didResume else {
                lock.unlock()
                return
            }
            didResume = true
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }
}

// MARK: - Tool runner

enum AgentToolRunner {
    static func run(
        name: String,
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        let resolution = resolvesSecretsForTool(name)
            ? AgentSecretStore.resolve(arguments)
            : AgentSecretResolution(value: .object(arguments), secretValues: [])
        let activeArguments: [String: AgentJSONValue]
        if case .object(let dict) = resolution.value {
            activeArguments = dict
        } else {
            activeArguments = arguments
        }
        let activeContext = context.withAdditionalSecretRedactionValues(resolution.secretValues)
        do {
            let result: AgentToolResult
            if AgentShortDramaToolDispatcher.canHandle(name) {
                result = try await AgentShortDramaToolDispatcher.run(
                    name: name,
                    arguments: activeArguments,
                    context: activeContext
                )
                return AgentSecretStore.redact(result, secretValues: activeContext.secretRedactionValues)
            }
            switch name {
            case "search_files":
                result = try await AgentFileTools.searchFiles(arguments: activeArguments, context: activeContext)
            case "grep_files":
                result = try await AgentFileTools.grepFiles(arguments: activeArguments, context: activeContext)
            case "read_file":
                result = try await AgentFileTools.readFile(arguments: activeArguments, context: activeContext)
            case "list_directory":
                result = try await AgentFileTools.listDirectory(arguments: activeArguments, context: activeContext)
            case "glob":
                // Compatibility alias for the `glob` tool some models hallucinate;
                // read-only workspace path scan. See AgentFileTools.glob.
                result = try await AgentFileTools.glob(arguments: activeArguments, context: activeContext)
            case "git_status":
                result = try await AgentFileTools.gitStatus(context: activeContext)
            case "run_command":
                result = try await runCommand(arguments: activeArguments, context: activeContext)
            case "terminal_list_shortcuts":
                result = try await AgentTerminalTools.listShortcuts(arguments: activeArguments, context: activeContext)
            case "terminal_create_shortcut":
                result = try await AgentTerminalTools.createShortcut(arguments: activeArguments, context: activeContext)
            case "terminal_edit_shortcut":
                result = try await AgentTerminalTools.editShortcut(arguments: activeArguments, context: activeContext)
            case "terminal_snapshot":
                result = try await AgentTerminalTools.snapshot(arguments: activeArguments, context: activeContext)
            case "terminal_send_command":
                result = try await AgentTerminalTools.sendCommand(arguments: activeArguments, context: activeContext)
            case "terminal_send_control":
                result = try await AgentTerminalTools.sendControl(arguments: activeArguments, context: activeContext)
            case "create_file":
                result = try await createFile(arguments: activeArguments, context: activeContext)
            case "edit_file":
                result = try await editFile(arguments: activeArguments, context: activeContext)
            case "apply_patch":
                result = try await applyPatch(arguments: activeArguments, context: activeContext)
            case "claude_code":
                result = try await claudeCode(arguments: activeArguments, context: activeContext)
            case "codex_cli":
                result = try await codexCLI(arguments: activeArguments, context: activeContext)
            case "cursor_agent":
                result = try await cursorAgent(arguments: activeArguments, context: activeContext)
            case "cline_cli":
                result = try await clineCLI(arguments: activeArguments, context: activeContext)
            case "lark_cli":
                result = try await larkCLI(arguments: activeArguments)
            case "list_jobs":
                result = try await listJobs(arguments: activeArguments, context: activeContext)
            case "get_job_output":
                result = try await getJobOutput(arguments: activeArguments, context: activeContext)
            case "kill_job":
                result = try await killJob(arguments: activeArguments, context: activeContext)
            case "list_skills":
                result = try AgentSkillCatalog.listSkills(arguments: activeArguments)
            case "read_skill":
                result = try AgentSkillCatalog.readSkill(arguments: activeArguments)
            case "add_memory":
                result = try AgentSelfLearning.addMemory(arguments: activeArguments, rootDirectory: activeContext.rootDirectory)
            case "create_user_skill":
                result = try AgentSelfLearning.createUserSkill(arguments: activeArguments)
            case "update_user_skill":
                result = try AgentConfigurationTools.updateUserSkill(arguments: activeArguments)
            case "delete_user_skill":
                result = try AgentConfigurationTools.deleteUserSkill(arguments: activeArguments)
            case "search_mcp_servers":
                result = try await AgentSelfLearning.searchMCPServers(arguments: activeArguments)
            case "suggest_mcp_server":
                result = try AgentSelfLearning.suggestMCPServer(arguments: activeArguments, rootDirectory: activeContext.rootDirectory)
            case "configure_mcp_server":
                result = try AgentConfigurationTools.configureMCPServer(arguments: activeArguments)
            case "web_search":
                result = try await AgentWebTools.webSearch(arguments: activeArguments)
            case "web_fetch":
                result = try await AgentWebTools.webFetch(arguments: activeArguments)
            case "create_media_task":
                result = try await AgentMediaTools.createMediaTask(arguments: activeArguments, context: activeContext)
            case "open_image_editor":
                result = try await AgentMediaTools.openImageEditor(arguments: activeArguments, context: activeContext)
            case "edit_image_with_mask":
                result = try await AgentMediaTools.editImageWithMask(arguments: activeArguments, context: activeContext)
            case "upscale_image":
                result = try await AgentMediaTools.upscaleImage(arguments: activeArguments, context: activeContext)
            case "generate_video_from_image":
                result = try await AgentMediaTools.generateVideoFromImage(arguments: activeArguments, context: activeContext)
            case "show_image_choice_widget":
                result = try await AgentMediaTools.showImageChoiceWidget(arguments: activeArguments, context: activeContext)
            case "import_media_directory":
                result = try await AgentMediaImportTools.importDirectory(arguments: activeArguments, context: activeContext)
            case "import_media_manifest":
                result = try await AgentMediaImportTools.importManifest(arguments: activeArguments, context: activeContext)
            case "update_media_task":
                result = try await AgentMediaTools.updateMediaTask(arguments: activeArguments, context: activeContext)
            case "list_media_tasks":
                result = try await AgentMediaTools.listMediaTasks(arguments: activeArguments, context: activeContext)
            case "replicate_create_prediction":
                result = try await AgentMediaTools.replicateCreatePrediction(arguments: activeArguments, context: activeContext)
            case "replicate_poll_prediction":
                result = try await AgentMediaTools.replicatePollPrediction(arguments: activeArguments, context: activeContext)
            case "replicate_cancel_prediction":
                result = try await AgentMediaTools.replicateCancelPrediction(arguments: activeArguments, context: activeContext)
            case "some_im_create_media_task":
                result = try await AgentMediaTools.someIMCreateMediaTask(arguments: activeArguments, context: activeContext)
            case "some_im_poll_media_task":
                result = try await AgentMediaTools.someIMPollMediaTask(arguments: activeArguments, context: activeContext)
            case "some_im_cancel_media_task":
                result = try await AgentMediaTools.someIMCancelMediaTask(arguments: activeArguments, context: activeContext)
            case "generate_image":
                result = try await generateImage(arguments: activeArguments)
            case "visual_qa_screenshot":
                result = try await AgentVisualQATools.analyzeScreenshot(arguments: activeArguments, context: activeContext)
            case "capture_screenshot":
                result = try await AgentCaptureTools.captureScreenshot(arguments: activeArguments, context: activeContext)
            case "chrome_status":
                result = try await AgentChromeTools.status(arguments: activeArguments)
            case "chrome_read_page":
                result = try await AgentChromeTools.readPage(arguments: activeArguments)
            case "chrome_read_selection":
                result = try await AgentChromeTools.readSelection(arguments: activeArguments)
            case "chrome_click":
                result = try await AgentChromeTools.click(arguments: activeArguments)
            case "chrome_type":
                result = try await AgentChromeTools.typeText(arguments: activeArguments)
            case "chrome_capture_tab":
                result = try await AgentChromeTools.captureTab(arguments: activeArguments)
            case "chrome_debugger_command":
                result = try await AgentChromeTools.debuggerCommand(arguments: activeArguments)
            case "embedded_browser_status":
                result = try await AgentEmbeddedBrowserTools.status(arguments: activeArguments)
            case "embedded_browser_navigate":
                result = try await AgentEmbeddedBrowserTools.navigate(arguments: activeArguments)
            case "embedded_browser_read_page":
                result = try await AgentEmbeddedBrowserTools.readPage(arguments: activeArguments)
            case "embedded_browser_snapshot":
                result = try await AgentEmbeddedBrowserTools.snapshot(arguments: activeArguments)
            case "embedded_browser_click":
                result = try await AgentEmbeddedBrowserTools.click(arguments: activeArguments)
            case "embedded_browser_type":
                result = try await AgentEmbeddedBrowserTools.typeText(arguments: activeArguments)
            case "embedded_browser_wait_for":
                result = try await AgentEmbeddedBrowserTools.waitFor(arguments: activeArguments)
            case "embedded_browser_eval":
                result = try await AgentEmbeddedBrowserTools.evaluate(arguments: activeArguments)
            case "embedded_browser_console":
                result = try await AgentEmbeddedBrowserTools.console(arguments: activeArguments)
            case "embedded_browser_network":
                result = try await AgentEmbeddedBrowserTools.network(arguments: activeArguments)
            case "embedded_browser_requests":
                result = try await AgentEmbeddedBrowserTools.requests(arguments: activeArguments)
            case "embedded_browser_export_har":
                result = try await AgentEmbeddedBrowserTools.exportHAR(arguments: activeArguments)
            case "embedded_browser_storage":
                result = try await AgentEmbeddedBrowserTools.storage(arguments: activeArguments)
            case "embedded_browser_performance":
                result = try await AgentEmbeddedBrowserTools.performance(arguments: activeArguments)
            case "embedded_browser_failed_resources":
                result = try await AgentEmbeddedBrowserTools.failedResources(arguments: activeArguments)
            case "embedded_browser_capture_screenshot":
                result = try await AgentEmbeddedBrowserTools.captureScreenshot(arguments: activeArguments)
            case "list_mcp_servers":
                result = try AgentMCPBridge.listServers()
            case "list_mcp_tools":
                result = try await AgentMCPBridge.listTools(arguments: activeArguments)
            case "call_mcp_tool":
                result = try await AgentMCPBridge.callTool(arguments: activeArguments)
            case "show_widget":
                result = try await showWidget(arguments: activeArguments, context: activeContext)
            case "run_workflow":
                result = try await runWorkflow(arguments: activeArguments, context: activeContext)
            default:
                throw AgentToolError.unknownTool(name)
            }
            return AgentSecretStore.redact(result, secretValues: activeContext.secretRedactionValues)
        } catch {
            throw redactedToolError(error, secretValues: activeContext.secretRedactionValues)
        }
    }

    private static func redactedToolError(_ error: Error, secretValues: [String]) -> Error {
        guard !secretValues.isEmpty else { return error }
        if let toolError = error as? AgentToolError {
            return toolError.redacted(secretValues: secretValues)
        }
        return AgentToolError.invalidArgument(
            AgentSecretStore.redact(error.localizedDescription, secretValues: secretValues)
        )
    }

    nonisolated static func resolvesSecretsForTool(_ toolName: String) -> Bool {
        switch toolName {
        case "run_command",
             "terminal_send_command",
             "lark_cli",
             "call_mcp_tool",
             "chrome_type",
             "embedded_browser_type",
             "embedded_browser_eval":
            return true
        default:
            return false
        }
    }

    // MARK: create_file

    /// Build the unified creation diff that `apply_patch` already knows how to
    /// parse and apply. Splitting on "\n" and prefixing each line with `+`
    /// round-trips exactly through `AgentPatchApplier.apply` (which, for a new
    /// file, joins the added lines back with "\n"), so the file lands byte-for
    /// -byte equal to `content`. Empty content → a single empty added line →
    /// an empty file.
    static func makeCreationDiff(path: String, content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        let body = lines.map { "+\($0)" }.joined(separator: "\n")
        let header = "--- /dev/null\n+++ b/\(path)\nnew file mode 100644\n@@ -0,0 +1,\(lines.count) @@"
        return body.isEmpty ? header : "\(header)\n\(body)"
    }

    /// Dedicated "create a new file" tool. Internally synthesizes a creation
    /// diff and reuses the `apply_patch` pipeline so the inline file card,
    /// worktree-change tracking, undo, and immediate-write semantics stay
    /// identical to how new files behaved when models hand-crafted the diff —
    /// the model just hands us a path + content instead of a unified diff.
    private static func createFile(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let rawPath = arguments["path"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            throw AgentToolError.missingArgument("path")
        }
        // `content` may legitimately be empty (empty file), so only the key's
        // absence — not an empty string — is an error.
        guard let content = arguments["content"]?.stringValue() else {
            throw AgentToolError.missingArgument("content")
        }
        // Strip an accidental leading `./`; apply_patch resolves the rest
        // workspace-relative and rejects paths outside the workspace.
        let path = rawPath.hasPrefix("./") ? String(rawPath.dropFirst(2)) : rawPath
        let diff = makeCreationDiff(path: path, content: content)

        let rawTitle = arguments["title"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (rawTitle?.isEmpty == false) ? rawTitle! : "创建文件: \(path)"
        // New files always write immediately — mirror the long-standing
        // new-file behavior of apply_patch.
        let patchArguments: [String: AgentJSONValue] = [
            "diff": .string(diff),
            "title": .string(title),
            "apply_immediately": .bool(true)
        ]
        return try await applyPatch(arguments: patchArguments, context: context)
    }

    // MARK: edit_file

    /// Claude-Code-style exact string replacement editor. The model passes
    /// (path, old_string, new_string) instead of hand-crafting a unified
    /// diff; the host matches old_string against the CURRENT file content
    /// (open tab buffer first, then disk), synthesizes a machine-accurate
    /// diff, and routes it through the apply_patch pipeline so the review
    /// card, auto-apply modes, undo, and worktree tracking stay identical.
    private static func editFile(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let rootDirectory = context.rootDirectory else {
            throw AgentToolError.noWorkspace
        }
        guard let rawPath = arguments["path"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            throw AgentToolError.missingArgument("path")
        }
        guard let oldString = arguments["old_string"]?.stringValue(), !oldString.isEmpty else {
            throw AgentToolError.missingArgument("old_string")
        }
        // `new_string` may legitimately be empty (pure deletion), so only the
        // key's absence — not an empty string — is an error.
        guard let newString = arguments["new_string"]?.stringValue() else {
            throw AgentToolError.missingArgument("new_string")
        }
        let replaceAll = arguments["replace_all"]?.boolValue() ?? false

        let path = rawPath.hasPrefix("./") ? String(rawPath.dropFirst(2)) : rawPath
        let root = rootDirectory.standardizedFileURL
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else {
            throw AgentToolError.pathOutsideWorkspace(path)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentToolError.notFound(path)
        }

        let currentContent: String
        if let provider = context.editableContentProvider {
            currentContent = try await provider(url)
        } else {
            currentContent = AppState.decodeText(from: try Data(contentsOf: url))
        }

        let edit = try AgentEditFileSupport.makeEdit(
            path: path,
            oldContent: currentContent,
            oldString: oldString,
            newString: newString,
            replaceAll: replaceAll
        )

        let rawTitle = arguments["title"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (rawTitle?.isEmpty == false) ? rawTitle! : "编辑文件: \(path)"
        var patchArguments: [String: AgentJSONValue] = [
            "diff": .string(edit.diff),
            "title": .string(title)
        ]
        if let applyImmediately = arguments["apply_immediately"]?.boolValue() {
            patchArguments["apply_immediately"] = .bool(applyImmediately)
        }
        let result = try await applyPatch(arguments: patchArguments, context: context)
        let occurrenceLine = edit.occurrences == 1
            ? "Replaced 1 occurrence of old_string in \(path)."
            : "Replaced \(edit.occurrences) occurrences of old_string in \(path)."
        return AgentToolResult(
            summary: result.summary,
            payload: "\(occurrenceLine)\n\n\(result.payload)",
            references: result.references
        )
    }

    // MARK: apply_patch

    private static func applyPatch(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let rootDirectory = context.rootDirectory else {
            throw AgentToolError.noWorkspace
        }
        guard let rawDiff = arguments["diff"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawDiff.isEmpty else {
            throw AgentToolError.missingArgument("diff")
        }
        guard let sink = context.patchProposalSink else {
            throw AgentToolError.invalidArgument("apply_patch is only available inside an interactive WillDeep agent session.")
        }

        let extractedBlocks = AgentPatchApplier.extractDiffBlocks(from: rawDiff)
        let diff = extractedBlocks.count == 1 ? extractedBlocks[0] : rawDiff
        let changes: [AgentPatchFileChange]
        do {
            changes = try AgentPatchApplier.parse(diff)
        } catch {
            throw AgentToolError.invalidArgument(error.localizedDescription)
        }

        let root = rootDirectory.standardizedFileURL
        let rootPath = root.path
        for change in changes {
            let url = root.appendingPathComponent(change.path).standardizedFileURL
            guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
                throw AgentToolError.pathOutsideWorkspace(change.path)
            }
            if change.isNewFile {
                // Creation diff: the file must NOT already exist (use a
                // modify diff to change an existing file).
                if FileManager.default.fileExists(atPath: url.path) {
                    throw AgentToolError.invalidArgument("apply_patch new-file diff targets a path that already exists: \(change.path). Use a normal modify diff instead.")
                }
            } else {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw AgentToolError.notFound(change.path)
                }
            }
        }

        let rawTitle = arguments["title"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle?.isEmpty == false ? rawTitle : nil
        // The model sets apply_immediately only when the user explicitly
        // asked to write / save directly without review.
        let applyImmediately = arguments["apply_immediately"]?.boolValue() ?? false
        let proposal = try await sink(title, diff, applyImmediately)
        let files = changes.map(\.path)
        let fileList = files.map { "- \($0)" }.joined(separator: "\n")
        let fileLabel = files.count == 1 ? "1 file" : "\(files.count) files"
        let statusLine: String
        switch proposal.status {
        case .applied:
            statusLine = "Patch status: applied. The existing patch applier wrote the changes to disk."
        case .failed:
            statusLine = "Patch status: failed\(proposal.statusMessage.map { ": \($0)" } ?? ".")"
        case .rejected:
            statusLine = "Patch status: rejected."
        case .pending:
            statusLine = "Patch status: pending. No files were modified; the user must click Apply on the patch card in the chat before this patch writes to disk."
        }

        let placementLine = proposal.status == .applied
            ? "Changes written to disk — no review was needed (new files and auto-apply modes write immediately)."
            : "A patch card is shown inline in the chat, right below your message — there is NO separate side / review panel. The user reviews and clicks Apply there. Do NOT tell the user to look in a right-side panel."

        return AgentToolResult(
            summary: proposal.status == .applied ? "patch applied: \(fileLabel)" : "patch queued: \(fileLabel)",
            payload: """
            \(placementLine)

            Patch ID: \(proposal.id.uuidString)
            Title: \(proposal.title)
            \(statusLine)
            Files:
            \(fileList)
            """
        )
    }

    private static func generateImage(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        guard let prompt = arguments["prompt"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            throw AgentToolError.missingArgument("prompt")
        }
        let rawSize = arguments["size"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let size = rawSize.isEmpty ? "1024x1024" : rawSize
        let rawModel = arguments["model"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = rawModel.isEmpty ? nil : rawModel
        let image = try await SomeIMClient.generateImage(prompt: prompt, size: size, model: model)
        return AgentToolResult(
            summary: "Generated image: \(image.fileURL.lastPathComponent)",
            payload: """
            Generated image with some.im model `\(image.model)`.

            Local file:
            \(image.fileURL.path)
            """
        )
    }

    // MARK: run_command

    nonisolated private static let defaultCommandTimeout: TimeInterval = 20
    nonisolated private static let maxCommandTimeout: TimeInterval = 120
    nonisolated private static let maxCommandOutput = 32 * 1024
    nonisolated static let supplementalCommandPathEntries = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    nonisolated static func shellEnvironment(from base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        var pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for entry in supplementalCommandPathEntries where !pathEntries.contains(entry) {
            pathEntries.append(entry)
        }
        environment["PATH"] = pathEntries.joined(separator: ":")
        return environment
    }

    private static func runCommand(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext,
        foregroundMaxTimeout: TimeInterval = maxCommandTimeout
    ) async throws -> AgentToolResult {
        if let backend = context.remoteBackend {
            return try await backend.runCommand(
                arguments: arguments,
                context: context,
                foregroundMaxTimeout: foregroundMaxTimeout
            )
        }
        let root = context.rootDirectory?.standardizedFileURL
            ?? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard let command = arguments["command"]?.stringValue(),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.missingArgument("command")
        }
        let timeoutArg = arguments["timeout_seconds"]?.intValue().map { Double($0) } ?? defaultCommandTimeout
        let timeout = min(max(timeoutArg, 1), max(1, foregroundMaxTimeout))

        // Background path: hand the Process off to the registry, return
        // immediately with the job handle, let the agent loop pull the
        // completion event at the top of a later turn.
        let wantsBackground = arguments["run_in_background"]?.boolValue() ?? false
        if wantsBackground, let registry = context.jobRegistry, let runtimeID = context.runtimeID {
            let bgTimeout: Double? = arguments["timeout_seconds"]?.intValue().map { Double(min(max($0, 1), 3600 * 6)) }
            let job: AgentBackgroundJob
            do {
                job = try await MainActor.run {
                    try registry.start(
                        command: command,
                        workingDirectory: root,
                        runtimeID: runtimeID,
                        timeoutSeconds: bgTimeout,
                        sandboxMode: context.sandboxMode,
                        displayCommand: AgentSecretStore.redact(command, secretValues: context.secretRedactionValues),
                        secretRedactionValues: context.secretRedactionValues
                    )
                }
            } catch {
                throw AgentToolError.commandFailed(
                    -1,
                    AgentSecretStore.redact(error.localizedDescription, secretValues: context.secretRedactionValues)
                )
            }
            let cwd = job.workingDirectoryPath ?? root.path
            let timeoutLine = bgTimeout.map { "\nTimeout: \(Int($0))s" } ?? ""
            let payload = """
            Started background job \(job.displayHandle).
            Command: \(AgentSecretStore.redact(command, secretValues: context.secretRedactionValues))
            PID: \(job.pid)
            cwd: \(cwd)\(timeoutLine)

            The job is running. You will receive a `<background-task-notification>` system message at the start of a later turn when it finishes (or fails). Until then, call `get_job_output` to inspect partial output, `list_jobs` to see all alive jobs, or `kill_job` to stop it.
            """
            return AgentToolResult(
                summary: "▶ \(job.displayHandle) started",
                payload: payload
            )
        }

        let outcome = await Task.detached(priority: .userInitiated) { () -> CommandOutcome in
            let process = Process()
            let launch = AgentSandboxPolicy.shellLaunch(
                command: command,
                mode: context.sandboxMode,
                rootDirectory: context.rootDirectory
            )
            process.executableURL = launch.executableURL
            process.arguments = launch.arguments
            process.currentDirectoryURL = root
            let baseEnvironment = shellEnvironment()
            var environment = AgentSandboxPolicy.sandboxedEnvironment(
                mode: context.sandboxMode,
                rootDirectory: context.rootDirectory,
                base: baseEnvironment
            )
            // `shellEnvironment()` 复制宿主进程的环境,里面带着宿主的
            // `$PWD`。`sh`/`bash` 的 `pwd` builtin 信任 `$PWD`,于是即便
            // 我们已经 chdir 到 `root`,`pwd` 仍会打印宿主那个陈旧的目
            // 录(CI 上就是 runner 的工作目录,本地恰好可能一致所以测
            // 不出来)。把 `$PWD` 同步成真实 cwd,`pwd` 才反映实际工作
            // 目录 —— 也修掉 testRunCommandUsesHomeDirectoryWithoutWorkspace。
            environment["PWD"] = root.path
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            closeStandardInput(for: process)
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            let outputLimit = maxCommandOutput
            let stdoutCollector = CommandOutputCollector(limit: outputLimit)
            let stderrCollector = CommandOutputCollector(limit: outputLimit)
            let runState = CommandRunState()
            let stdoutDrain = Task.detached(priority: .utility) {
                stdoutCollector.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            }
            let stderrDrain = Task.detached(priority: .utility) {
                stderrCollector.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
            do {
                try process.run()
            } catch {
                try? stdoutPipe.fileHandleForReading.close()
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForWriting.close()
                await stdoutDrain.value
                await stderrDrain.value
                return CommandOutcome(
                    exitStatus: -1,
                    stdout: "",
                    stderr: AgentSecretStore.redact(error.localizedDescription, secretValues: context.secretRedactionValues),
                    timedOut: false,
                    launchFailed: true
                )
            }

            let timeoutWorkItem = DispatchWorkItem {
                runState.markTimedOut()
                if process.isRunning {
                    process.terminate()
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            await AgentProcessSupport.waitUntilExit(process)
            timeoutWorkItem.cancel()
            await stdoutDrain.value
            await stderrDrain.value

            return CommandOutcome(
                exitStatus: process.terminationStatus,
                stdout: AgentSecretStore.redact(
                    AgentSandboxPolicy.scrub(stdoutCollector.stringValue),
                    secretValues: context.secretRedactionValues
                ),
                stderr: AgentSecretStore.redact(
                    AgentSandboxPolicy.scrub(stderrCollector.stringValue),
                    secretValues: context.secretRedactionValues
                ),
                timedOut: runState.didTimeout,
                launchFailed: false
            )
        }.value

        if outcome.launchFailed {
            throw AgentToolError.commandFailed(-1, outcome.stderr)
        }
        if outcome.timedOut {
            throw AgentToolError.commandTimeout
        }
        let stdout = outcome.stdout
        let stderr = outcome.stderr
        let status = outcome.exitStatus

        let combined = "exit=\(status)\n--- stdout ---\n\(stdout)\n--- stderr ---\n\(stderr)"
        let trimmed: String
        if combined.count > maxCommandOutput {
            trimmed = trimDelegatedCommandPayload(combined, maxCharacters: maxCommandOutput)
        } else {
            trimmed = combined
        }

        if status != 0 {
            throw AgentToolError.commandFailed(status, trimmed)
        }

        let firstLine = stdout.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let summary = "exit 0\(firstLine.isEmpty ? "" : ": " + firstLine.prefix(60))"
        return AgentToolResult(summary: summary, payload: trimmed)
    }

    nonisolated static func closeStandardInput(for process: Process) {
        let stdinPipe = Pipe()
        stdinPipe.fileHandleForWriting.closeFile()
        process.standardInput = stdinPipe
    }

    nonisolated static func trimDelegatedCommandPayload(_ raw: String, maxCharacters: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters, maxCharacters > 400 else { return trimmed }
        let headCount = max(200, maxCharacters / 5)
        let tailCount = maxCharacters - headCount - 96
        let headEnd = trimmed.index(trimmed.startIndex, offsetBy: headCount)
        let tailStart = trimmed.index(trimmed.endIndex, offsetBy: -tailCount)
        return """
        \(trimmed[..<headEnd])

        [...middle output truncated; showing final diagnostics below...]

        \(trimmed[tailStart...])
        """
    }

    // MARK: claude_code

    /// Permission modes we forward to `claude -p`. Deliberately NOT
    /// including `bypassPermissions` — headless full-bypass from a
    /// model-initiated tool call is an instruction-injection foot-gun.
    nonisolated static let claudeCodePermissionModes: Set<String> = ["plan", "acceptEdits", "default"]

    /// Locate the Claude Code CLI. Checks the native-installer location
    /// (`~/.local/bin`) and the legacy alias first, then every PATH
    /// entry from the augmented shell environment. Returns an absolute
    /// path so the composed command doesn't depend on PATH at run time.
    nonisolated static func claudeCodeExecutablePath(
        environment: [String: String] = shellEnvironment(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let home = NSHomeDirectory()
        var candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        for entry in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(entry)/claude")
        }
        return candidates.first(where: isExecutable)
    }

    /// POSIX single-quote escaping: safe to embed arbitrary text
    /// (including the task prompt) into a `/bin/sh -c` command line.
    nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func claudeCodeCommandLine(
        executable: String,
        prompt: String,
        permissionMode: String,
        model: String?
    ) -> String {
        var parts = [
            shellQuoted(executable),
            "-p", shellQuoted(prompt),
            "--output-format", "text",
            "--permission-mode", permissionMode,
        ]
        if let model, !model.isEmpty {
            parts += ["--model", shellQuoted(model)]
        }
        return parts.joined(separator: " ")
    }

    /// Delegate a task to the Claude Code CLI in headless mode. Thin
    /// composer over `runCommand`: builds the `claude -p …` command
    /// line, then rides the exact same foreground/background plumbing
    /// (job registry, output buffers, kill, completion notifications).
    private static func claudeCode(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let prompt = arguments["prompt"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            throw AgentToolError.missingArgument("prompt")
        }

        let permissionMode = arguments["permission_mode"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "acceptEdits"
        guard claudeCodePermissionModes.contains(permissionMode) else {
            throw AgentToolError.invalidArgument(
                "permission_mode must be one of: \(claudeCodePermissionModes.sorted().joined(separator: ", "))"
            )
        }

        let executable: String
        if context.remoteBackend != nil {
            executable = "claude"
        } else if let localExecutable = claudeCodeExecutablePath() {
            executable = localExecutable
        } else {
            throw AgentToolError.commandFailed(
                127,
                "Claude Code CLI not found on this Mac. Install it first (e.g. `npm install -g @anthropic-ai/claude-code` or the native installer from https://claude.com/claude-code), then retry. Tell the user instead of retrying blindly."
            )
        }

        let command = claudeCodeCommandLine(
            executable: executable,
            prompt: prompt,
            permissionMode: permissionMode,
            model: arguments["model"]?.stringValue()
        )

        // Claude Code tasks routinely run for minutes. Agent-initiated
        // calls still default to background jobs, but Composer can force
        // foreground and wait for the final response without inheriting
        // the ordinary 120s shell-command ceiling.
        var forwarded = delegatedAgentForwardedCommandArguments(
            command: command,
            sourceArguments: arguments
        )
        if context.daemonBackend != nil, forwarded["timeout_seconds"] == nil {
            forwarded["timeout_seconds"] = .number(delegatedAgentForegroundTimeout)
        }
        return try await runCommand(
            arguments: forwarded,
            context: context,
            foregroundMaxTimeout: delegatedAgentForegroundTimeout
        )
    }

    // MARK: codex_cli / cursor_agent / cline_cli

    nonisolated static let delegatedAgentForegroundTimeout: TimeInterval = 3600 * 6
    nonisolated static let codexCLIPermissionModes: Set<String> = ["plan", "workspaceWrite", "default"]
    nonisolated static let cursorAgentPermissionModes: Set<String> = ["plan", "ask", "default"]
    nonisolated static let clineCLIPermissionModes: Set<String> = ["plan", "act", "default"]

    nonisolated static func delegatedAgentForwardedCommandArguments(
        command: String,
        sourceArguments arguments: [String: AgentJSONValue]
    ) -> [String: AgentJSONValue] {
        let runInBackground = arguments["run_in_background"]?.boolValue() ?? true
        var forwarded: [String: AgentJSONValue] = [
            "command": .string(command),
            "run_in_background": .bool(runInBackground),
        ]
        if let timeout = arguments["timeout_seconds"]?.intValue() {
            forwarded["timeout_seconds"] = .number(Double(timeout))
        } else if !runInBackground {
            forwarded["timeout_seconds"] = .number(delegatedAgentForegroundTimeout)
        }
        return forwarded
    }

    nonisolated static func codexCLIExecutablePath(
        environment: [String: String] = shellEnvironment(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        executablePath(commandName: "codex", preferredPaths: [
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
        ], environment: environment, isExecutable: isExecutable)
    }

    nonisolated static func cursorAgentExecutablePath(
        environment: [String: String] = shellEnvironment(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        executablePath(commandName: "cursor", preferredPaths: [
            "/usr/local/bin/cursor",
            "/opt/homebrew/bin/cursor",
        ], environment: environment, isExecutable: isExecutable)
    }

    nonisolated static func clineCLIExecutablePath(
        environment: [String: String] = shellEnvironment(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        executablePath(commandName: "cline", preferredPaths: [
            "\(NSHomeDirectory())/.local/bin/cline",
        ], environment: environment, isExecutable: isExecutable)
    }

    nonisolated static func executablePath(
        commandName: String,
        preferredPaths: [String],
        environment: [String: String],
        isExecutable: (String) -> Bool
    ) -> String? {
        var seen = Set<String>()
        var candidates: [String] = []

        func append(_ path: String) {
            guard !seen.contains(path) else { return }
            seen.insert(path)
            candidates.append(path)
        }

        preferredPaths.forEach(append)
        for entry in (environment["PATH"] ?? "").split(separator: ":").map(String.init) {
            append("\(entry)/\(commandName)")
        }
        return candidates.first(where: isExecutable)
    }

    nonisolated static func codexCLICommandLine(
        executable: String,
        prompt: String,
        permissionMode: String,
        model: String?,
        workspacePath: String?
    ) -> String {
        let sandbox = permissionMode == "plan" ? "read-only" : "workspace-write"
        var parts = [
            shellQuoted(executable),
            "-a", "never",
            "exec",
            "--color", "never",
            "--skip-git-repo-check",
            "--sandbox", sandbox,
        ]
        if let workspacePath, !workspacePath.isEmpty {
            parts += ["--cd", shellQuoted(workspacePath)]
        }
        if let model, !model.isEmpty {
            parts += ["--model", shellQuoted(model)]
        }
        parts.append(shellQuoted(prompt))
        return parts.joined(separator: " ")
    }

    nonisolated static func cursorAgentCommandLine(
        executable: String,
        prompt: String,
        permissionMode: String,
        model: String?,
        workspacePath: String?
    ) -> String {
        var parts = [
            shellQuoted(executable),
            "agent",
            "--print",
            "--output-format", "text",
            "--sandbox", "enabled",
            "--trust",
        ]
        switch permissionMode {
        case "plan":
            parts += ["--mode", "plan"]
        case "ask":
            parts += ["--mode", "ask"]
        default:
            break
        }
        if let workspacePath, !workspacePath.isEmpty {
            parts += ["--workspace", shellQuoted(workspacePath)]
        }
        if let model, !model.isEmpty {
            parts += ["--model", shellQuoted(model)]
        }
        parts.append(shellQuoted(prompt))
        return parts.joined(separator: " ")
    }

    nonisolated static func clineCLICommandLine(
        executable: String,
        prompt: String,
        permissionMode: String,
        model: String?,
        workspacePath: String?
    ) -> String {
        var parts = [
            shellQuoted(executable),
            "--json",
        ]
        if permissionMode == "plan" {
            parts.append("--plan")
        }
        if let workspacePath, !workspacePath.isEmpty {
            parts += ["--cwd", shellQuoted(workspacePath)]
        }
        if let model, !model.isEmpty {
            parts += ["--model", shellQuoted(model)]
        }
        parts.append(shellQuoted(prompt))
        return parts.joined(separator: " ")
    }

    private static func codexCLI(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        let prompt = try delegatedAgentPrompt(arguments: arguments)
        let permissionMode = arguments["permission_mode"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "workspaceWrite"
        guard codexCLIPermissionModes.contains(permissionMode) else {
            throw AgentToolError.invalidArgument(
                "permission_mode must be one of: \(codexCLIPermissionModes.sorted().joined(separator: ", "))"
            )
        }
        let executable: String
        if context.remoteBackend != nil {
            executable = "codex"
        } else if let localExecutable = codexCLIExecutablePath() {
            executable = localExecutable
        } else {
            throw AgentToolError.commandFailed(
                127,
                "Codex CLI not found on this Mac. Install Codex CLI or the Codex desktop app, then retry. Tell the user instead of retrying blindly."
            )
        }
        let command = codexCLICommandLine(
            executable: executable,
            prompt: prompt,
            permissionMode: permissionMode,
            model: arguments["model"]?.stringValue(),
            workspacePath: context.workspaceLocation?.path ?? context.rootDirectory?.standardizedFileURL.path
        )
        return try await runDelegatedAgentCommand(command, arguments: arguments, context: context)
    }

    private static func cursorAgent(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        let prompt = try delegatedAgentPrompt(arguments: arguments)
        let permissionMode = arguments["permission_mode"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "default"
        guard cursorAgentPermissionModes.contains(permissionMode) else {
            throw AgentToolError.invalidArgument(
                "permission_mode must be one of: \(cursorAgentPermissionModes.sorted().joined(separator: ", "))"
            )
        }
        let executable: String
        if context.remoteBackend != nil {
            executable = "cursor"
        } else if let localExecutable = cursorAgentExecutablePath() {
            executable = localExecutable
        } else {
            throw AgentToolError.commandFailed(
                127,
                "Cursor Agent CLI not found on this Mac. Install Cursor and its command line launcher first, then retry. Tell the user instead of retrying blindly."
            )
        }
        let command = cursorAgentCommandLine(
            executable: executable,
            prompt: prompt,
            permissionMode: permissionMode,
            model: arguments["model"]?.stringValue(),
            workspacePath: context.workspaceLocation?.path ?? context.rootDirectory?.standardizedFileURL.path
        )
        return try await runDelegatedAgentCommand(command, arguments: arguments, context: context)
    }

    private static func clineCLI(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        let prompt = try delegatedAgentPrompt(arguments: arguments)
        let permissionMode = arguments["permission_mode"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "act"
        guard clineCLIPermissionModes.contains(permissionMode) else {
            throw AgentToolError.invalidArgument(
                "permission_mode must be one of: \(clineCLIPermissionModes.sorted().joined(separator: ", "))"
            )
        }
        let executable: String
        if context.remoteBackend != nil {
            executable = "cline"
        } else if let localExecutable = clineCLIExecutablePath() {
            executable = localExecutable
        } else {
            throw AgentToolError.commandFailed(
                127,
                "Cline CLI not found on this Mac. Install it first with `npm install -g cline`, then retry. Tell the user instead of retrying blindly."
            )
        }
        let normalizedMode = permissionMode == "default" ? "act" : permissionMode
        let command = clineCLICommandLine(
            executable: executable,
            prompt: prompt,
            permissionMode: normalizedMode,
            model: arguments["model"]?.stringValue(),
            workspacePath: context.workspaceLocation?.path ?? context.rootDirectory?.standardizedFileURL.path
        )
        return try await runDelegatedAgentCommand(command, arguments: arguments, context: context)
    }

    private static func delegatedAgentPrompt(arguments: [String: AgentJSONValue]) throws -> String {
        guard let prompt = arguments["prompt"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            throw AgentToolError.missingArgument("prompt")
        }
        return prompt
    }

    private static func runDelegatedAgentCommand(
        _ command: String,
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        var forwarded = delegatedAgentForwardedCommandArguments(
            command: command,
            sourceArguments: arguments
        )
        if context.daemonBackend != nil, forwarded["timeout_seconds"] == nil {
            forwarded["timeout_seconds"] = .number(delegatedAgentForegroundTimeout)
        }
        return try await runCommand(
            arguments: forwarded,
            context: context,
            foregroundMaxTimeout: delegatedAgentForegroundTimeout
        )
    }

    // MARK: list_jobs / get_job_output / kill_job

    // MARK: lark_cli

    private static func larkCLI(
        arguments: [String: AgentJSONValue]
    ) async throws -> AgentToolResult {
        guard let cliArguments = arguments["arguments"]?.stringArrayValue() else {
            throw AgentToolError.missingArgument("arguments")
        }
        let normalized = AgentLarkCLI.normalizedArguments(cliArguments)
        guard !normalized.isEmpty else {
            throw AgentToolError.invalidArgument("arguments must include at least one lark-cli subcommand.")
        }
        return try await AgentLarkCLI.run(
            arguments: normalized,
            timeoutSeconds: arguments["timeout_seconds"]?.intValue()
        )
    }

    /// Snapshot of background jobs for the current runtime. Returns a
    /// stable text format (one job per line) so the model can quote
    /// handles back into `get_job_output` / `kill_job` without parsing
    /// JSON.
    private static func listJobs(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        if let daemonBackend = context.daemonBackend {
            return try await daemonBackend.listJobs()
        }
        guard let registry = context.jobRegistry, let runtimeID = context.runtimeID else {
            return AgentToolResult(summary: "no jobs", payload: "Background job registry not available in this context.")
        }
        let onlyAlive = arguments["only_alive"]?.boolValue() ?? false
        let allJobs = await MainActor.run { registry.jobs(forRuntime: runtimeID) }
        let filtered = onlyAlive ? allJobs.filter { $0.isAlive } : allJobs
        guard !filtered.isEmpty else {
            return AgentToolResult(
                summary: "no jobs",
                payload: onlyAlive ? "No alive background jobs." : "No background jobs in this session."
            )
        }
        let lines = filtered.map { describe(job: $0) }
        let payload = lines.joined(separator: "\n")
        let aliveCount = filtered.filter { $0.isAlive }.count
        let summary = "\(filtered.count) job\(filtered.count == 1 ? "" : "s") (\(aliveCount) alive)"
        return AgentToolResult(summary: summary, payload: payload)
    }

    private static func getJobOutput(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        if let daemonBackend = context.daemonBackend {
            return try await daemonBackend.getJobOutput(arguments: arguments)
        }
        guard let registry = context.jobRegistry, let runtimeID = context.runtimeID else {
            throw AgentToolError.invalidArgument("Background job registry not available.")
        }
        guard let handle = arguments["job_id"]?.stringValue(),
              !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.missingArgument("job_id")
        }
        let tailLines = arguments["tail_lines"]?.intValue()
        let snapshot: (job: AgentBackgroundJob, output: String)? = await MainActor.run {
            guard let job = registry.job(matchingHandle: handle, runtimeID: runtimeID) else { return nil }
            return (job, registry.output(id: job.id, tailLines: tailLines))
        }
        guard let snapshot else {
            throw AgentJobError.jobNotFound(handle)
        }
        let header = describe(job: snapshot.job)
        let body = snapshot.output.isEmpty ? "(no output captured yet)" : snapshot.output
        return AgentToolResult(
            summary: "\(snapshot.job.displayHandle): \(snapshot.job.status.rawValue)",
            payload: "\(header)\n--- output ---\n\(body)"
        )
    }

    private static func killJob(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        if let daemonBackend = context.daemonBackend {
            return try await daemonBackend.killJob(arguments: arguments)
        }
        guard let registry = context.jobRegistry, let runtimeID = context.runtimeID else {
            throw AgentToolError.invalidArgument("Background job registry not available.")
        }
        guard let handle = arguments["job_id"]?.stringValue(),
              !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.missingArgument("job_id")
        }
        let result: (job: AgentBackgroundJob, didSignal: Bool)? = await MainActor.run {
            guard let job = registry.job(matchingHandle: handle, runtimeID: runtimeID) else { return nil }
            let signaled = registry.kill(id: job.id)
            return (job, signaled)
        }
        guard let result else {
            throw AgentJobError.jobNotFound(handle)
        }
        if result.didSignal {
            return AgentToolResult(
                summary: "\(result.job.displayHandle) killed",
                payload: "Sent SIGTERM to \(result.job.displayHandle) (pid \(result.job.pid)). A completion notice will arrive on the next turn."
            )
        } else {
            return AgentToolResult(
                summary: "\(result.job.displayHandle) not running",
                payload: "\(result.job.displayHandle) was already \(result.job.status.rawValue); nothing to kill."
            )
        }
    }

    private static func describe(job: AgentBackgroundJob) -> String {
        let exit = job.exitCode.map { "exit=\($0)" } ?? "exit=…"
        let durationText = formatDuration(job.duration)
        let trimmedCommand = job.command.count > 100
            ? String(job.command.prefix(100)) + "…"
            : job.command
        return "\(job.displayHandle) [\(job.status.rawValue)] \(exit) · \(durationText) · pid=\(job.pid) · \(trimmedCommand)"
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let m = total / 60
        let s = total % 60
        if m < 60 { return "\(m)m\(s)s" }
        let h = m / 60
        let mm = m % 60
        return "\(h)h\(mm)m"
    }

    // MARK: helpers

    private struct CommandOutcome: Sendable {
        let exitStatus: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
        let launchFailed: Bool
    }

    private nonisolated final class CommandOutputCollector: @unchecked Sendable {
        private let limit: Int
        private var data = Data()
        private var truncated = false
        private let lock = NSLock()

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }

            let remaining = max(0, limit - data.count)
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
            if chunk.count > remaining {
                truncated = true
            }
        }

        var stringValue: String {
            lock.lock()
            let snapshot = data
            let didTruncate = truncated
            lock.unlock()

            var text = String(data: snapshot, encoding: .utf8) ?? AppState.decodeText(from: snapshot)
            if didTruncate {
                text += "\n...[truncated]"
            }
            return text
        }
    }

    private nonisolated final class CommandRunState: @unchecked Sendable {
        private let lock = NSLock()
        private var timedOut = false

        func markTimedOut() {
            lock.lock()
            timedOut = true
            lock.unlock()
        }

        var didTimeout: Bool {
            lock.lock()
            let value = timedOut
            lock.unlock()
            return value
        }
    }

    // MARK: show_widget (1.84.0-rc1)

    // Widget HTML path boundary moved to AgentWidgetPathResolver.swift:
    // widgetTemporaryDirectories()
    // FileManager.default.temporaryDirectory
    // URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    // shortDramaExportsDirectory
    // WillDeep/short-drama/exports
    // isWidgetHTMLURLAllowed

    /// `show_widget` 工具 handler。把模型生成或本地脚本写出的 HTML 推到
    /// `AgentWidgetRegistry`，由 AppStateAgentLoop 在下一轮 turn 顶部
    /// drain 出来 append `.widget` 消息到 transcript。返回值只是 ack
    /// 字符串（"widget queued"），所以 LLM 不会看到 raw HTML 占用上下文。
    /// `html_path` 只允许读取当前 workspace、系统临时目录或 WillDeep
    /// 短剧导出目录内的 UTF-8 文件，供 Ruby skill 或第三方 API 脚本把
    /// 生成的网页直接嵌入右侧「网页组件」。
    private static func showWidget(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let title = arguments["title"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            throw AgentToolError.missingArgument("title")
        }
        guard let runtimeID = context.runtimeID else {
            return AgentToolResult(
                summary: "show_widget unavailable",
                payload: "show_widget is only available in conversational agent runtimes (no runtime id in this call context)."
            )
        }
        let html = try widgetHTML(arguments: arguments, context: context)
        let contextLines = try widgetContextLines(arguments: arguments)
        let bytes = html.utf8.count
        if bytes > 1_048_576 {
            return AgentToolResult(
                summary: "Refused (>1 MB)",
                payload: "show_widget refused: html payload is \(bytes) bytes (>1 MB). Trim it down or split into multiple widgets."
            )
        }
        let widget = AgentWidget(title: title, html: html, contextLines: contextLines)
        await MainActor.run {
            AgentWidgetRegistry.shared.add(widget, forRuntime: runtimeID)
            EditorAppStateRegistry.shared.appState(forRuntime: runtimeID)?.agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .widget)
        }
        let kbLabel = bytes >= 1024 ? "\(bytes / 1024) KB" : "\(bytes) B"
        return AgentToolResult(
            summary: "Queued widget: \(title)",
            payload: """
            widget queued: "\(title)" (\(kbLabel)) — opened the Widget side panel and will appear in the transcript at the start of the next turn.
            <widget-follow-up>
            action: show_widget_follow_up
            widget_id: \(widget.id.uuidString)
            title: \(title)
            side_panel: widget
            source: \(arguments["html_path"]?.stringValue() == nil ? "inline_html" : "html_path")
            \(widget.contextBlock)
            </widget-follow-up>
            """
        )
    }

    private static func widgetContextLines(arguments: [String: AgentJSONValue]) throws -> [String] {
        let mappings: [(String, String)] = [
            ("html_path", "html_path"),
            ("source_label", "source_label"),
            ("source_path", "source_path"),
            ("package_directory", "package_directory"),
            ("widget_context", "widget_context"),
            ("recommended_tool", "recommended_tool"),
            ("recommended_arguments", "recommended_arguments"),
            ("project_id", "project_id"),
            ("episode_id", "episode_id"),
            ("shot_id", "shot_id"),
            ("asset_kind", "asset_kind"),
            ("asset_id", "asset_id"),
            ("review_item_id", "review_item_id")
        ]
        var lines: [String] = []
        for (argumentName, lineName) in mappings {
            guard let value = arguments[argumentName]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            guard value.utf8.count <= 2_000 else {
                throw AgentToolError.invalidArgument("\(argumentName) must be 2 KB or smaller.")
            }
            lines.append("\(lineName): \(value)")
        }
        lines.append(contentsOf: widgetShortDramaHandoffLines(arguments: arguments))
        if lines.joined(separator: "\n").utf8.count > 8_000 {
            throw AgentToolError.invalidArgument("show_widget context metadata must be 8 KB or smaller.")
        }
        return lines
    }

    private static func widgetShortDramaHandoffLines(arguments: [String: AgentJSONValue]) -> [String] {
        let projectID = widgetContextValue(arguments, "project_id")
        let episodeID = widgetContextValue(arguments, "episode_id")
        let shotID = widgetContextValue(arguments, "shot_id")
        let assetKind = widgetContextValue(arguments, "asset_kind")
        let assetID = widgetContextValue(arguments, "asset_id")
        let reviewItemID = widgetContextValue(arguments, "review_item_id")
        guard projectID != nil else { return [] }

        var lines: [String] = []
        if let projectID, let shotID {
            var pairs = ["project_id=\(projectID)"]
            if let episodeID { pairs.append("episode_id=\(episodeID)") }
            pairs.append("shot_id=\(shotID)")
            var scopeArguments = pairs.joined(separator: ", ")
            if let reviewItemID {
                scopeArguments += ", scope=review_item, review_item_id=\(reviewItemID)"
            } else {
                scopeArguments += ", scope=shot"
            }
            lines.append("open_widget_tasks_tool: short_drama_open_media_tasks")
            lines.append("open_widget_tasks_arguments: \(scopeArguments)")
            lines.append("refresh_widget_tasks_tool: short_drama_refresh_media_tasks")
            lines.append("refresh_widget_tasks_arguments: \(scopeArguments)")
            if let reviewItemID {
                let resolveArguments = (pairs + ["item_id=\(reviewItemID)"]).joined(separator: ", ")
                lines.append("resolve_widget_review_tool: short_drama_resolve_review_item")
                lines.append("resolve_widget_review_arguments: \(resolveArguments)")
            }
            return lines
        }

        if let projectID, let assetKind, let assetID {
            let arguments = "project_id=\(projectID), scope=asset, asset_kind=\(assetKind), asset_id=\(assetID)"
            lines.append("open_widget_tasks_tool: short_drama_open_media_tasks")
            lines.append("open_widget_tasks_arguments: \(arguments)")
            lines.append("refresh_widget_tasks_tool: short_drama_refresh_media_tasks")
            lines.append("refresh_widget_tasks_arguments: \(arguments)")
            return lines
        }

        if let projectID {
            var pairs = ["project_id=\(projectID)"]
            if let episodeID { pairs.append("episode_id=\(episodeID)") }
            pairs.append("scope=\(episodeID == nil ? "project" : "episode")")
            let arguments = pairs.joined(separator: ", ")
            lines.append("open_widget_tasks_tool: short_drama_open_media_tasks")
            lines.append("open_widget_tasks_arguments: \(arguments)")
            lines.append("refresh_widget_tasks_tool: short_drama_refresh_media_tasks")
            lines.append("refresh_widget_tasks_arguments: \(arguments)")
        }
        return lines
    }

    private static func widgetContextValue(_ arguments: [String: AgentJSONValue], _ key: String) -> String? {
        guard let value = arguments[key]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func widgetHTML(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) throws -> String {
        if let html = arguments["html"]?.stringValue(), !html.isEmpty {
            return html
        }
        guard let rawPath = arguments["html_path"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            throw AgentToolError.missingArgument("html")
        }
        let url = try resolveWidgetHTMLURL(rawPath, context: context)
        let path = url.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw AgentToolError.notFound(rawPath)
        }
        guard !isDirectory.boolValue else {
            throw AgentToolError.notRegular(rawPath)
        }
        guard ["html", "htm", "svg"].contains(url.pathExtension.lowercased()) else {
            throw AgentToolError.invalidArgument("html_path must point to a .html, .htm, or .svg file.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else {
            return String(decoding: data.prefix(1_048_577), as: UTF8.self)
        }
        guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
            throw AgentToolError.invalidArgument("html_path must contain non-empty UTF-8 HTML/SVG.")
        }
        return html
    }

    private static func resolveWidgetHTMLURL(_ rawPath: String, context: AgentToolContext) throws -> URL {
        let trimmed = AgentWidgetPathResolver.normalize(rawPath)
        let workspaceRoot = context.rootDirectory?.standardizedFileURL
        if !(trimmed as NSString).isAbsolutePath, workspaceRoot == nil {
            throw AgentToolError.noWorkspace
        }
        if let url = AgentWidgetPathResolver.resolve(trimmed, workspaceRoot: workspaceRoot) {
            return url
        }
        throw AgentToolError.pathOutsideWorkspace(rawPath)
    }

    // MARK: run_workflow (1.84.0-rc2)

    /// Agent 自己派 workflow（无需用户 slash 命令）。handler 通过
    /// `AppState.startWorkflow` 走和 composer slash 同款入口 ——
    /// AppState 创建 .workflowReport message + 起后台 Task 跑
    /// WorkflowEngine。本工具返回简短 ack；后续 turn 顶部 LLM 自然能在
    /// transcript 里读到 workflow card 的 summary。
    private static func runWorkflow(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let name = arguments["workflow_name"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            throw AgentToolError.missingArgument("workflow_name")
        }
        guard let runtimeID = context.runtimeID else {
            return AgentToolResult(
                summary: "run_workflow unavailable",
                payload: "run_workflow is only available in conversational agent runtimes."
            )
        }
        let normalizedName = name.hasPrefix("/") ? String(name.dropFirst()) : name
        guard let workflow = await MainActor.run(body: {
            WorkflowRegistry.find(name: normalizedName)
                ?? WorkflowRegistry.find(slashCommand: "/\(normalizedName)")
        }) else {
            let known = await MainActor.run { WorkflowRegistry.all.map { $0.name }.joined(separator: ", ") }
            return AgentToolResult(
                summary: "Unknown workflow",
                payload: "Unknown workflow `\(name)`. Available: \(known)."
            )
        }
        let args = arguments["args"]?.stringValue() ?? ""
        let result = await MainActor.run { () -> (Bool, String) in
            // 用 runtime 自己的 startWorkflow 路径 —— 它会找到该 runtime
            // 的 messages / 状态并塞 workflow card 进去。
            guard let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) else {
                return (false, "no app state for runtime \(runtimeID)")
            }
            let claimed = appState.startWorkflow(slashCommand: workflow.slashCommand, args: args)
            return (claimed, claimed ? "started" : "could not start (workflow rejected args)")
        }
        if result.0 {
            let argsHint = args.isEmpty ? "" : " with args: \(args)"
            return AgentToolResult(
                summary: "Started \(workflow.displayTitle)",
                payload: "workflow `\(workflow.name)` queued\(argsHint). Card will appear in the transcript with live agent counts; final report joins the transcript when synthesize finishes."
            )
        }
        return AgentToolResult(
            summary: "Failed to start \(workflow.displayTitle)",
            payload: "Could not start workflow `\(workflow.name)`: \(result.1)."
        )
    }

}
