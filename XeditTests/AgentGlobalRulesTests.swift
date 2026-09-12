//
//  AgentGlobalRulesTests.swift
//  WillDeepTests
//
//  Covers user-level Agent rules loading and system prompt injection.
//

import Foundation
import Darwin
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
    func defaultRulesTemplateIsACompactBundledLibraryIndex() {
        let template = AgentGlobalRulesStore.defaultRulesTemplate

        #expect(template.contains("# WillDeep 全局规则（精简索引）"))
        #expect(template.contains(AgentBundledRules.rootPlaceholder))
        #expect(template.contains(AgentBundledRules.readerToolName))
        #expect(template.contains("ai-guardrails.md"))
        #expect(template.contains("version-control.md"))
        #expect(template.contains("不要一次性读取整个目录"))
        #expect(!template.contains("<!-- BEGIN ALMA AGENTRULES SYNC -->"))
        #expect(template.count < 2_000)
    }

    @Test
    func bundledRuleReaderReadsManifestFileWithoutWorkspaceAccess() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rulesRoot = try #require(AgentBundledRules.rootURL(sourceRoot: repositoryRoot))

        let result = try AgentBundledRules.readRule(named: "programming.md", rootURL: rulesRoot)

        #expect(result.summary == "Read bundled rule programming.md")
        #expect(result.payload.contains("编程最佳实践"))
    }

    @Test
    func bundledRuleReaderRejectsUnknownAndTraversalPaths() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rulesRoot = try #require(AgentBundledRules.rootURL(sourceRoot: repositoryRoot))

        #expect(throws: AgentToolError.self) {
            try AgentBundledRules.readRule(named: "../AGENTS.md", rootURL: rulesRoot)
        }
        #expect(throws: AgentToolError.self) {
            try AgentBundledRules.readRule(named: "not-a-rule.md", rootURL: rulesRoot)
        }
    }

    @Test
    func untouchedCompactIndexMigratesToNativeRuleReaderInstructions() {
        #expect(AgentGlobalRulesStore.shouldMigrateLegacyDefaultRulesFile(
            settings: .default,
            fileText: AgentBundledRules.previousDefaultGlobalRulesTemplate
        ))
        #expect(!AgentGlobalRulesStore.shouldMigrateLegacyDefaultRulesFile(
            settings: .default,
            fileText: AgentBundledRules.previousDefaultGlobalRulesTemplate + "\n个人偏好"
        ))
    }

    @Test
    func bundledRuleReaderIsAReadOnlyCoreToolAvailableToFileReadingWorkers() throws {
        let descriptor = try #require(AgentToolRegistry.all.first {
            $0.name == AgentBundledRules.readerToolName
        })

        #expect(descriptor.risk == .read)
        #expect(AgentToolPackCatalog.coreToolNames.contains(AgentBundledRules.readerToolName))
        #expect(AgentSubagentRunner.allowedToolNames.contains(AgentBundledRules.readerToolName))
        #expect(AgentSubagentProfileCatalog.reader.effectiveToolNames().contains(
            AgentBundledRules.readerToolName
        ))
        #expect(!AgentSubagentProfileCatalog.smallReviewer.effectiveToolNames().contains(
            AgentBundledRules.readerToolName
        ))
    }

    @Test
    func bundledRulesResolveAStableLocalDirectoryAndManifest() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rulesRoot = try #require(AgentBundledRules.rootURL(sourceRoot: repositoryRoot))
        let manifest = try #require(AgentBundledRules.manifest(rootURL: rulesRoot))

        #expect(rulesRoot.lastPathComponent == AgentBundledRules.directoryName)
        #expect(manifest.rulesVersion == "0.21.0")
        #expect(manifest.files.contains("AGENTS.md"))
        #expect(manifest.files.contains("programming.md"))
    }

    @Test
    func bundledRulesPlaceholderResolvesOnlyAtPromptLoadTime() {
        let root = URL(fileURLWithPath: "/Applications/WillDeep.app/Contents/Resources/BundledAgentRules")
        let raw = "Rules: `\(AgentBundledRules.rootPlaceholder)`"
        let resolved = AgentBundledRules.resolvingRootPlaceholder(in: raw, rootURL: root)

        #expect(raw.contains(AgentBundledRules.rootPlaceholder))
        #expect(resolved.contains(root.path))
        #expect(!resolved.contains(AgentBundledRules.rootPlaceholder))
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
        #expect(!AgentGlobalRulesStore.shouldMigrateLegacyDefaultRulesFile(
            settings: AgentGlobalRulesSettings.default,
            fileText: "user customized rules"
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

        // 这些断言守的是「终端条款别被合并吃掉半句」。1.284.0-rc5 压缩稳定
        // 契约时改写了措辞，约束逐条仍在，但字面锚点全变了——当时用
        // `--without-building` 验证，跑的是没编译进改动的旧二进制，拿到假
        // 全绿，红了整整一天没人看见。锚点已按 v32 措辞重挂。
        #expect(prompt.contains("separate, stateful machine that may be a remote SSH host"))
        #expect(prompt.contains("route to the ACTIVE tab unless terminal_tab_id"))
        #expect(prompt.contains("terminal_list_tabs enumerates tabs"))
        #expect(prompt.contains("terminal_select_tab switches visibly"))
        #expect(prompt.contains("a local shell or which host/user/directory the SSH session shows"))
        #expect(prompt.contains("Never send local Mac or workspace commands into an SSH tab"))
        #expect(prompt.contains("If the host is unclear, snapshot or ask one concrete question"))
        #expect(prompt.contains("rather than claiming the terminal was routed"))
        #expect(prompt.contains("implicit routing stays blocked"))
        #expect(prompt.contains("terminal_send_command may open a local shell itself"))
        #expect(prompt.contains("dispatch confirmation is not command output"))
        #expect(prompt.contains("one bounded follow-up snapshot"))
        #expect(prompt.contains("never call the terminal unstable"))
        #expect(prompt.contains("Only the user may start saved shortcut playback"))
        #expect(prompt.contains("do not create or overwrite files with heredoc"))
        #expect(prompt.contains("A small auditable heredoc is acceptable only when the terminal is the only path"))
        // ZMODEM 细则外迁到 bundled skill,提示词只留强制指针 —— 细节改
        // 在 SKILL.md 里断言,提示词契约只保证模型会先去读它。
        #expect(prompt.contains("read_skill \"zmodem-terminal-transfers\""))
        #expect(prompt.contains("do not improvise the flow"))
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
        let readFD = pipe.fileHandleForReading.fileDescriptor
        let writeFD = pipe.fileHandleForWriting.fileDescriptor
        // A concurrent process may retain a pipe writer after our original
        // handle closes. Keep such an alias alive deliberately: receiving the
        // exact frame must not require EOF from every holder of that pipe.
        let heldWriter = Darwin.dup(writeFD)
        try #require(heldWriter >= 0)
        defer { Darwin.close(heldWriter) }
        defer { try? pipe.fileHandleForReading.close() }
        for descriptor in [readFD, writeFD, heldWriter] {
            try #require(Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0)
        }
        let flags = Darwin.fcntl(writeFD, F_GETFL)
        try #require(flags >= 0)
        try #require(Darwin.fcntl(writeFD, F_SETFL, flags | O_NONBLOCK) == 0)

        let (results, continuation) = AsyncStream<Data>.makeStream()
        let expectedCount = payload.count
        // Do not occupy a cooperative executor with blocking readToEnd while
        // the writer (and hundreds of unrelated tests) need that executor.
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.yield(Self.readPipePayload(readFD, expectedCount: expectedCount))
            continuation.finish()
        }
        // 90s 而不是 10s。2 MiB 过一个 64 KiB 的管道要读写两端交替唤醒约 32
        // 次，而读端那个 DispatchQueue.global 块在满载全量下拿不到线程，于是
        // 写端在 EAGAIN 上转到超时、读端一个字节没收到（实测 delivered=false
        // 且 received=0）。判据是「整帧原样送达」，不是「多快送达」。
        let writer = TerminalZModemPTYWriter(
            fileDescriptor: writeFD,
            writeTimeout: 90
        )

        let delivered = writer.write(payload)
        try pipe.fileHandleForWriting.close()
        var iterator = results.makeAsyncIterator()
        let received = try #require(await iterator.next())

        #expect(delivered)
        #expect(received.count == payload.count)
        #expect(received == Data(payload))
    }

    /// Bounded test-only receiver. A missing byte becomes a failed assertion,
    /// not an indefinite EOF wait that prevents the entire suite finishing.
    private nonisolated static func readPipePayload(_ descriptor: Int32, expectedCount: Int) -> Data {
        let clock = ContinuousClock()
        // 和写端的 writeTimeout 成对放宽：两边都是 10s 时，谁先被饿到都会让
        // 这条用例假红。仍然是有界的——缺字节照样变成失败断言，不会无限等。
        let deadline = clock.now.advanced(by: .seconds(90))
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while received.count < expectedCount, clock.now < deadline {
            var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&readiness, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            let remaining = min(buffer.count, expectedCount - received.count)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, remaining)
            }
            if count > 0 {
                received.append(contentsOf: buffer.prefix(count))
            } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                break
            }
        }
        return received
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
