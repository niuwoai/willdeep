//
//  AgentTools.swift
//  WillDeep
//
//  Built-in tools exposed to the project agent: search, read, list,
//  run command, and git status. Each tool declares a risk tier so the
//  AppState can decide whether to auto-allow, prompt, or require an
//  explicit confirm word before executing.
//
//  本文件只保留命令执行策略、进程树辅助与 `AgentToolRunner.run` 总分发；
//  各类工具的实现按职责拆到同前缀的兄弟文件：
//  AgentToolsFileEditing / AgentToolsCommandExecution /
//  AgentToolsDelegatedAgents / AgentToolsJobs /
//  AgentToolsExpertsAndSchedules / AgentToolsWidgets。
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
        let trackedIdentities = signalProcessTreeForShutdown(rootPID: rootPID)
        guard !trackedIdentities.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + gracePeriod) {
            for identity in trackedIdentities where identity.stillMatchesCurrentProcess {
                _ = Darwin.kill(identity.pid, SIGKILL)
            }
        }
    }

    /// SIGTERM the tree and hand the tracked identities back instead of
    /// scheduling the SIGKILL fallback. App termination needs this split: the
    /// delayed escalation above rides a queue inside this process, so a quit
    /// that exits before the grace period elapses never delivers it, and every
    /// child that ignored SIGTERM survives as an orphan.
    @discardableResult
    nonisolated static func signalProcessTreeForShutdown(
        rootPID: pid_t
    ) -> [ProcessIdentity] {
        guard rootPID > 0 else { return [] }
        let trackedPIDs = descendantPIDs(of: rootPID) + [rootPID]
        let trackedIdentities = trackedPIDs.compactMap(ProcessIdentity.init(pid:))
        for pid in trackedPIDs {
            _ = Darwin.kill(pid, SIGTERM)
        }
        return trackedIdentities
    }

    /// Protect the delayed SIGKILL from PID reuse: a short-lived child may
    /// exit after TERM and macOS may recycle its pid before the grace period.
    nonisolated struct ProcessIdentity: Sendable {
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
    nonisolated static func descendantProcessIdentities(of rootPID: pid_t) -> [ProcessIdentity] {
        descendantPIDs(of: rootPID).compactMap(ProcessIdentity.init(pid:))
    }

    nonisolated static func terminateProcessIdentities(
        _ identities: [ProcessIdentity],
        gracePeriod: TimeInterval = 2
    ) {
        let live = identities.filter(\.stillMatchesCurrentProcess)
        for identity in live {
            _ = Darwin.kill(identity.pid, SIGTERM)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + gracePeriod) {
            for identity in live where identity.stillMatchesCurrentProcess {
                _ = Darwin.kill(identity.pid, SIGKILL)
            }
        }
    }

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
        try Task.checkCancellation()
        try context.executionBudget?.checkCurrentOwner()
        try await context.taskAuthorizationCheck?(name, arguments, context)
        try Task.checkCancellation()
        try context.executionBudget?.checkCurrentOwner()
        guard !AgentTerminalAutomationPolicy.forbidsShortcutReplay(toolName: name) else {
            throw AgentToolError.invalidArgument(
                "Saved Terminal recording shortcuts are user-run only. Ask the user to press Run in the visible Terminal panel."
            )
        }
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
            try context.executionBudget?.checkCurrentOwner()
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
            case AgentBundledRules.readerToolName:
                guard let file = activeArguments["file"]?.stringValue() else {
                    throw AgentToolError.missingArgument("file")
                }
                result = try AgentBundledRules.readRule(named: file)
            case "list_directory":
                result = try await AgentFileTools.listDirectory(arguments: activeArguments, context: activeContext)
            case "glob":
                // Compatibility alias for the `glob` tool some models hallucinate;
                // read-only workspace path scan. See AgentFileTools.glob.
                result = try await AgentFileTools.glob(arguments: activeArguments, context: activeContext)
            case "git_status":
                result = try await AgentFileTools.gitStatus(context: activeContext)
            case "load_tool_pack":
                let requested = try AgentToolPackCatalog.requestedPackIDs(from: activeArguments)
                guard let activationSink = activeContext.toolPackActivationSink else {
                    throw AgentToolError.invalidArgument("load_tool_pack is available only in the main WillDeep conversation")
                }
                let loaded = activationSink(requested)
                result = AgentToolPackCatalog.activationResult(requested: requested, loaded: loaded)
            case "list_workspace_sessions":
                result = try await AgentSessionTools.listWorkspaceSessions(arguments: activeArguments, context: activeContext)
            case "search_sessions":
                result = try await AgentSessionTools.searchSessions(arguments: activeArguments, context: activeContext)
            case "read_context_message":
                result = try await AgentContextReadTool.run(arguments: activeArguments, context: activeContext)
            case "list_projects", "list_project_sessions", "manage_sessions":
                result = try await AgentSessionManagementTools.run(tool: name, arguments: activeArguments, context: activeContext)
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
            case "write_file":
                result = try await AgentExternalFileTools.writeFile(arguments: activeArguments, context: activeContext)
            case "edit_file":
                result = try await editFile(arguments: activeArguments, context: activeContext)
            case "apply_patch":
                result = try await applyPatch(arguments: activeArguments, context: activeContext)
            case "create_plugin_draft":
                result = try AgentPluginTools.createDraft(arguments: activeArguments)
            case "write_plugin_draft_file":
                result = try AgentPluginTools.writeDraftFile(arguments: activeArguments)
            case "inspect_plugin_draft":
                result = try AgentPluginTools.inspectDraft(arguments: activeArguments)
            case "claude_code":
                result = try await claudeCode(arguments: activeArguments, context: activeContext)
            case "codex_cli":
                result = try await codexCLI(arguments: activeArguments, context: activeContext)
            case "hermes_cli":
                result = try await hermesCLI(arguments: activeArguments, context: activeContext)
            case "cursor_agent":
                result = try await cursorAgent(arguments: activeArguments, context: activeContext)
            case "cline_cli":
                result = try await clineCLI(arguments: activeArguments, context: activeContext)
            case "opencode_cli":
                result = try await openCodeCLI(arguments: activeArguments, context: activeContext)
            case "lark_cli":
                result = try await larkCLI(arguments: activeArguments)
            case "list_jobs":
                result = try await listJobs(arguments: activeArguments, context: activeContext)
            case "get_job_output":
                result = try await getJobOutput(arguments: activeArguments, context: activeContext)
            case "kill_job":
                result = try await killJob(arguments: activeArguments, context: activeContext)
            case "list_skills":
                result = try AgentSkillCatalog.listSkills(
                    arguments: activeArguments,
                    // Children share this runner but cannot spawn: the recipe
                    // only rides when the caller can act on it.
                    includeDispatchHint: activeContext.canSpawnSubagents
                )
            case "read_skill":
                result = try AgentSkillCatalog.readSkill(arguments: activeArguments)
            case "activate_expert":
                result = try await activateExpert(arguments: activeArguments, context: activeContext)
            case "add_memory":
                result = try AgentSelfLearning.addMemory(arguments: activeArguments, rootDirectory: activeContext.rootDirectory)
            case "read_memory":
                result = try AgentSelfLearning.readMemory(arguments: activeArguments, rootDirectory: activeContext.rootDirectory)
            case "create_user_skill":
                result = try AgentSelfLearning.createUserSkill(arguments: activeArguments)
            case "create_user_skills":
                result = try AgentSelfLearning.createUserSkills(arguments: activeArguments)
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
                result = try await AgentEmbeddedBrowserTools.status(arguments: activeArguments, runtimeID: activeContext.runtimeID)
            case "embedded_browser_navigate":
                result = try await AgentEmbeddedBrowserTools.navigate(arguments: activeArguments, runtimeID: activeContext.runtimeID)
            case "embedded_browser_read_page":
                result = try await AgentEmbeddedBrowserTools.readPage(arguments: activeArguments, runtimeID: activeContext.runtimeID)
            case "embedded_browser_snapshot":
                result = try await AgentEmbeddedBrowserTools.snapshot(arguments: activeArguments, runtimeID: activeContext.runtimeID)
            case "embedded_browser_click":
                result = try await AgentEmbeddedBrowserTools.click(arguments: activeArguments, runtimeID: activeContext.runtimeID)
            case "embedded_browser_type":
                result = try await AgentEmbeddedBrowserTools.typeText(arguments: activeArguments, runtimeID: activeContext.runtimeID)
            case "embedded_browser_wait_for":
                result = try await AgentEmbeddedBrowserTools.waitFor(arguments: activeArguments, runtimeID: activeContext.runtimeID)
            case "embedded_browser_eval":
                result = try await AgentEmbeddedBrowserTools.evaluate(arguments: activeArguments, runtimeID: activeContext.runtimeID)
            case "embedded_browser_console":
                result = try await AgentEmbeddedBrowserTools.console(arguments: activeArguments, runtimeID: activeContext.runtimeID)
            case "embedded_browser_network":
                result = try await AgentEmbeddedBrowserTools.network(arguments: activeArguments, runtimeID: activeContext.runtimeID)
            case "embedded_browser_requests":
                result = try await AgentEmbeddedBrowserTools.requests(arguments: activeArguments, runtimeID: activeContext.runtimeID)
            case "embedded_browser_export_har":
                result = try await AgentEmbeddedBrowserTools.exportHAR(arguments: activeArguments, runtimeID: activeContext.runtimeID)
            case "embedded_browser_storage":
                result = try await AgentEmbeddedBrowserTools.storage(arguments: activeArguments, runtimeID: activeContext.runtimeID)
            case "embedded_browser_performance":
                result = try await AgentEmbeddedBrowserTools.performance(arguments: activeArguments, runtimeID: activeContext.runtimeID)
            case "embedded_browser_failed_resources":
                result = try await AgentEmbeddedBrowserTools.failedResources(arguments: activeArguments, runtimeID: activeContext.runtimeID)
            case "embedded_browser_capture_screenshot":
                result = try await AgentEmbeddedBrowserTools.captureScreenshot(arguments: activeArguments, runtimeID: activeContext.runtimeID)
            case let mcpTool where mcpTool.hasPrefix(AgentPluginMCPToolCatalog.exposedNamePrefix):
            // 插件 MCP 工具的一等入口。解不回来就报错而不是静默回落到别的
            // 工具：名字对不上通常是缓存过期，让模型看见比让它以为调过更好。
            guard let route = AgentPluginMCPToolCatalog.route(exposedName: mcpTool) else {
                throw AgentToolError.invalidArgument(
                    "Unknown plugin MCP tool \(mcpTool). Its plugin may have been disabled; use list_mcp_servers to see what is available now."
                )
            }
            let rawArguments = activeArguments["arguments_json"]?.stringValue() ?? "{}"
            let parsed = (try? JSONSerialization.jsonObject(
                with: Data(rawArguments.utf8), options: []
            )) as? [String: Any] ?? [:]
            let payload = try await AgentMCPBridge.callPluginTool(
                pluginID: route.pluginID,
                serverName: route.serverName,
                toolName: route.toolName,
                arguments: parsed
            )
            return AgentToolResult(summary: "\(route.serverName)/\(route.toolName)", payload: payload)
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
            case "declare_environment_trust":
            result = try await declareEnvironmentTrust(arguments: arguments, context: context)
            case "update_plan":
                result = try await updatePlan(arguments: activeArguments, context: activeContext)
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
}
