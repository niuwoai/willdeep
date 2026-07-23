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
        #expect(prompt.contains("avoid creating or overwriting files with heredoc"))
        #expect(prompt.contains("WillDeep's visible side-panel terminal supports rz/sz ZMODEM transfers"))
        #expect(prompt.contains("zmodem_upload_paths"))
        #expect(prompt.contains("zmodem_download_directory"))
        #expect(prompt.contains("command -v rz sz"))
        #expect(prompt.contains("install lrzsz"))
        #expect(prompt.contains("small auditable heredoc or patch-style shell fallback is acceptable"))
        #expect(prompt.contains("remote host cannot install lrzsz"))
    }

    @Test
    func zmodemDetectorClassifiesRemoteRzPromptAsUpload() throws {
        var detector = TerminalZModemDetector()
        #expect(detector.detect(in: Array("rz waiting to receive.\r".utf8)) == nil)

        let maybeStart = detector.detect(in: [0x2A, 0x2A, 0x18, 0x42, 0x30, 0x31])
        let start = try #require(maybeStart)
        #expect(isUploadDirection(start.direction))
        #expect(start.protocolBytes.prefix(4) == [0x2A, 0x2A, 0x18, 0x42])
    }

    @Test
    func zmodemDetectorDefaultsRemoteSzHandshakeToDownload() throws {
        var detector = TerminalZModemDetector()
        let bytes = Array("sending file\r".utf8) + [0x2A, 0x2A, 0x18, 0x42, 0x30, 0x30]

        let maybeStart = detector.detect(in: bytes)
        let start = try #require(maybeStart)
        #expect(isDownloadDirection(start.direction))
        #expect(String(decoding: start.displayPrefix, as: UTF8.self) == "sending file\r")
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
