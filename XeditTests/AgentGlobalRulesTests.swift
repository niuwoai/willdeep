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

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-global-rules-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
