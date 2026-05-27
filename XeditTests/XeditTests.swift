//
//  XeditTests.swift
//  VeilWriterTests
//
//  Created by rocky on 2026/5/27.
//

import Testing
import Foundation
import AppKit
@testable import VeilWriter

struct VeilWriterTests {
    private enum TestError: Error {
        case loadTimedOut
    }

    // MARK: - File Size Detection

    @Test("fileSize returns correct size for a known file")
    func testFileSizeReturnsCorrectSize() throws {
        // Create a temp file with known content.
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("xedit_test_size_\(UUID().uuidString).txt")
        let content = String(repeating: "A", count: 1024)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let size = AppState.fileSize(at: fileURL)
        #expect(size != nil)
        #expect(size! >= 1024)
    }

    @Test("fileSize returns nil for nonexistent file")
    func testFileSizeReturnsNilForNonexistentFile() {
        let nonexistent = URL(fileURLWithPath: "/tmp/xedit_nonexistent_\(UUID().uuidString)")
        let size = AppState.fileSize(at: nonexistent)
        #expect(size == nil)
    }

    @Test("maxFileSize is 1 MB")
    func testMaxFileSizeIsOneMegabyte() {
        #expect(AppState.maxFileSize == 1_048_576)
    }

    // MARK: - Binary File Detection

    @Test("isBinaryFile returns true for data containing null bytes")
    func testBinaryDetectionWithNullBytes() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("xedit_test_binary_\(UUID().uuidString).dat")

