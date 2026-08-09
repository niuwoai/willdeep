//
//  AgentGlobalRulesTests.swift
//  WillDeepTests
//
//  Covers user-level Agent rules loading and system prompt injection.
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentGlobalRulesTests {
    @Test
    func settingsNormalizeUsesDefaultPathWhenBlank() {
        let settings = AgentGlobalRulesSettings(
            isEnabled: true,
            filePath: "   "
        ).normalized

        #expect(settings.filePath == AgentGlobalRulesSettings.defaultFilePath)
    }

    @Test
    func resolvedURLExpandsHomeRelativePath() {
        let url = AgentGlobalRulesStore.resolvedURL(for: "~/.willdeep/CLAUDE.md")
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

        #expect(url.path == "\(home)/.willdeep/CLAUDE.md")
        #expect(AgentGlobalRulesStore.displayPath(for: url) == "~/.willdeep/CLAUDE.md")
    }

    @Test
    func defaultRulesTemplateContainsCodexStrictRules() {
        // The template constrains "this AI assistant", never a named third
        // party — a model reading "these rules bind Codex" can reasonably
        // conclude they do not bind WillDeep Agent.
        #expect(AgentGlobalRulesStore.defaultRulesTemplate.contains("# 全局规则（严格条款）"))
        #expect(!AgentGlobalRulesStore.defaultRulesTemplate.contains("Codex"))
        #expect(AgentGlobalRulesStore.defaultRulesTemplate.contains("所有对用户的回复一律使用**简体中文**"))
        #expect(AgentGlobalRulesStore.defaultRulesTemplate.contains("前端与后端版本号必须保持一致"))
        #expect(AgentGlobalRulesStore.defaultRulesTemplate.contains("默认避免使用管道"))
        #expect(AgentGlobalRulesStore.defaultRulesTemplate.contains("远程环境无法安装/使用传输工具"))
        #expect(AgentGlobalRulesStore.defaultRulesTemplate.contains("<!-- BEGIN ALMA AGENTRULES SYNC -->"))
    }

    @Test
    func loadRulesRespectsEnabledFlagAndTruncatesOnlyForPromptInjection() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rulesURL = tempDir.appendingPathComponent("CLAUDE.md")
        let fullText = String(repeating: "A", count: AgentGlobalRulesStore.maxRulesCharacters + 20)
        try fullText.write(to: rulesURL, atomically: true, encoding: .utf8)

        let settings = AgentGlobalRulesSettings(isEnabled: true, filePath: rulesURL.path)
        let raw = try #require(AgentGlobalRulesStore.readRulesFileText(at: rulesURL))
        let injected = try #require(AgentGlobalRulesStore.loadRules(settings: settings))

        #expect(raw.count == fullText.count)
        #expect(injected.count < raw.count)
        #expect(injected.contains("[truncated]"))
        #expect(AgentGlobalRulesStore.loadRules(settings: AgentGlobalRulesSettings(isEnabled: false, filePath: rulesURL.path)) == nil)
    }

    @Test
    func savingRulesInvalidatesThePromptInjectionCache() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rulesURL = tempDir.appendingPathComponent("CLAUDE.md")
        let settings = AgentGlobalRulesSettings(isEnabled: true, filePath: rulesURL.path)
        try AgentGlobalRulesStore.saveRules("first rule", settings: settings)
        #expect(AgentGlobalRulesStore.loadRules(settings: settings) == "first rule")

        try AgentGlobalRulesStore.saveRules("second rule", settings: settings)
        #expect(AgentGlobalRulesStore.loadRules(settings: settings) == "second rule")
    }

    @Test
    func defaultRulesSeederOnlyTargetsMissingDefaultPath() {
        #expect(AgentGlobalRulesStore.shouldSeedDefaultRulesFile(
            settings: AgentGlobalRulesSettings.default,
            fileExists: false
        ))
        #expect(!AgentGlobalRulesStore.shouldSeedDefaultRulesFile(
            settings: AgentGlobalRulesSettings.default,
            fileExists: true
        ))
        #expect(!AgentGlobalRulesStore.shouldSeedDefaultRulesFile(
            settings: AgentGlobalRulesSettings(isEnabled: true, filePath: "/tmp/custom-rules.md"),
            fileExists: false
        ))
    }

    @Test
    func systemPromptIncludesGlobalRulesBeforeProjectRules() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "Project says use AGENTS.".write(
            to: tempDir.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )

        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: tempDir,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            globalRules: "Global says prefer concise answers."
        )

        let globalRange = try #require(prompt.range(of: "Global user instructions:"))
        let projectRange = try #require(prompt.range(of: "Project instructions:"))
        #expect(globalRange.lowerBound < projectRange.lowerBound)
        #expect(prompt.contains("Global says prefer concise answers."))
        #expect(prompt.contains("Project says use AGENTS."))
    }

    @Test
    func systemPromptOmitsGlobalSectionWhenRulesAreDisabledOrEmpty() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: tempDir,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            globalRules: nil
        )

        #expect(!prompt.contains("Global user instructions:"))
    }

    @Test
    func toolsPromptRequiresEndToEndCommandExecution() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: tempDir,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            toolsEnabled: true,
            globalRules: nil
        )

        #expect(prompt.contains("Work end-to-end with tools whenever the workspace makes that possible."))
        #expect(prompt.contains("Do not tell the user to run install/build/test/render commands when run_command can do it."))
        #expect(prompt.contains("npm install"))
        #expect(prompt.contains("Verify generated artifacts before your final answer"))
    }

    @Test
    func toolsPromptTracksSidePanelTerminalMachineContext() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let prompt = AgentContextBuilder.systemPrompt(
            rootDirectory: tempDir,
            openedFileURL: nil,
            fileContent: "",
            selectedText: "",
            language: nil,
            toolsEnabled: true,
            globalRules: nil
        )

        #expect(prompt.contains("Treat the visible side-panel terminal as a separate, stateful machine context."))
        #expect(prompt.contains("route to the ACTIVE side-panel tab"))
        #expect(prompt.contains("terminal_list_tabs enumerates every open tab"))
        #expect(prompt.contains("terminal_select_tab makes a tab active"))
        #expect(prompt.contains("local macOS shell or an SSH session"))
        #expect(prompt.contains("do not send commands meant for the local Mac"))
        #expect(prompt.contains("If the active tab is SSH'd into a server"))
        #expect(prompt.contains("never tell the user the side panel or terminal is closed"))
        #expect(prompt.contains("terminal_send_command opens a local shell tab automatically"))
        #expect(prompt.contains("dispatch confirmation does not contain command output"))
        #expect(prompt.contains("bounded automatic follow-up snapshot"))
        #expect(prompt.contains("never call the terminal unstable"))
        #expect(prompt.contains("avoid creating or overwriting files with heredoc"))
        #expect(prompt.contains("small auditable heredoc or patch-style shell fallback is acceptable"))
        // ZMODEM 细则外迁到 bundled skill,提示词只留强制指针 —— 细节改
        // 在 SKILL.md 里断言,提示词契约只保证模型会先去读它。
        #expect(prompt.contains("read_skill \"zmodem-terminal-transfers\""))
        #expect(prompt.contains("Do not improvise the flow from memory"))
        let skillURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("BundledSkills/zmodem-terminal-transfers/SKILL.md")
        let skill = (try? String(contentsOf: skillURL, encoding: .utf8)) ?? ""
        #expect(skill.contains("zmodem_upload_paths"))
        #expect(skill.contains("zmodem_download_directory"))
        #expect(skill.contains("command -v rz sz"))
        #expect(skill.contains("install lrzsz"))
        #expect(skill.contains("scp/rsync"))
    }

    @Test
    func zmodemDetectorClassifiesZrinitFrameAsUpload() throws {
        var detector = TerminalZModemDetector()
        let prompt = Array("rz waiting to receive.\r".utf8)
        #expect(detector.detect(in: prompt) == .display(prompt))

        // ZRINIT ("01"): the remote is the receiver, so the local side sends.
        let start = try #require(startedSession(
            detector.detect(in: [0x2A, 0x2A, 0x18, 0x42, 0x30, 0x31])
        ))
        #expect(isUploadDirection(start.direction))
        #expect(start.protocolBytes.prefix(4) == [0x2A, 0x2A, 0x18, 0x42])
    }

    @Test
    func zmodemDetectorClassifiesZrqinitFrameAsDownload() throws {
        var detector = TerminalZModemDetector()
        let bytes = Array("sending file\r".utf8) + [0x2A, 0x2A, 0x18, 0x42, 0x30, 0x30]

        // ZRQINIT ("00"): the remote is the sender, so the local side receives.
        let start = try #require(startedSession(detector.detect(in: bytes)))
        #expect(isDownloadDirection(start.direction))
        #expect(String(decoding: start.displayPrefix, as: UTF8.self) == "sending file\r")
    }

    @Test
    func zmodemDetectorMatchesTriggerSplitAcrossChunks() throws {
        var detector = TerminalZModemDetector()
        let first = Array("rz\r*".utf8)
        #expect(detector.detect(in: first) == .display(first))

        let start = try #require(startedSession(
            detector.detect(in: [0x2A, 0x18, 0x42, 0x30, 0x30])
        ))
        #expect(isDownloadDirection(start.direction))
        #expect(start.displayPrefix.isEmpty)
        #expect(start.protocolBytes.prefix(4) == [0x2A, 0x2A, 0x18, 0x42])
    }

    @Test
    func zmodemDetectorHoldsTriggerUntilFrameTypeArrives() throws {
        var detector = TerminalZModemDetector()
        let prefix = Array("sending\r".utf8)
        #expect(detector.detect(in: prefix + [0x2A, 0x2A, 0x18, 0x42]) == .hold(display: prefix))
        #expect(detector.isHoldingProtocolTail)

        let start = try #require(startedSession(detector.detect(in: [0x30, 0x31])))
        #expect(isUploadDirection(start.direction))
        #expect(!detector.isHoldingProtocolTail)
    }

    @Test
    func zmodemDetectorReleasesNonHandshakeFramesForDisplay() throws {
        var detector = TerminalZModemDetector()
        // A stray ZFIN ("08") is not a handshake — render it, don't spawn rz.
        let junk: [UInt8] = [0x2A, 0x2A, 0x18, 0x42, 0x30, 0x38]
        #expect(detector.detect(in: junk) == .display(junk))

        // The released junk must not poison a later, genuine handshake.
        let start = startedSession(detector.detect(in: [0x2A, 0x2A, 0x18, 0x42, 0x30, 0x30]))
        #expect(start != nil)
    }

    @Test
    func zmodemDetectorReadsBinaryFrameTypes() throws {
        var detector = TerminalZModemDetector()
        let start = try #require(startedSession(
            detector.detect(in: [0x2A, 0x2A, 0x18, 0x43, 0x00])
        ))
        #expect(isDownloadDirection(start.direction))

        var junkDetector = TerminalZModemDetector()
        let junk: [UInt8] = [0x2A, 0x2A, 0x18, 0x43, 0x7F]
        #expect(junkDetector.detect(in: junk) == .display(junk))
    }

    @Test
    func zmodemToolResolvesPreselectedWorkspacePaths() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("upload.txt")
        try Data("hello".utf8).write(to: fileURL)

        let upload = try AgentTerminalTools.zmodemPathSelection(
            arguments: ["zmodem_upload_paths": .array([.string("upload.txt")])],
            rootDirectory: tempDir
        )
        #expect(upload == .upload(files: [fileURL.standardizedFileURL]))

        let download = try AgentTerminalTools.zmodemPathSelection(
            arguments: ["zmodem_download_directory": .string(".")],
            rootDirectory: tempDir
        )
        #expect(download == .download(directory: tempDir.standardizedFileURL))
    }

    @Test
    func zmodemToolRejectsConflictingPathSelections() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("upload.txt")
        try Data("hello".utf8).write(to: fileURL)

        #expect(throws: AgentToolError.self) {
            try AgentTerminalTools.zmodemPathSelection(
                arguments: [
                    "zmodem_upload_paths": .array([.string(fileURL.path)]),
                    "zmodem_download_directory": .string(tempDir.path),
                ],
                rootDirectory: tempDir
            )
        }
    }

    @Test
    func zmodemPreparedPathIsDirectionBoundAndOneShot() {
        let now = Date()
        let fileURL = URL(fileURLWithPath: "/tmp/upload.txt")
        var prepared = TerminalZModemPreparedSelection(lifetime: 60)
        prepared.prepare(.upload(files: [fileURL]), now: now)

        #expect(prepared.consume(for: .downloadFromRemote, now: now) == nil)
        #expect(prepared.consume(for: .uploadToRemote, now: now) == nil)

        prepared.prepare(.upload(files: [fileURL]), now: now)
        #expect(prepared.consume(for: .uploadToRemote, now: now) == .upload(files: [fileURL]))
        #expect(prepared.consume(for: .uploadToRemote, now: now) == nil)
    }

    @Test
    func zmodemTransferTicketWaitsForProtocolProcessCompletion() async {
        let ticket = TerminalZModemTransferTicket(
            direction: .downloadFromRemote,
            handshakeTimeout: 5
        )
        #expect(ticket.markStarted())
        let waiter = Task {
            await ticket.waitForCompletion()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!ticket.isFinished)

        let expected = TerminalZModemTransferOutcome(
            direction: .downloadFromRemote,
            succeeded: true,
            message: "protocol complete",
            transferredByteCount: 17_000_000
        )
        ticket.finish(expected)
        let outcome = await waiter.value

        #expect(outcome == expected)
        #expect(ticket.isFinished)
    }

    @Test
    func zmodemTransferTicketFailsWhenRemoteHandshakeNeverStarts() async {
        let ticket = TerminalZModemTransferTicket(
            direction: .downloadFromRemote,
            handshakeTimeout: 0.05
        )

        let outcome = await ticket.waitForCompletion()

        #expect(!outcome.succeeded)
        #expect(outcome.transferredByteCount == 0)
        #expect(outcome.message.contains("no completed transfer was confirmed"))
    }

    @Test
    func zmodemTransferTicketCancellationDoesNotLeaveToolWaiting() async {
        let ticket = TerminalZModemTransferTicket(
            direction: .downloadFromRemote,
            handshakeTimeout: 5
        )
        #expect(ticket.markStarted())
        let waiter = Task {
            await ticket.waitForCompletion()
        }

        waiter.cancel()
        let outcome = await waiter.value

        #expect(!outcome.succeeded)
        #expect(outcome.message.contains("was cancelled"))
        #expect(!ticket.isFinished)
    }

    @Test
    func zmodemPTYWriterCompletesShortWritesBeforeAdvancingToNextChunk() {
        let first = Array((0..<4_096).map { UInt8($0 % 251) })
        let second = Array((0..<8_192).map { UInt8(($0 + 73) % 251) })
        var emitted: [UInt8] = []
        var attemptCount = 0
        let writer = TerminalZModemPTYWriter(writeTimeout: 1) { buffer in
            attemptCount += 1
            if attemptCount == 2 || attemptCount == 7 {
                return .retry
            }
            let chunkSize = min((attemptCount % 97) + 1, buffer.count)
            emitted.append(contentsOf: buffer.bindMemory(to: UInt8.self).prefix(chunkSize))
            return .written(chunkSize)
        }

        #expect(writer.write(first))
        #expect(writer.write(second))
        #expect(emitted == first + second)
    }

    @Test
    func zmodemPTYWriterDeliversLargePayloadThroughBackpressuredPipe() async throws {
        let pipe = Pipe()
        let payload = Array((0..<(2 * 1_024 * 1_024)).map { UInt8($0 % 251) })
        let readTask = Task.detached {
            try pipe.fileHandleForReading.readToEnd() ?? Data()
        }
        let writer = TerminalZModemPTYWriter(
            fileDescriptor: pipe.fileHandleForWriting.fileDescriptor,
            writeTimeout: 10
        )

        let delivered = writer.write(payload)
        try pipe.fileHandleForWriting.close()
        let received = try await readTask.value

        #expect(delivered)
        #expect(received == Data(payload))
    }

    @Test
    func zmodemLocalProcessFailsWhenOrderedPTYDeliveryStops() throws {
        let completion = DispatchSemaphore(value: 0)
        let session = try TerminalZModemProcessSession(
            executable: "/bin/cat",
            arguments: [],
            currentDirectory: nil,
            sendToRemote: { _ in false },
            finish: { _ in completion.signal() }
        )

        session.start()
        #expect(isAccepted(session.writeRemoteBytes(Array("trigger output".utf8))))
        #expect(completion.wait(timeout: .now() + 10) == .success)
        #expect(session.endReason == .remoteWriteFailed)
    }

    @Test
    func zmodemLocalProcessDrainsOutputBeforeFinishingAndRejectsLateRemoteBytes() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let payload = Data((0..<(512 * 1_024)).map { UInt8($0 % 251) })
        let payloadURL = tempDir.appendingPathComponent("zmodem-output.bin")
        try payload.write(to: payloadURL)

        let completion = DispatchSemaphore(value: 0)
        let receivedLock = NSLock()
        var received = Data()
        var receivedCountAtFinish = -1
        let session = try TerminalZModemProcessSession(
            executable: "/bin/cat",
            arguments: [payloadURL.path],
            currentDirectory: nil,
            sendToRemote: { bytes in
                receivedLock.lock()
                received.append(contentsOf: bytes)
                receivedLock.unlock()
                return true
            },
            finish: { _ in
                receivedLock.lock()
                receivedCountAtFinish = received.count
                receivedLock.unlock()
                completion.signal()
            }
        )

        session.start()
        #expect(completion.wait(timeout: .now() + 10) == .success)

        receivedLock.lock()
        let finalReceived = received
        let finalCountAtFinish = receivedCountAtFinish
        receivedLock.unlock()
        #expect(finalReceived == payload)
        #expect(finalCountAtFinish == payload.count)
        #expect(isProcessExited(session.writeRemoteBytes(Array("prompt".utf8))))
    }

    @Test
    func zmodemLocalProcessIdleWatchdogAbortsDeadSessions() throws {
        let completion = DispatchSemaphore(value: 0)
        let sentLock = NSLock()
        var sent = Data()
        // `cat` with an open stdin and no input models a dead handshake:
        // no bytes move in either direction, so the watchdog must fire.
        let session = try TerminalZModemProcessSession(
            executable: "/bin/cat",
            arguments: [],
            currentDirectory: nil,
            idleTimeout: 0.5,
            sendToRemote: { bytes in
                sentLock.lock()
                sent.append(contentsOf: bytes)
                sentLock.unlock()
                return true
            },
            finish: { _ in completion.signal() }
        )

        session.start()
        #expect(completion.wait(timeout: .now() + 10) == .success)
        #expect(session.endReason == .timedOut)
        sentLock.lock()
        let finalSent = sent
        sentLock.unlock()
        // The remote must see the ZMODEM cancel burst so its rz/sz aborts
        // too, instead of leaving the remote shell hung.
        #expect(finalSent.contains(0x18))
    }

    @Test
    func zmodemLocalProcessEchoesAsyncWritesAndAbortsOnRequest() throws {
        let payload = Array("hello zmodem".utf8)
        let completion = DispatchSemaphore(value: 0)
        let echoed = DispatchSemaphore(value: 0)
        let sentLock = NSLock()
        var sent = Data()
        let session = try TerminalZModemProcessSession(
            executable: "/bin/cat",
            arguments: [],
            currentDirectory: nil,
            idleTimeout: 30,
            sendToRemote: { bytes in
                sentLock.lock()
                sent.append(contentsOf: bytes)
                let enough = sent.count >= payload.count
                sentLock.unlock()
                if enough { echoed.signal() }
                return true
            },
            finish: { _ in completion.signal() }
        )

        session.start()
        #expect(isAccepted(session.writeRemoteBytes(payload)))
        #expect(echoed.wait(timeout: .now() + 10) == .success)

        session.abort(reason: .userCancelled)
        #expect(completion.wait(timeout: .now() + 10) == .success)
        #expect(session.endReason == .userCancelled)
        sentLock.lock()
        let finalSent = sent
        sentLock.unlock()
        #expect(finalSent.prefix(payload.count) == Data(payload))
        #expect(session.transferredByteCount(for: .downloadFromRemote) == payload.count)
    }

    private func startedSession(_ detection: TerminalZModemDetection) -> TerminalZModemStart? {
        if case .start(let start) = detection {
            return start
        }
        return nil
    }

    private func isAccepted(_ result: TerminalZModemRemoteWriteResult) -> Bool {
        if case .accepted = result {
            return true
        }
        return false
    }

    private func isProcessExited(_ result: TerminalZModemRemoteWriteResult) -> Bool {
        if case .processExited = result {
            return true
        }
        return false
    }

    private func isUploadDirection(_ direction: TerminalZModemDirection) -> Bool {
        if case .uploadToRemote = direction {
            return true
        }
        return false
    }

    private func isDownloadDirection(_ direction: TerminalZModemDirection) -> Bool {
        if case .downloadFromRemote = direction {
            return true
        }
        return false
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-global-rules-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
