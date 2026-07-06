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
        #expect(AgentGlobalRulesStore.defaultRulesTemplate.contains("# Codex 规则（严格条款）"))
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
        #expect(prompt.contains("local macOS shell, an SSH session"))
        #expect(prompt.contains("do not send commands that are meant to run locally on the Mac"))
        #expect(prompt.contains("If the active terminal is SSH'd into a server"))
        #expect(prompt.contains("avoid creating or overwriting files with heredoc"))
        #expect(prompt.contains("WillDeep's visible side-panel terminal supports rz/sz ZMODEM transfers"))
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