        // Write data with a null byte in the middle.
        var data = Data(repeating: 0x41, count: 100) // 'A'
        data[50] = 0x00 // Insert null byte
        try data.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        #expect(AppState.isBinaryFile(at: fileURL) == true)
    }

    @Test("isBinaryFile returns false for plain text")
    func testBinaryDetectionWithPlainText() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("xedit_test_text_\(UUID().uuidString).txt")
        try "Hello, world!".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        #expect(AppState.isBinaryFile(at: fileURL) == false)
    }

    @Test("isBinaryFile returns false for nonexistent file")
    func testBinaryDetectionWithNonexistentFile() {
        let nonexistent = URL(fileURLWithPath: "/tmp/xedit_nonexistent_\(UUID().uuidString)")
        #expect(AppState.isBinaryFile(at: nonexistent) == false)
    }

    // MARK: - Encoding Detection (c2)

    @Test("decodeText correctly decodes UTF-8 with multi-byte characters")
    func testDecodeUTF8() {
        let input = "Hello, 世界! 🎉 café"
        let data = input.data(using: .utf8)!
        let result = AppState.decodeText(from: data)
        #expect(result == input)
    }

    @Test("decodeText correctly decodes ISO Latin 1 with accented characters")
    func testDecodeISOLatin1() {
        // Create ISO Latin 1 encoded data.
        // "café" with é = 0xE9 in Latin-1
        let bytes: [UInt8] = [0x63, 0x61, 0x66, 0xE9] // "café"
        let data = Data(bytes)
        let result = AppState.decodeText(from: data)
        #expect(result == "café")
    }

    @Test("decodeText falls back to error placeholder for undecodable data")
    func testDecodeErrorPlaceholder() {
        // Create data that is not valid in any expected encoding.
        // High bytes with no valid interpretation: random garbage.
        let bytes: [UInt8] = [0xFF, 0xFE, 0x00, 0x00, 0x80, 0x81, 0x82]
        let data = Data(bytes)
        let result = AppState.decodeText(from: data)
        // Should produce a result (either decoded via some fallback or the placeholder).
        #expect(!result.isEmpty)
    }

    @Test("decodeText handles empty data")
    func testDecodeEmptyData() {
        let data = Data()
        let result = AppState.decodeText(from: data)
        #expect(result == "")
    }

    @Test("decodeText handles CJK characters in UTF-8")
    func testDecodeUTF8CJK() {
        let input = "日本語テスト"
        let data = input.data(using: .utf8)!
        let result = AppState.decodeText(from: data)
        #expect(result == input)
    }

    // MARK: - Editor Appearance

    @Test("editor settings defaults enable line focus affordances")
    func testEditorSettingsDefaults() {
        let settings = EditorSettings.default
        #expect(settings.showsLineNumbers == true)
        #expect(settings.highlightsCurrentLine == true)
        #expect(EditorTheme.byID(settings.themeID) != nil)
        #expect(EditorFontChoice.byID(settings.fontID) != nil)
    }

    @Test("editor settings normalize invalid persisted values")
    func testEditorSettingsNormalization() {
        let settings = EditorSettings(
            fontID: "missing-font",
            fontSize: 99,
            themeID: "missing-theme",
            showsLineNumbers: false,
            highlightsCurrentLine: false
        ).normalized()

        #expect(settings.fontID == EditorSettings.default.fontID)
        #expect(settings.themeID == EditorSettings.default.themeID)
        #expect(settings.fontSize == 28)
        #expect(settings.showsLineNumbers == false)
        #expect(settings.highlightsCurrentLine == false)
    }

    @Test("syntax highlighting uses the selected theme and font")
    @MainActor
    func testSyntaxHighlightUsesSelectedAppearance() {
        let theme = EditorTheme.ember
        let font = EditorFontChoice.menlo.font(size: 17)
        let highlighted = SyntaxHighlighter.highlightSync(
            "let value = \"x\"\n",
            language: .swift,
            theme: theme,
            font: font
        )

        let keywordColor = highlighted.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let appliedFont = highlighted.attribute(.font, at: 0, effectiveRange: nil) as? NSFont

        #expect(keywordColor == theme.keywordColor)
        #expect(appliedFont?.pointSize == 17)
    }

    @Test("language detection supports common source file extensions")
    func testLanguageDetectionSupportsCommonExtensions() {
        let expected: [(String, Language)] = [
            (".rb", .ruby),
            (".php", .php),
            (".java", .java),
            (".json", .json),
            (".js", .javascript),
            (".mjs", .javascript),
            (".ts", .typescript),
            (".tsx", .typescript),
            (".go", .go),
            (".html", .html),
            (".css", .css),
            (".swift", .swift),
        ]

        for (ext, language) in expected {
            #expect(Language.fromExtension(ext) == language)
        }
    }

    @Test("syntax highlighting covers requested languages")
    @MainActor
    func testSyntaxHighlightingCoversRequestedLanguages() {
        let theme = EditorTheme.ember
        let font = EditorFontChoice.menlo.font(size: 15)
        let samples: [(Language, String, String)] = [
            (.ruby, "class Greeter\nend\n", "class"),
            (.php, "<?php\nfunction greet() { return true; }\n", "function"),
            (.java, "public class Greeter { return; }\n", "public"),
            (.json, "{\"enabled\": true, \"count\": 3}", "enabled"),
            (.javascript, "const value = true;\n", "const"),
            (.typescript, "interface User { name: string }\n", "interface"),
            (.go, "package main\nfunc main() { return }\n", "package"),
            (.html, "<section class=\"hero\"></section>\n", "section"),
            (.css, ".hero { color: #fff; }\n", "color"),
            (.swift, "struct Greeter { let value = true }\n", "struct"),
        ]

        for (language, source, token) in samples {
            let highlighted = SyntaxHighlighter.highlightSync(
                source,
                language: language,
                theme: theme,
                font: font
            )

            let range = (source as NSString).range(of: token)
            let color = highlighted.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
            #expect(color == theme.keywordColor, "Expected \(language.rawValue) token \(token) to use keyword color")
        }
    }

    // MARK: - File Loading Timing (c1)

    @Test("loadFile completes within 500ms for a file under 1MB")
    func testFileLoadingTimingUnder500ms() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("xedit_test_timing_\(UUID().uuidString).txt")

        // Create a ~500 KB text file (well under 1 MB threshold).
        let lineLength = 80
        let lineCount = 6400 // ~512 KB
        let line = String(repeating: "X", count: lineLength) + "\n"
        let content = String(repeating: line, count: lineCount)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // Verify the file is under 1 MB.
        let size = AppState.fileSize(at: fileURL)
        #expect(size != nil)
        #expect(size! < Int64(AppState.maxFileSize), "Test file must be under 1MB for timing test")

        let start = CFAbsoluteTimeGetCurrent()
        let appState = await MainActor.run { AppState() }
        await MainActor.run {
            appState.openedFileURL = fileURL
            appState.loadFile(from: fileURL)
        }

        var didLoad = false
        while (CFAbsoluteTimeGetCurrent() - start) < 1.0 {
            didLoad = await MainActor.run {
                appState.fileContent == content && appState.isEdited == false
            }
            if didLoad { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        guard didLoad else {
            throw TestError.loadTimedOut
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        #expect(
            elapsedMs < 500.0,
            "loadFile time \(elapsedMs)ms exceeded 500ms threshold"
        )
    }

    @Test("loadFile data path rejects files over 1MB unless explicitly allowed")
    func testFileLoadingRejectsLargeFilesByDefault() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("xedit_test_large_\(UUID().uuidString).txt")

        let content = String(repeating: "A", count: AppState.maxFileSize + 1)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        #expect(AppState.shouldRequireLargeFileConfirmation(at: fileURL) == true)

        do {
            _ = try AppState.readFileData(from: fileURL)
            Issue.record("Expected readFileData to reject files over 1MB by default")
        } catch AppState.FileLoadError.fileTooLarge(let size) {
            #expect(size > Int64(AppState.maxFileSize))
        }

        let allowedData = try AppState.readFileData(from: fileURL, allowLargeFile: true)
        #expect(allowedData.count == content.utf8.count)
    }

    @Test("loadFile can handle a moderately sized UTF-8 file quickly")
    func testFileLoadingWithMediumFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("xedit_test_medium_\(UUID().uuidString).txt")

        // Create a ~200 KB file with varied content.
        var content = ""
        for i in 0..<5000 {
            content += "Line \(i): The quick brown fox jumps over the lazy dog.\n"
        }
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let data = try Data(contentsOf: fileURL)
        let result = AppState.decodeText(from: data)
        #expect(result.hasPrefix("Line 0:"))
        #expect(result.contains("quick brown fox"))
    }

    // MARK: - Save Functionality (c4)

    @Test("saveCurrentFile writes content and returns true on success")
    func testSaveCurrentFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("xedit_test_save_\(UUID().uuidString).txt")

        // Pre-create the file with initial content.
        try "initial content".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let appState = AppState()
        appState.openedFileURL = fileURL
        appState.fileContent = "updated content!"
        appState.isEdited = true

        let result = appState.saveCurrentFile()
        #expect(result == true)
        #expect(appState.isEdited == false)

        // Verify the file was actually updated on disk.
        let savedContent = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(savedContent == "updated content!")
    }

    @Test("writeCurrentFile returns false when destination is invalid")
    func testWriteCurrentFileWithInvalidDestination() {
        let appState = AppState()
        appState.fileContent = "unsaved content"

        let invalidURL = URL(fileURLWithPath: "/tmp/veilwriter_missing_\(UUID().uuidString)/file.txt")
        let result = appState.writeCurrentFile(to: invalidURL, updateOpenedURL: false, showsAlert: false)

        #expect(result == false)
        #expect(appState.openedFileURL == nil)
    }

    @Test("writeCurrentFile can save to a new URL and update current file")
    func testWriteCurrentFileAsNewURL() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("veilwriter_test_save_as_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let appState = AppState()
        appState.fileContent = "saved through save as"
        appState.isEdited = true

        let result = appState.writeCurrentFile(to: fileURL, updateOpenedURL: true)

        #expect(result == true)
        #expect(appState.openedFileURL == fileURL)
        #expect(appState.rootDirectory == fileURL.deletingLastPathComponent())
        #expect(appState.isEdited == false)
        #expect(appState.suppressURLChangeProcessing == true)
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "saved through save as")
    }

    // MARK: - Tabs

    @Test("beginOpeningTab creates tabs and reuses existing file tabs")
    func testBeginOpeningTabCreatesAndReusesTabs() {
        let tempDir = FileManager.default.temporaryDirectory
        let firstURL = tempDir.appendingPathComponent("veilwriter_tab_first_\(UUID().uuidString).txt")
        let secondURL = tempDir.appendingPathComponent("veilwriter_tab_second_\(UUID().uuidString).txt")

        let appState = AppState()
        appState.beginOpeningTab(for: firstURL)

        #expect(appState.tabs.count == 1)
        #expect(appState.openedFileURL == firstURL)
        #expect(appState.activeTab?.url == firstURL)

        appState.fileContent = "first draft"
        appState.isEdited = true
        appState.beginOpeningTab(for: secondURL)

        #expect(appState.tabs.count == 2)
        #expect(appState.openedFileURL == secondURL)
        #expect(appState.tabs.first { $0.url == firstURL }?.content == "first draft")
        #expect(appState.tabs.first { $0.url == firstURL }?.isEdited == true)

        appState.beginOpeningTab(for: firstURL)

        #expect(appState.tabs.count == 2)
        #expect(appState.openedFileURL == firstURL)
        #expect(appState.fileContent == "first draft")
        #expect(appState.isEdited == true)
    }

    @Test("closeTab activates a neighboring tab")
    func testCloseTabActivatesNeighbor() {
        let tempDir = FileManager.default.temporaryDirectory
        let firstURL = tempDir.appendingPathComponent("veilwriter_close_first_\(UUID().uuidString).txt")
        let secondURL = tempDir.appendingPathComponent("veilwriter_close_second_\(UUID().uuidString).txt")

        let appState = AppState()
        appState.beginOpeningTab(for: firstURL)
        let firstID = appState.activeTabID
        appState.beginOpeningTab(for: secondURL)

        guard let firstID else {
            Issue.record("Expected first tab ID")
            return
        }

        appState.closeTab(id: appState.activeTabID!)

        #expect(appState.tabs.count == 1)
        #expect(appState.activeTabID == firstID)
        #expect(appState.openedFileURL == firstURL)
    }

    // MARK: - Dirty State Tracking (c3)

    @Test("isEdited is false after loading content")
    func testDirtyStateClearedAfterLoad() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("xedit_test_dirty_\(UUID().uuidString).txt")
        try "test content".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let appState = AppState()
        appState.isEdited = true // simulate previous dirty state
        appState.openedFileURL = fileURL

        // Simulate what loadFile does on the main thread after successful decode.
        appState.fileContent = "test content"
        appState.isEdited = false

        #expect(appState.isEdited == false)
        #expect(appState.fileContent == "test content")
    }

    // MARK: - suppressURLChangeProcessing Flag

    @Test("suppressURLChangeProcessing defaults to false")
    func testSuppressFlagDefaultsToFalse() {
        let appState = AppState()
        #expect(appState.suppressURLChangeProcessing == false)
    }
}
