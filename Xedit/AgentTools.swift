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

nonisolated enum AgentRunCommandExecutionPolicy {
    enum ActivityKind: Equatable {
        case test
        case build
        case server

        var operationName: String {
            switch self {
            case .test: return "运行测试"
            case .build: return "编译项目"
            case .server: return "启动开发服务"
            }
        }
    }

    /// An explicit model/user choice always wins. Otherwise, promote only
    /// well-known test/build/dev-server entry points. This intentionally does
    /// not infer from arbitrary words such as "build" inside script paths:
    /// release, publish, notarization, and deployment workflows must opt in.
    static func shouldRunInBackground(arguments: [String: AgentJSONValue]) -> Bool {
        if let explicitChoice = arguments["run_in_background"]?.boolValue() {
            return explicitChoice
        }
        guard let command = arguments["command"]?.stringValue() else { return false }
        return inferredActivityKind(for: command) != nil
    }

    static func inferredActivityKind(for command: String) -> ActivityKind? {
        for segment in SafeCommand.splitPipeline(command) {
            let tokens = normalizedInvocationTokens(from: SafeCommand.tokenize(segment))
            guard let executable = tokens.first else { continue }
            let arguments = Array(tokens.dropFirst())

            switch executable {
            case "xcodebuild":
                if arguments.contains("test") { return .test }
                if arguments.contains(where: { ["build", "archive"].contains($0) }) { return .build }
                if !arguments.contains(where: {
                    ["-list", "-showbuildsettings", "-showsdks", "-version", "clean"].contains($0)
                }) {
                    return .build
                }
            case "swift", "go", "cargo":
                if arguments.first == "test" { return .test }
                if arguments.first == "build" { return .build }
            case "pytest", "rspec":
                return .test
            case "python", "python3":
                if arguments.starts(with: ["-m", "pytest"]) { return .test }
            case "bundle":
                if arguments.starts(with: ["exec", "rspec"]) { return .test }
            case "npm", "yarn", "pnpm", "bun":
                if let kind = packageScriptActivityKind(arguments) { return kind }
            case "make", "gmake":
                if let kind = makeActivityKind(arguments) { return kind }
            case "gradle", "gradlew", "mvn", "mvnw":
                if arguments.contains(where: { ["test", "check", "verify"].contains($0) }) { return .test }
                if arguments.contains(where: { ["build", "assemble", "package"].contains($0) }) { return .build }
            case "docker":
                if arguments.first == "build" { return .build }
                if arguments.starts(with: ["compose", "build"]) { return .build }
                if arguments.starts(with: ["compose", "up"]) { return .server }
            default:
                let basename = URL(fileURLWithPath: executable).lastPathComponent
                if ["run_tests.sh", "run-tests.sh", "test.sh", "tests.sh"].contains(basename) {
                    return .test
                }
                if ["build.sh", "build.rb"].contains(basename) {
                    return .build
                }
            }
        }
        return nil
    }

    private static func normalizedInvocationTokens(from rawTokens: [String]) -> [String] {
        var tokens = rawTokens.map { $0.lowercased() }
        while let first = tokens.first, isEnvironmentAssignment(first) {
            tokens.removeFirst()
        }
        if tokens.first == "env" {
            tokens.removeFirst()
            while let first = tokens.first, isEnvironmentAssignment(first) {
                tokens.removeFirst()
            }
        }
        while let first = tokens.first, ["time", "nice", "nohup"].contains(first) {
            tokens.removeFirst()
        }
        guard let first = tokens.first else { return [] }
        tokens[0] = URL(fileURLWithPath: first).lastPathComponent
        return tokens
    }

    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let separator = token.firstIndex(of: "="), separator != token.startIndex else {
            return false
        }
        return token[..<separator].allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func packageScriptActivityKind(_ rawArguments: [String]) -> ActivityKind? {
        var arguments = rawArguments
        if arguments.first == "run" {
            arguments.removeFirst()
        }
        guard let script = arguments.first?.split(separator: ":", maxSplits: 1).first.map(String.init) else {
            return nil
        }
        switch script {
        case "test", "tests", "check", "ci": return .test
        case "build", "compile": return .build
        case "dev", "serve", "start": return .server
        default: return nil
        }
    }

    private static func makeActivityKind(_ arguments: [String]) -> ActivityKind? {
        if arguments.contains(where: { ["test", "tests", "check"].contains($0) }) { return .test }
        if arguments.contains(where: { ["build", "compile", "all"].contains($0) }) { return .build }
        if arguments.contains(where: { ["dev", "serve", "start"].contains($0) }) { return .server }
        return nil
    }
}

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

    /// Terminate the shell and every descendant it launched. Killing only the
    /// Foundation `Process` frequently leaves `sh -c` children alive (and the
    /// inherited stdout pipe open), so a stopped command can otherwise keep
    /// consuming resources until its original timeout.
    nonisolated static func terminateProcessTree(
        _ process: Process,
        gracePeriod: TimeInterval = 2
    ) {
        terminateProcessTree(rootPID: process.processIdentifier, gracePeriod: gracePeriod)
    }

    /// PID-based variant for PTY-backed processes such as SwiftTerm's
    /// `LocalProcess`, which does not expose a Foundation `Process`.
    ///
    /// Capture descendants before sending TERM: the root shell/ssh process
    /// can exit immediately, after which libproc can no longer discover
    /// children that ignored the first signal. The delayed identity check
    /// protects the SIGKILL fallback from PID reuse.
    nonisolated static func terminateProcessTree(
        rootPID: pid_t,
        gracePeriod: TimeInterval = 2
    ) {
        guard rootPID > 0 else { return }
        let trackedPIDs = descendantPIDs(of: rootPID) + [rootPID]
        let trackedIdentities = trackedPIDs.compactMap(ProcessIdentity.init(pid:))
        for pid in trackedPIDs {
            _ = Darwin.kill(pid, SIGTERM)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + gracePeriod) {
            for identity in trackedIdentities where identity.stillMatchesCurrentProcess {
                _ = Darwin.kill(identity.pid, SIGKILL)
            }
        }
    }

    /// Protect the delayed SIGKILL from PID reuse: a short-lived child may
    /// exit after TERM and macOS may recycle its pid before the grace period.
    private nonisolated struct ProcessIdentity: Sendable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64

        init?(pid: pid_t) {
            guard let info = Self.info(for: pid) else { return nil }
            self.pid = pid
            startSeconds = info.pbi_start_tvsec
            startMicroseconds = info.pbi_start_tvusec
        }

        var stillMatchesCurrentProcess: Bool {
            guard let info = Self.info(for: pid) else { return false }
            return info.pbi_start_tvsec == startSeconds
                && info.pbi_start_tvusec == startMicroseconds
        }

        private static func info(for pid: pid_t) -> proc_bsdinfo? {
            var info = proc_bsdinfo()
            let byteCount = withUnsafeMutablePointer(to: &info) { pointer in
                proc_pidinfo(
                    pid,
                    PROC_PIDTBSDINFO,
                    0,
                    pointer,
                    Int32(MemoryLayout<proc_bsdinfo>.size)
                )
            }
            guard byteCount == MemoryLayout<proc_bsdinfo>.size else { return nil }
            return info
        }
    }

    /// libproc reports PID counts (not byte counts); recurse before appending
    /// each child so signals travel deepest-first.
    private nonisolated static func descendantPIDs(of rootPID: pid_t) -> [pid_t] {
        var visited: Set<pid_t> = [rootPID]
        var result: [pid_t] = []

        func collect(parentPID: pid_t) {
            let capacity = proc_listchildpids(parentPID, nil, 0)
            guard capacity > 0 else { return }
            var children = [pid_t](repeating: 0, count: Int(capacity))
            let count = children.withUnsafeMutableBytes { buffer in
                proc_listchildpids(parentPID, buffer.baseAddress, Int32(buffer.count))
            }
            guard count > 0 else { return }
            for childPID in children.prefix(Int(count)) where childPID > 0 {
                guard visited.insert(childPID).inserted else { continue }
                collect(parentPID: childPID)
                result.append(childPID)
            }
        }

        collect(parentPID: rootPID)
        return result
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
        var computerUseControl: AgentComputerUsePreparedControl?
        var localObservationGuard: AgentComputerUseLocalObservationGuard?
        var computerUseMaintenance:
            AgentComputerUseMaintenanceReservation?
        do {
            computerUseMaintenance = try await AgentComputerUseExecution
                .prepareMaintenanceReservation(toolName: name)
            localObservationGuard = try await AgentComputerUseExecution
                .prepareLocalObservation(
                    toolName: name,
                    arguments: activeArguments
                )
            computerUseControl = try await AgentComputerUseExecution.prepare(
                toolName: name,
                arguments: activeArguments,
                context: activeContext
            )
            let computerUseLeaseID = computerUseControl?
                .leaseID
                .uuidString
                .lowercased()
            let result: AgentToolResult
            if AgentShortDramaToolDispatcher.canHandle(name) {
                result = try await AgentShortDramaToolDispatcher.run(
                    name: name,
                    arguments: activeArguments,
                    context: activeContext
                )
                await AgentComputerUseExecution.finishMaintenanceReservation(
                    computerUseMaintenance
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
            case "list_workspace_sessions":
                result = try await AgentSessionTools.listWorkspaceSessions(arguments: activeArguments, context: activeContext)
            case "suggest_session_title":
                result = try await AgentSessionTools.suggestSessionTitle(context: activeContext)
            case "rename_session":
                result = try await AgentSessionTools.renameSession(arguments: activeArguments, context: activeContext)
            case "change_workspace":
                result = try await AgentSessionTools.changeWorkspace(arguments: activeArguments, context: activeContext)
            case "run_command":
                result = try await runCommand(arguments: activeArguments, context: activeContext)
            case "list_queued_tasks":
                result = try await listQueuedTasks(arguments: activeArguments, context: activeContext)
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
            case "terminal_list_tabs":
                result = try await AgentTerminalTools.listTabs(arguments: activeArguments, context: activeContext)
            case "terminal_select_tab":
                result = try await AgentTerminalTools.selectTab(arguments: activeArguments, context: activeContext)
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
            case "activate_expert":
                result = try await activateExpert(arguments: activeArguments, context: activeContext)
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
                result = try await generateImage(arguments: activeArguments, context: activeContext)
            case "edit_generated_image":
                result = try await AgentMediaTools.editGeneratedImage(arguments: activeArguments, context: activeContext)
            case "visual_qa_screenshot":
                result = try await AgentVisualQATools.analyzeScreenshot(arguments: activeArguments, context: activeContext)
            case "design_to_code_acceptance":
                result = try AgentDesignToCodeTools.acceptance(arguments: activeArguments, context: activeContext)
            case "capture_screenshot":
                result = try await AgentCaptureTools.captureScreenshot(arguments: activeArguments, context: activeContext)
            case "computer_use_permissions":
                result = try await AgentComputerUseTools.permissions()
            case "computer_use_request_permissions":
                result = try await AgentComputerUseTools.requestPermissions(
                    arguments: activeArguments,
                    sessionPersistenceBarrier: activeContext.sessionPersistenceBarrier
                )
            case "computer_use_list_apps":
                result = try await AgentComputerUseTools.listApps()
            case "computer_use_launch_app":
                result = try await AgentComputerUseTools.launchApp(
                    arguments: activeArguments,
                    controlLeaseID: computerUseLeaseID
                )
            case "computer_use_activate_app":
                result = try await AgentComputerUseTools.activateApp(
                    arguments: activeArguments,
                    controlLeaseID: computerUseLeaseID
                )
            case "computer_use_get_app_state":
                result = try await AgentComputerUseTools.getAppState(
                    arguments: activeArguments,
                    controlLeaseID: computerUseLeaseID
                )
            case "computer_use_inspect_app":
                result = try await AgentComputerUseTools.inspectApp(
                    arguments: activeArguments,
                    controlLeaseID: computerUseLeaseID
                )
            case "computer_use_wait_for":
                result = try await AgentComputerUseTools.waitFor(
                    arguments: activeArguments,
                    controlLeaseID: computerUseLeaseID
                )
            case "computer_use_click":
                result = try await AgentComputerUseTools.perform(
                    action: "click",
                    arguments: activeArguments,
                    controlLeaseID: computerUseLeaseID
                )
            case "computer_use_secondary_action":
                result = try await AgentComputerUseTools.perform(
                    action: "secondary_action",
                    arguments: activeArguments,
                    controlLeaseID: computerUseLeaseID
                )
            case "computer_use_scroll":
                result = try await AgentComputerUseTools.perform(
                    action: "scroll",
                    arguments: activeArguments,
                    controlLeaseID: computerUseLeaseID
                )
            case "computer_use_drag":
                result = try await AgentComputerUseTools.perform(
                    action: "drag",
                    arguments: activeArguments,
                    controlLeaseID: computerUseLeaseID
                )
            case "computer_use_type_text":
                result = try await AgentComputerUseTools.perform(
                    action: "type_text",
                    arguments: activeArguments,
                    controlLeaseID: computerUseLeaseID
                )
            case "computer_use_press_key":
                result = try await AgentComputerUseTools.perform(
                    action: "press_key",
                    arguments: activeArguments,
                    controlLeaseID: computerUseLeaseID
                )
            case "computer_use_set_value":
                result = try await AgentComputerUseTools.perform(
                    action: "set_value",
                    arguments: activeArguments,
                    controlLeaseID: computerUseLeaseID
                )
            case "computer_use_focus":
                result = try await AgentComputerUseTools.perform(
                    action: "focus",
                    arguments: activeArguments,
                    controlLeaseID: computerUseLeaseID
                )
            case "computer_use_hover":
                result = try await AgentComputerUseTools.perform(
                    action: "hover",
                    arguments: activeArguments,
                    controlLeaseID: computerUseLeaseID
                )
            case "computer_use_select_text":
                result = try await AgentComputerUseTools.perform(
                    action: "select_text",
                    arguments: activeArguments,
                    controlLeaseID: computerUseLeaseID
                )
            case "computer_use_restart_helper":
                result = try await AgentComputerUseTools.restartHelper()
            case "chrome_status":
                result = try await AgentChromeTools.status(arguments: activeArguments)
            case "chrome_read_page":
                result = try await AgentChromeTools.readPage(arguments: activeArguments)
            case "chrome_read_selection":
                result = try await AgentChromeTools.readSelection(arguments: activeArguments)
            case "chrome_snapshot":
                result = try await AgentChromeTools.snapshot(arguments: activeArguments)
            case "chrome_list_tabs":
                result = try await AgentChromeTools.listTabs(arguments: activeArguments)
            case "chrome_activate_tab":
                result = try await AgentChromeTools.activateTab(arguments: activeArguments)
            case "chrome_navigate":
                result = try await AgentChromeTools.navigate(arguments: activeArguments)
            case "chrome_history":
                result = try await AgentChromeTools.history(arguments: activeArguments)
            case "chrome_click":
                result = try await AgentChromeTools.click(arguments: activeArguments)
            case "chrome_type":
                result = try await AgentChromeTools.typeText(arguments: activeArguments)
            case "chrome_hover":
                result = try await AgentChromeTools.hover(arguments: activeArguments)
            case "chrome_select_option":
                result = try await AgentChromeTools.selectOption(arguments: activeArguments)
            case "chrome_press_key":
                result = try await AgentChromeTools.pressKey(arguments: activeArguments)
            case "chrome_scroll":
                result = try await AgentChromeTools.scroll(arguments: activeArguments)
            case "chrome_wait_for":
                result = try await AgentChromeTools.waitFor(arguments: activeArguments)
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
            case "schedule_task":
                result = try await scheduleTask(arguments: activeArguments, context: activeContext)
            case "complete_scheduled_task":
                result = try await completeScheduledTask(arguments: activeArguments, context: activeContext)
            default:
                throw AgentToolError.unknownTool(name)
            }
            try await AgentComputerUseExecution.complete(
                computerUseControl,
                result: result
            )
            do {
                try await AgentComputerUseExecution.validateLocalObservation(
                    localObservationGuard
                )
            } catch {
                if name == "capture_screenshot",
                   localObservationGuard != nil {
                    AgentCaptureTools.discardPersistedCaptureArtifacts(in: result)
                }
                throw error
            }
            await AgentComputerUseExecution.finishMaintenanceReservation(
                computerUseMaintenance
            )
            return AgentSecretStore.redact(result, secretValues: activeContext.secretRedactionValues)
        } catch {
            await AgentComputerUseExecution.finishMaintenanceReservation(
                computerUseMaintenance
            )
            if computerUseControl != nil {
                do {
                    try await AgentComputerUseExecution.handleFailure(
                        error,
                        prepared: computerUseControl
                    )
                } catch {
                    throw redactedToolError(
                        error,
                        secretValues: activeContext.secretRedactionValues
                    )
                }
            }
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
        // The host decides whether this creation can write immediately from
        // the active approval mode and recoverable git baseline.
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
        let placementLine: String
        let summaryPrefix: String
        switch proposal.status {
        case .applied:
            statusLine = "Patch status: applied. The existing patch applier wrote the changes to disk."
            placementLine = "Changes written to disk. No further approval is required for this patch."
            summaryPrefix = "patch applied"
        case .failed:
            statusLine = "Patch status: failed\(proposal.statusMessage.map { ": \($0)" } ?? ".")"
            placementLine = "The patch was approved, but applying it failed. Diagnose the failure before retrying."
            summaryPrefix = "patch failed"
        case .rejected:
            statusLine = "Patch status: rejected."
            placementLine = "The user rejected this patch. Do not apply it unless the user explicitly asks again."
            summaryPrefix = "patch rejected"
        case .pending:
            statusLine = "Patch status: pending. No files were modified; the user must click Apply on the patch card in the chat before this patch writes to disk."
            placementLine = "A patch card is shown inline in the chat, right below your message — there is NO separate side / review panel. The user reviews and clicks Apply there. Do NOT tell the user to look in a right-side panel."
            summaryPrefix = "patch queued"
        }

        return AgentToolResult(
            summary: "\(summaryPrefix): \(fileLabel)",
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

    private static func generateImage(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let prompt = arguments["prompt"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            throw AgentToolError.missingArgument("prompt")
        }
        var mediaArguments = arguments
        mediaArguments["kind"] = .string("image_generation")
        return try await AgentMediaTools.someIMCreateMediaTask(arguments: mediaArguments, context: context)
    }

    // MARK: run_command

    // 20s/120s starved real builds and test runs: the command got killed,
    // the model retried with a bigger timeout_seconds, and every retry cost
    // a full model round trip. 60s absorbs typical lint/test/build steps;
    // long jobs should still go through run_in_background.
    nonisolated private static let defaultCommandTimeout: TimeInterval = 60
    nonisolated private static let maxCommandTimeout: TimeInterval = 600
    nonisolated private static let maxCommandOutput = 32 * 1024
    nonisolated static let supplementalCommandPathEntries = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        // User-local install prefixes. When the app is launched from
        // Finder/Dock it inherits the minimal launchd PATH, so delegated
        // CLIs (claude/codex/cursor/cline) and the child processes they
        // fork — node, uv, python, git — can't find tools installed here.
        // We resolve the four agent executables by absolute path already,
        // but their children still need these on PATH.
        "\(NSHomeDirectory())/.local/bin",
        "\(NSHomeDirectory())/.cargo/bin",
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

    static func localCommandEnvironment(
        from base: [String: String] = ProcessInfo.processInfo.environment,
        settings: EditorTerminalSettings
    ) -> [String: String] {
        EditorTerminalLaunchEnvironment.variables(
            from: shellEnvironment(from: base),
            settings: settings,
            injectClaudeCodeCompatibility: false,
            markAsAgentTerminal: true
        )
    }

    private static func runCommand(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext,
        foregroundMaxTimeout: TimeInterval = maxCommandTimeout
    ) async throws -> AgentToolResult {
        var effectiveArguments = arguments
        let selectedBackgroundAutomatically =
            arguments["run_in_background"] == nil
            && AgentRunCommandExecutionPolicy.shouldRunInBackground(arguments: arguments)
        if selectedBackgroundAutomatically {
            effectiveArguments["run_in_background"] = .bool(true)
        }
        if let backend = context.remoteBackend {
            return try await backend.runCommand(
                arguments: effectiveArguments,
                context: context,
                foregroundMaxTimeout: foregroundMaxTimeout
            )
        }
        let root = context.rootDirectory?.standardizedFileURL
            ?? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard let command = effectiveArguments["command"]?.stringValue(),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.missingArgument("command")
        }
        let timeoutArg = effectiveArguments["timeout_seconds"]?.intValue().map { Double($0) } ?? defaultCommandTimeout
        let timeout = min(max(timeoutArg, 1), max(1, foregroundMaxTimeout))

        // Background path: hand the Process off to the registry, return
        // immediately with the job handle, let the agent loop pull the
        // completion event at the top of a later turn.
        let wantsBackground = effectiveArguments["run_in_background"]?.boolValue() ?? false
        if wantsBackground, let registry = context.jobRegistry, let runtimeID = context.runtimeID {
            let bgTimeout: Double? = effectiveArguments["timeout_seconds"]?.intValue().map { Double(min(max($0, 1), 3600 * 6)) }
            let job: AgentBackgroundJob
            do {
                job = try await MainActor.run {
                    try registry.start(
                        command: command,
                        workingDirectory: root,
                        runtimeID: runtimeID,
                        turnID: context.turnID,
                        timeoutSeconds: bgTimeout,
                        sandboxMode: context.sandboxMode,
                        environment: context.localCommandEnvironment,
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
            let selectionLine = selectedBackgroundAutomatically
                ? "\nBackground mode: selected automatically for this test/build/server command."
                : ""
            let payload = """
            Started background job \(job.displayHandle).
            Command: \(AgentSecretStore.redact(command, secretValues: context.secretRedactionValues))
            PID: \(job.pid)
            cwd: \(cwd)\(timeoutLine)\(selectionLine)

            The job is running. You will receive a `<background-task-notification>` system message at the start of a later turn when it finishes (or fails). Until then, call `get_job_output` to inspect partial output, `list_jobs` to see all alive jobs, or `kill_job` to stop it.
            """
            let activityLabel = effectiveArguments["label"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = activityLabel.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) }
                ?? AgentRunCommandExecutionPolicy.inferredActivityKind(for: command)?.operationName
                ?? job.displayHandle
            return AgentToolResult(
                summary: "▶ \(summary) · \(job.displayHandle)",
                payload: payload
            )
        }

        try Task.checkCancellation()
        let cancellationController = ForegroundCommandCancellationController()
        let commandTask = Task.detached(priority: .userInitiated) { () -> CommandOutcome in
            let process = Process()
            defer { cancellationController.clear(process) }
            let launch = AgentSandboxPolicy.shellLaunch(
                command: command,
                mode: context.sandboxMode,
                rootDirectory: context.rootDirectory
            )
            process.executableURL = launch.executableURL
            process.arguments = launch.arguments
            process.currentDirectoryURL = root
            let baseEnvironment = context.localCommandEnvironment ?? shellEnvironment()
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
                cancellationController.bind(process)
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
                    AgentProcessSupport.terminateProcessTree(process)
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
        }
        let outcome = await withTaskCancellationHandler {
            await commandTask.value
        } onCancel: {
            commandTask.cancel()
            cancellationController.cancel()
        }
        try Task.checkCancellation()

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
        model: String?,
        imagePaths: [String] = []
    ) -> String {
        var parts = [shellQuoted(executable)]
        let imageDirectories = Array(Set(imagePaths.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        })).sorted()
        for directory in imageDirectories {
            parts += ["--add-dir", shellQuoted(directory)]
        }
        parts += [
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
            model: arguments["model"]?.stringValue(),
            imagePaths: delegatedImagePaths(arguments)
        )

        return try await runDelegatedAgentCommand(command, arguments: arguments, context: context)
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
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
        ], environment: environment, isExecutable: isExecutable)
    }

    /// Locate the Cursor Agent CLI. The standalone installer
    /// (`curl https://cursor.com/install | bash`) drops a `cursor-agent`
    /// binary in `~/.local/bin` and does NOT provide a `cursor` command,
    /// so prefer `cursor-agent`. Fall back to the `cursor` editor launcher
    /// (installed by Cursor.app), which forwards its `agent` subcommand to
    /// the same headless agent. Both accept the `agent …` command we
    /// compose, so callers don't need to know which one was found.
    nonisolated static func cursorAgentExecutablePath(
        environment: [String: String] = shellEnvironment(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let home = NSHomeDirectory()
        if let standalone = executablePath(commandName: "cursor-agent", preferredPaths: [
            "\(home)/.local/bin/cursor-agent",
            "/opt/homebrew/bin/cursor-agent",
            "/usr/local/bin/cursor-agent",
        ], environment: environment, isExecutable: isExecutable) {
            return standalone
        }
        return executablePath(commandName: "cursor", preferredPaths: [
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
        workspacePath: String?,
        imagePaths: [String] = []
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
        if !imagePaths.isEmpty {
            parts.append("--image")
            parts += imagePaths.map(shellQuoted)
            parts.append("--")
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
            workspacePath: context.workspaceLocation?.path ?? context.rootDirectory?.standardizedFileURL.path,
            imagePaths: delegatedImagePaths(arguments)
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

    nonisolated static func delegatedImagePaths(
        _ arguments: [String: AgentJSONValue],
        fileManager: FileManager = .default
    ) -> [String] {
        guard let candidates = arguments["image_paths"]?.stringArrayValue() else { return [] }
        return candidates.compactMap { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let directory = url.deletingLastPathComponent()
            guard url.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path + "/"),
                  directory.lastPathComponent.hasPrefix(AgentDelegatedImageBundle.directoryPrefix),
                  fileManager.fileExists(atPath: url.path) else {
                return nil
            }
            return url.path
        }
    }

    private static func runDelegatedAgentCommand(
        _ command: String,
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        if arguments["use_visible_terminal"]?.boolValue() == true,
           context.remoteBackend == nil,
           let controller = context.terminalController,
           let sessionID = context.runtimeID {
            let timeout = arguments["timeout_seconds"]?.intValue()
                .map(TimeInterval.init) ?? delegatedAgentForegroundTimeout
            let label = arguments["visible_terminal_label"]?.stringValue()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayCommand = label.flatMap { $0.isEmpty ? nil : $0 }
                ?? L10n.AgentTerminal.delegatedTask
            return try await controller.runCommandInDelegatedShellTab(
                command,
                sessionID: sessionID,
                displayCommand: displayCommand,
                timeout: timeout,
                secretRedactionValues: context.secretRedactionValues
            )
        }
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

    private static func listQueuedTasks(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        let includeFinished = arguments["include_finished"]?.boolValue() ?? false
        let queueSnapshot = await MainActor.run {
            context.sessionQueueSnapshotProvider?()
        } ?? AgentSessionQueueSnapshot(queuedMessages: [], pendingDispatches: [])

        let jobs: [AgentBackgroundJob] = await MainActor.run {
            guard let registry = context.jobRegistry, let runtimeID = context.runtimeID else { return [] }
            let scoped = registry.jobs(forRuntime: runtimeID)
            return includeFinished ? scoped : scoped.filter { $0.isAlive || $0.needsAttention }
        }
        let mediaTasks: [AgentMediaTask] = await MainActor.run {
            guard let registry = context.mediaTaskRegistry else { return [] }
            let scoped = registry.tasks(forRuntime: context.runtimeID)
            return includeFinished ? scoped : scoped.filter { $0.isActive || $0.needsAttention }
        }
        let buildQueue = projectBuildGuardQueueEntries(rootDirectory: context.rootDirectory)
        let shouldDeferHeavyActions = !queueSnapshot.queuedMessages.isEmpty || !queueSnapshot.pendingDispatches.isEmpty

        var lines: [String] = [
            "defer_heavy_actions_recommended: \(shouldDeferHeavyActions)",
            "reason: \(shouldDeferHeavyActions ? "The current session has queued user work or is waiting for a provider slot." : "No queued user messages or provider dispatch waits in the current session.")",
            "counts:",
            "- queued_user_messages: \(queueSnapshot.queuedMessages.count)",
            "- pending_provider_dispatches: \(queueSnapshot.pendingDispatches.count)",
            "- active_background_jobs: \(jobs.filter { $0.isAlive }.count)",
            "- active_media_tasks: \(mediaTasks.filter { $0.isActive }.count)",
            "- project_build_guard_queue_entries: \(buildQueue.count)"
        ]

        if !queueSnapshot.queuedMessages.isEmpty {
            lines.append("queued_user_messages:")
            for (offset, message) in queueSnapshot.queuedMessages.enumerated() {
                lines.append("- #\(offset + 1) \(message.id.uuidString): \(preview(message.text))\(attachmentSummary(images: message.images.count, textAttachments: message.textAttachments.count, skills: message.attachedSkills.count))")
            }
        }
        if !queueSnapshot.pendingDispatches.isEmpty {
            lines.append("pending_provider_dispatches:")
            for (offset, dispatch) in queueSnapshot.pendingDispatches.enumerated() {
                lines.append("- #\(offset + 1) provider=\(dispatch.providerID) queued_for=\(formatDuration(Date().timeIntervalSince(dispatch.enqueuedAt))) message_id=\(dispatch.userMessageID.uuidString): \(preview(dispatch.text))")
            }
        }
        if !jobs.isEmpty {
            lines.append("background_jobs:")
            lines.append(contentsOf: jobs.map { "- \(describe(job: $0))" })
        }
        if !mediaTasks.isEmpty {
            lines.append("media_tasks:")
            lines.append(contentsOf: mediaTasks.map { "- \(describe(mediaTask: $0))" })
        }
        if !buildQueue.isEmpty {
            lines.append("project_build_guard_queue:")
            lines.append(contentsOf: buildQueue.map { "- \($0.summaryLine)" })
        }

        let jsonObject: [String: Any] = [
            "defer_heavy_actions_recommended": shouldDeferHeavyActions,
            "queued_user_messages": queueSnapshot.queuedMessages.enumerated().map { offset, message in
                [
                    "position": offset + 1,
                    "id": message.id.uuidString,
                    "preview": preview(message.text),
                    "image_count": message.images.count,
                    "text_attachment_count": message.textAttachments.count,
                    "skill_count": message.attachedSkills.count,
                    "execution_agent": message.executionAgent.rawValue
                ] as [String: Any]
            },
            "pending_provider_dispatches": queueSnapshot.pendingDispatches.enumerated().map { offset, dispatch in
                [
                    "position": offset + 1,
                    "user_message_id": dispatch.userMessageID.uuidString,
                    "provider_id": dispatch.providerID,
                    "enqueued_at": isoString(dispatch.enqueuedAt),
                    "preview": preview(dispatch.text),
                    "image_count": dispatch.imageCount,
                    "text_attachment_count": dispatch.textAttachmentCount,
                    "skill_count": dispatch.skillCount
                ] as [String: Any]
            },
            "background_jobs": jobs.map { job in
                [
                    "id": job.id.uuidString,
                    "handle": job.displayHandle,
                    "status": job.status.rawValue,
                    "is_alive": job.isAlive,
                    "exit_code": job.exitCode.map { Int($0) } ?? NSNull(),
                    "started_at": isoString(job.startedAt),
                    "finished_at": job.finishedAt.map(isoString) ?? NSNull(),
                    "command": preview(job.command, limit: 180)
                ] as [String: Any]
            },
            "media_tasks": mediaTasks.map { task in
                [
                    "id": task.id.uuidString,
                    "handle": task.displayHandle,
                    "status": task.status.rawValue,
                    "provider": task.provider.rawValue,
                    "kind": task.kind.rawValue,
                    "title": preview(task.title, limit: 120),
                    "progress": task.progress ?? NSNull(),
                    "updated_at": isoString(task.updatedAt),
                    "artifact_count": task.artifacts.count
                ] as [String: Any]
            },
            "project_build_guard_queue": buildQueue.map(\.jsonObject)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            lines.append("json:")
            lines.append(json)
        }

        let activeCount = jobs.filter(\.isAlive).count + mediaTasks.filter(\.isActive).count + buildQueue.count
        let summary = shouldDeferHeavyActions
            ? "queued user work: \(queueSnapshot.queuedMessages.count)"
            : "no queued user work; \(activeCount) active tracked tasks"
        return AgentToolResult(summary: summary, payload: lines.joined(separator: "\n"))
    }

    private static func describe(job: AgentBackgroundJob) -> String {
        let exit = job.exitCode.map { "exit=\($0)" } ?? "exit=…"
        let durationText = formatDuration(job.duration)
        let trimmedCommand = job.command.count > 100
            ? String(job.command.prefix(100)) + "…"
            : job.command
        return "\(job.displayHandle) [\(job.status.rawValue)] \(exit) · \(durationText) · pid=\(job.pid) · \(trimmedCommand)"
    }

    private static func describe(mediaTask task: AgentMediaTask) -> String {
        let progress = task.progress.map { " progress=\(Int(($0 * 100).rounded()))%" } ?? ""
        let updated = formatDuration(Date().timeIntervalSince(task.updatedAt))
        let title = preview(task.title, limit: 80)
        return "\(task.displayHandle) [\(task.status.rawValue)] \(task.provider.displayName)/\(task.kind.rawValue)\(progress) · updated \(updated) ago · \(title)"
    }

    private struct ProjectBuildQueueEntry {
        let id: String
        let position: Int
        let pid: Int32?
        let name: String
        let kind: String
        let fingerprint: String
        let command: [String]
        let createdAt: Date?
        let createdAtISO: String?
        let processAlive: Bool

        var summaryLine: String {
            let pidText = pid.map { "pid=\($0)" } ?? "pid=unknown"
            let commandText = command.joined(separator: " ")
            let shortFingerprint = fingerprint.isEmpty ? "no-fingerprint" : String(fingerprint.prefix(12))
            return "#\(position) \(name) [\(kind)] \(pidText) alive=\(processAlive) fingerprint=\(shortFingerprint) · \(AgentToolRunner.preview(commandText, limit: 120))"
        }

        var jsonObject: [String: Any] {
            [
                "id": id,
                "position": position,
                "pid": pid.map { Int($0) } ?? NSNull(),
                "name": name,
                "kind": kind,
                "fingerprint": fingerprint,
                "command": command,
                "created_at": createdAt.map(AgentToolRunner.isoString) ?? NSNull(),
                "created_at_iso": createdAtISO ?? NSNull(),
                "process_alive": processAlive
            ]
        }
    }

    private static func projectBuildGuardQueueEntries(rootDirectory: URL?) -> [ProjectBuildQueueEntry] {
        guard let rootDirectory else { return [] }
        let localStateURL = rootDirectory
            .standardizedFileURL
            .appendingPathComponent(".codex-build", isDirectory: true)
        let coordinationURL = localStateURL.appendingPathComponent("coordination.json", isDirectory: false)
        let queueURL: URL
        if let data = try? Data(contentsOf: coordinationURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sharedQueuePath = object["queue_dir"] as? String,
           !sharedQueuePath.isEmpty {
            queueURL = URL(fileURLWithPath: sharedQueuePath, isDirectory: true).standardizedFileURL
        } else {
            queueURL = localStateURL.appendingPathComponent("queue", isDirectory: true)
        }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: queueURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoded: [(url: URL, object: [String: Any])] = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                return (url, object)
            }
            .sorted { lhs, rhs in
                let leftCreated = doubleValue(lhs.object["created_at"]) ?? 0
                let rightCreated = doubleValue(rhs.object["created_at"]) ?? 0
                if leftCreated != rightCreated { return leftCreated < rightCreated }
                return stringValue(lhs.object["id"]) < stringValue(rhs.object["id"])
            }

        return decoded.enumerated().map { offset, item in
            let object = item.object
            let pid = int32Value(object["pid"])
            let createdAt = doubleValue(object["created_at"]).map(Date.init(timeIntervalSince1970:))
            return ProjectBuildQueueEntry(
                id: stringValue(object["id"], fallback: item.url.deletingPathExtension().lastPathComponent),
                position: offset + 1,
                pid: pid,
                name: stringValue(object["name"], fallback: "build"),
                kind: stringValue(object["kind"], fallback: "build"),
                fingerprint: stringValue(object["fingerprint"]),
                command: stringArrayValue(object["command"]),
                createdAt: createdAt,
                createdAtISO: stringValue(object["created_at_iso"]).isEmpty ? nil : stringValue(object["created_at_iso"]),
                processAlive: pid.map(processAlive) ?? false
            )
        }
    }

    nonisolated private static func processAlive(pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private static func attachmentSummary(images: Int, textAttachments: Int, skills: Int) -> String {
        var parts: [String] = []
        if images > 0 { parts.append("images=\(images)") }
        if textAttachments > 0 { parts.append("attachments=\(textAttachments)") }
        if skills > 0 { parts.append("skills=\(skills)") }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    private static func preview(_ value: String, limit: Int = 160) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit)) + "…"
    }

    nonisolated private static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func stringValue(_ value: Any?, fallback: String = "") -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return fallback
        }
    }

    private static func stringArrayValue(_ value: Any?) -> [String] {
        switch value {
        case let strings as [String]:
            return strings
        case let array as [Any]:
            return array.map { stringValue($0) }.filter { !$0.isEmpty }
        default:
            return []
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let double as Double:
            return double
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private static func int32Value(_ value: Any?) -> Int32? {
        guard let double = doubleValue(value), double >= Double(Int32.min), double <= Double(Int32.max) else {
            return nil
        }
        return Int32(double)
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

    private static func activateExpert(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let rawID = arguments["expert_id"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawID.isEmpty else {
            throw AgentToolError.missingArgument("expert_id")
        }
        guard let expert = AgentExpert(rawValue: rawID) else {
            throw AgentToolError.invalidArgument("Unknown expert_id: \(rawID)")
        }
        guard let runtimeID = context.runtimeID else {
            throw AgentToolError.invalidArgument("activate_expert requires a conversational runtime.")
        }
        let activated = await MainActor.run { () -> Bool in
            guard let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID),
                  let runtime = appState.agentRuntimes[runtimeID] else {
                return false
            }
            if runtime.activeExperts.contains(expert) {
                return true
            }
            var experts = runtime.activeExperts
            experts.insert(expert)
            runtime.activeExperts = experts
            return true
        }
        guard activated else {
            throw AgentToolError.invalidArgument("No active app session found for activate_expert.")
        }
        let reason = arguments["reason"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasonLine = reason?.isEmpty == false ? "\nReason: \(reason!)" : ""
        return AgentToolResult(
            summary: "Activated expert: \(expert.rawValue)",
            payload: "Activated \(expert.displayName) for this session.\(reasonLine)"
        )
    }

    // MARK: scheduled tasks

    /// `schedule_task` — create a scheduled task (backed by an AgentRoutine)
    /// from within the conversation and drop an inline card into the transcript.
    private static func scheduleTask(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let runtimeID = context.runtimeID else {
            throw AgentToolError.invalidArgument("schedule_task requires a conversational runtime.")
        }
        let title = arguments["title"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = arguments["prompt"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else { throw AgentToolError.missingArgument("prompt") }
        let goalRaw = arguments["goal"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = (goalRaw?.isEmpty == false) ? goalRaw : nil

        let schedule: AgentRoutineSchedule
        if let minutesString = arguments["interval_minutes"]?.stringValue(),
           let minutes = Int(minutesString), minutes > 0 {
            schedule = .interval(minutes: max(1, minutes))
        } else if let dailyAt = arguments["daily_at"]?.stringValue(),
                  let time = parseHHMM(dailyAt) {
            schedule = .dailyAt(hour: time.hour, minute: time.minute)
        } else {
            throw AgentToolError.invalidArgument(
                "schedule_task needs either interval_minutes (e.g. \"30\") or daily_at (\"HH:MM\")."
            )
        }

        let name: String = {
            if !title.isEmpty { return title }
            if let goal, !goal.isEmpty { return String(goal.prefix(48)) }
            return String(prompt.prefix(48))
        }()

        let created: AgentRoutine? = await MainActor.run {
            guard let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) else {
                return nil
            }
            let routine = AgentRoutine(
                name: name,
                prompt: prompt,
                workspaceRootPath: appState.agentRuntimes[runtimeID]?.workspaceRootPath,
                schedule: schedule,
                originSessionID: runtimeID,
                goal: goal
            )
            appState.saveAgentRoutine(routine)
            AgentScheduledTaskRegistry.shared.add(
                AgentScheduledTaskCard(
                    id: routine.id,
                    title: name,
                    scheduleSummary: schedule.summary,
                    goal: goal,
                    prompt: prompt
                ),
                forRuntime: runtimeID
            )
            return routine
        }
        guard let routine = created else {
            throw AgentToolError.invalidArgument("No active app session found for schedule_task.")
        }

        let goalLine = goal.map { "\nGoal (task self-completes when met): \($0)" } ?? ""
        return AgentToolResult(
            summary: "Scheduled task: \(name) · \(schedule.summary)",
            payload: "Scheduled task \"\(name)\" created (task_id: \(routine.id.uuidString)); it will run \(schedule.summary). Each run receives this prompt: \(prompt)\(goalLine)"
        )
    }

    /// `complete_scheduled_task` — remove a scheduled task once its goal is met.
    /// Called by the fired run when it judges the goal achieved; also usable to
    /// cancel a task by id.
    private static func completeScheduledTask(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let runtimeID = context.runtimeID else {
            throw AgentToolError.invalidArgument("complete_scheduled_task requires a conversational runtime.")
        }
        let idString = arguments["task_id"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let taskID = UUID(uuidString: idString) else {
            throw AgentToolError.invalidArgument("task_id must be a valid scheduled-task id.")
        }
        let reason = arguments["reason"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines)

        let existed: Bool = await MainActor.run {
            guard let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) else {
                return false
            }
            let found = appState.agentRoutines.contains { $0.id == taskID }
            appState.deleteAgentRoutine(id: taskID)
            return found
        }

        let reasonLine = reason?.isEmpty == false ? " Reason: \(reason!)" : ""
        if existed {
            return AgentToolResult(
                summary: "Completed scheduled task",
                payload: "Scheduled task \(taskID.uuidString) marked complete and removed.\(reasonLine)"
            )
        }
        return AgentToolResult(
            summary: "Scheduled task already gone",
            payload: "No scheduled task with id \(taskID.uuidString) (it may already be removed).\(reasonLine)"
        )
    }

    /// Parse "HH:MM" (24h) into components; returns nil on malformed input.
    private static func parseHHMM(_ raw: String) -> (hour: Int, minute: Int)? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), (0...23).contains(hour),
              let minute = Int(parts[1]), (0...59).contains(minute) else {
            return nil
        }
        return (hour, minute)
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

    /// Bridges structured Task cancellation to Foundation.Process. Without
    /// this, stopping an Agent turn only cancelled the awaiter while the shell
    /// kept running until its timeout and continued consuming resources.
    private nonisolated final class ForegroundCommandCancellationController: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var isCancelled = false

        func bind(_ process: Process) {
            lock.lock()
            self.process = process
            let shouldCancel = isCancelled
            lock.unlock()
            if shouldCancel {
                terminate(process)
            }
        }

        func clear(_ process: Process) {
            lock.lock()
            if self.process === process {
                self.process = nil
            }
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let process = process
            lock.unlock()
            if let process {
                terminate(process)
            }
        }

        private func terminate(_ process: Process) {
            guard process.isRunning else { return }
            AgentProcessSupport.terminateProcessTree(process)
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
        let sourceURL = try widgetHTMLSourceURL(arguments: arguments, context: context)
        let html = try widgetHTML(arguments: arguments, context: context, sourceURL: sourceURL)
        let contextLines = try widgetContextLines(arguments: arguments)
        let bytes = html.utf8.count
        if bytes > 1_048_576 {
            return AgentToolResult(
                summary: "Refused (>1 MB)",
                payload: "show_widget refused: html payload is \(bytes) bytes (>1 MB). Trim it down or split into multiple widgets."
            )
        }
        var widget = AgentWidget(title: title, html: html, contextLines: contextLines)
        widget.sourceBaseURL = sourceURL?.deletingLastPathComponent()
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
        context: AgentToolContext,
        sourceURL: URL? = nil
    ) throws -> String {
        if let html = arguments["html"]?.stringValue(), !html.isEmpty {
            return html
        }
        guard let url = sourceURL else {
            throw AgentToolError.missingArgument("html")
        }
        let rawPath = arguments["html_path"]?.stringValue() ?? url.path
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

    private static func widgetHTMLSourceURL(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) throws -> URL? {
        guard let rawPath = arguments["html_path"]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return nil
        }
        return try resolveWidgetHTMLURL(rawPath, context: context)
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
        let result = await MainActor.run { () -> WorkflowStartResult in
            guard let appState = EditorAppStateRegistry.shared.appState(forRuntime: runtimeID) else {
                return .rejected(reason: "No AppState owns runtime \(runtimeID).")
            }
            return appState.startWorkflow(
                slashCommand: workflow.slashCommand,
                args: args,
                runtimeID: runtimeID,
                notifyAgentOnCompletion: true
            )
        }
        switch result {
        case .started(let reportID):
            let argsHint = args.isEmpty ? "" : " with args: \(args)"
            return AgentToolResult(
                summary: "Started \(workflow.displayTitle)",
                payload: "workflow `\(workflow.name)` queued\(argsHint) as report `\(reportID.uuidString)`. The card will show live progress. When it finishes, the host will deliver the report back in a workflow-completion notice so you can continue the user's task."
            )
        case .rejected(let reason):
            return AgentToolResult(
                summary: "Failed to start \(workflow.displayTitle)",
                payload: "Could not start workflow `\(workflow.name)`: \(reason)"
            )
        case .notRecognized:
            return AgentToolResult(
                summary: "Failed to start \(workflow.displayTitle)",
                payload: "Workflow `\(workflow.name)` disappeared from the registry before dispatch."
            )
        }
    }

}
