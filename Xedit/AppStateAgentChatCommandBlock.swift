//
//  AppStateAgentChatCommandBlock.swift
//  WillDeep
//
//  聊天里那两个图标按下去之后发生的事：就地执行，或送进侧边栏终端。
//
//  能走到这儿的命令已经被 `AgentChatRunnableCommand` 筛过一遍（只读、
//  单条、非交互、本地），但按钮上挂的载荷来自渲染那一刻的属性字符串，
//  所以执行前**再判一次**——渲染与点击之间隔着用户的手，中间可能换过
//  会话、换过工作区，这层复判不算多余。
//

import AppKit
import Foundation

@MainActor
extension AppState {
    /// 就地执行：本机跑完，输出以一条系统消息落进 transcript。
    /// 这条消息模型看得到，所以用户可以接着问「为什么报这个错」。
    func runAgentChatShellCommand(_ command: String) {
        guard let runtime = activeRuntime else { return }
        guard allowsLocalAgentChatCommandButtons,
              AgentChatRunnableCommand.isRunnable(command) else {
            appendAgentChatCommandResult(
                runtime: runtime,
                command: command,
                body: L10n.AgentChatCommandBlock.refused
            )
            return
        }
        let workingDirectory = runtime.workspaceRootPath
        Task { [weak self] in
            let outcome = await AgentChatCommandRunner.run(
                command: command,
                workingDirectory: workingDirectory
            )
            await MainActor.run {
                guard let self else { return }
                self.appendAgentChatCommandResult(
                    runtime: runtime,
                    command: command,
                    body: outcome.transcriptBody
                )
            }
        }
    }

    /// 送进侧边栏终端并执行。终端面板没开就先开出来，用户看得见命令
    /// 落在哪个标签页里。
    func sendAgentChatShellCommandToTerminal(_ command: String) {
        guard let runtime = activeRuntime else { return }
        guard allowsLocalAgentChatCommandButtons,
              AgentChatRunnableCommand.isRunnable(command) else {
            appendAgentChatCommandResult(
                runtime: runtime,
                command: command,
                body: L10n.AgentChatCommandBlock.refused
            )
            return
        }
        agentSidePanelRequest = AgentSidePanelOpenRequest(kind: .terminal)
        agentTerminalController.ensureAtLeastOneTab(
            originAgentSessionID: runtime.id,
            workingDirectory: runtime.workspaceRootPath,
            settings: editorTerminalSettings.normalized(),
            skin: nil
        )
        agentTerminalController.activateOwnedTab(for: runtime.id)
        do {
            _ = try agentTerminalController.sendApprovedCommand(command, sessionID: runtime.id)
        } catch {
            appendAgentChatCommandResult(
                runtime: runtime,
                command: command,
                body: "\(L10n.AgentChatCommandBlock.launchFailed): \(error.localizedDescription)"
            )
        }
    }

    /// 当前会话是否允许这两个按钮。工作区在远端时一律不允许——本机跑出
    /// 来的结果是另一台机器的答案，比没有更糟。
    var allowsLocalAgentChatCommandButtons: Bool {
        guard let runtime = activeRuntime else { return false }
        if case .remote = runtime.workspaceLocation { return false }
        return true
    }

    private func appendAgentChatCommandResult(
        runtime: AgentRuntime,
        command: String,
        body: String
    ) {
        let message = AgentMessage(
            role: .system,
            content: """
            \(L10n.AgentChatCommandBlock.resultHeader(command))

            ```
            \(body)
            ```
            """
        )
        runtime.messages.append(message)
        persistAgentSession(runtime: runtime, touchUpdatedAt: false, moveToFront: false)
    }
}

/// 就地执行的那点活：起一个登录 shell、等它、把输出截短。
///
/// 刻意不复用 `run_command` 工具那条路：那条路带沙箱配置、审批联动、
/// 后台任务登记与工具结果协议，是给模型用的；这里是用户点了一下一条
/// 已经确定安全的只读命令，多绕那一圈只会把失败模式变多。
nonisolated enum AgentChatCommandRunner {
    /// 超时。够格的命令都是 `ls` / `git status` 这类，跑不满 15 秒；
    /// 真卡住了也不该让聊天区那条结果消息一直悬着。
    static let timeoutSeconds = 15
    /// 输出上限。超了截断并在末尾说明，别把一屏 transcript 顶满。
    static let maximumOutputBytes = 8 * 1024

    struct Outcome {
        let output: String
        let exitCode: Int32?
        let timedOut: Bool
        let truncated: Bool
        let launchError: String?

        var transcriptBody: String {
            if let launchError {
                return "\(L10n.AgentChatCommandBlock.launchFailed): \(launchError)"
            }
            var lines: [String] = []
            lines.append(output.isEmpty ? L10n.AgentChatCommandBlock.emptyOutput : output)
            if truncated {
                lines.append(L10n.AgentChatCommandBlock.truncated)
            }
            if timedOut {
                lines.append(L10n.AgentChatCommandBlock.timedOut(AgentChatCommandRunner.timeoutSeconds))
            } else if let exitCode, exitCode != 0 {
                lines.append(L10n.AgentChatCommandBlock.exitStatus(Int(exitCode)))
            }
            return lines.joined(separator: "\n")
        }
    }

    static func run(command: String, workingDirectory: String?) async -> Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSynchronously(
                    command: command,
                    workingDirectory: workingDirectory
                ))
            }
        }
    }

    private static func runSynchronously(command: String, workingDirectory: String?) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.environment = AgentToolRunner.shellEnvironment()
        if let workingDirectory, !workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // 标准输入接空:够格的命令都不该等输入,万一等了也立刻拿到 EOF,
        // 而不是把这个进程挂在那里直到超时。
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Outcome(
                output: "",
                exitCode: nil,
                timedOut: false,
                truncated: false,
                launchError: error.localizedDescription
            )
        }

        // 先起看门狗再读管道:反过来的话读操作会把我们卡住,超时永远不
        // 会生效。
        let deadline = DispatchTime.now() + .seconds(timeoutSeconds)
        let timedOut = UnfairBox(false)
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.value = true
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline, execute: watchdog)

        // 一块块读、到量就掐,不用 readDataToEndOfFile:那个要等进程写完才
        // 返回,遇上 `cat /dev/urandom` 这种没有尽头的输出,15 秒里能把几个
        // G 攒进内存,然后我们再把它截成 8KB——截断发生在把内存吃光之后,
        // 等于没截。
        let handle = pipe.fileHandleForReading
        var data = Data()
        var truncated = false
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break } // EOF
            data.append(chunk)
            if data.count >= maximumOutputBytes {
                truncated = true
                process.terminate()
                break
            }
        }
        process.waitUntilExit()
        watchdog.cancel()

        let clipped = data.count > maximumOutputBytes ? data.prefix(maximumOutputBytes) : data
        let text = String(decoding: clipped, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Outcome(
            output: text,
            exitCode: process.terminationStatus,
            timedOut: timedOut.value,
            truncated: truncated,
            launchError: nil
        )
    }
}

/// 看门狗线程与调用线程之间就传一个 Bool，用锁包一下够了。
private final class UnfairBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
