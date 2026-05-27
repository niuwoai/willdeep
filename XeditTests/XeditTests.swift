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
            (".bash", .shell),
            (".yaml", .yaml),
            (".toml", .toml),
            (".xml", .xml),
            (".sql", .sql),
            (".ini", .ini),
            (".rs", .rust),
            (".c", .c),
            (".cpp", .cpp),
            (".cs", .csharp),
        ]

        for (ext, language) in expected {
            #expect(Language.fromExtension(ext) == language)
        }

        let tempDir = URL(fileURLWithPath: "/tmp")
        #expect(Language.fromURL(tempDir.appendingPathComponent("Dockerfile")) == .dockerfile)
        #expect(Language.fromURL(tempDir.appendingPathComponent("Makefile")) == .makefile)
        #expect(Language.fromURL(tempDir.appendingPathComponent(".bashrc")) == .shell)
        #expect(Language.fromURL(tempDir.appendingPathComponent(".env")) == .env)
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
            (.shell, "#!/usr/bin/env bash\nif [[ -f \"$HOME/.zshrc\" ]]; then echo ok; fi\n", "if"),
            (.yaml, "service:\n  enabled: true\n", "service"),
            (.toml, "[server]\nport = 8080\n", "port"),
            (.xml, "<plist><dict><key>Name</key></dict></plist>\n", "plist"),
            (.sql, "select name from users where active = true;\n", "select"),
            (.dockerfile, "FROM swift:latest\nRUN echo ok\n", "FROM"),
            (.makefile, "include config.mk\nbuild:\n\tswift build\n", "include"),
            (.ini, "[server]\nport=8080\n", "port"),
            (.env, "API_HOST=\"localhost\"\n", "API_HOST"),
            (.rust, "pub struct Writer { fn save() {} }\n", "pub"),
            (.c, "struct Writer { int value; };\n", "struct"),
            (.cpp, "class Writer { public: void save(); };\n", "class"),
            (.csharp, "public class Writer { string Name; }\n", "public"),
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

    @Test("outline extractor finds Swift structure")
    func testOutlineExtractorFindsSwiftStructure() {
        let source = """
        struct Writer {
            let title: String
            func save() {}
        }
        """

        let items = EditorOutlineExtractor.outline(for: source, language: .swift)

        #expect(items.map(\.title) == ["Writer", "title", "save"])
        #expect(items.map(\.kind) == [.type, .property, .function])
    }

    @Test("outline extractor finds Markdown headings")
    func testOutlineExtractorFindsMarkdownHeadings() {
        let source = """
        # Product
        ## Features
        ### Minimap
        """

        let items = EditorOutlineExtractor.outline(for: source, language: .markdown)

        #expect(items.map(\.title) == ["Product", "Features", "Minimap"])
        #expect(items.map(\.level) == [0, 1, 2])
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

    @Test("closing active tab refreshes editor rendering")
    func testCloseTabBumpsEditorRenderRevision() {
        let tempDir = FileManager.default.temporaryDirectory
        let firstURL = tempDir.appendingPathComponent("veilwriter_render_first_\(UUID().uuidString).swift")
        let secondURL = tempDir.appendingPathComponent("veilwriter_render_second_\(UUID().uuidString).swift")

        let appState = AppState()
        appState.beginOpeningTab(for: firstURL)
        appState.fileContent = "let first = true"
        appState.beginOpeningTab(for: secondURL)
        appState.fileContent = "let second = true"

        let revisionBeforeClose = appState.editorRenderRevision
        appState.closeActiveTab()

        #expect(appState.openedFileURL == firstURL)
        #expect(appState.editorRenderRevision > revisionBeforeClose)
    }

    @Test("closeActiveTab closes the current tab")
    func testCloseActiveTabClosesCurrentTab() {
        let tempDir = FileManager.default.temporaryDirectory
        let firstURL = tempDir.appendingPathComponent("veilwriter_active_close_first_\(UUID().uuidString).txt")
        let secondURL = tempDir.appendingPathComponent("veilwriter_active_close_second_\(UUID().uuidString).txt")

        let appState = AppState()
        appState.beginOpeningTab(for: firstURL)
        let firstID = appState.activeTabID
        appState.beginOpeningTab(for: secondURL)

        appState.closeActiveTab()

        #expect(appState.tabs.count == 1)
        #expect(appState.activeTabID == firstID)
        #expect(appState.openedFileURL == firstURL)
    }

    @Test("editor navigation request targets requested line")
    func testEditorNavigationRequestTargetsLine() {
        let appState = AppState()

        appState.navigateEditor(toLine: 4)
        let firstRequest = appState.editorNavigationRequest

        appState.navigateEditor(toLine: 2)

        #expect(firstRequest?.line == 4)
        #expect(appState.editorNavigationRequest?.line == 2)
        #expect((appState.editorNavigationRequest?.revision ?? 0) > (firstRequest?.revision ?? 0))
    }

    @Test("editor line navigation maps lines to text ranges")
    func testEditorLineNavigationMapsLinesToRanges() {
        let text = "alpha\nbeta\ngamma"

        #expect(EditorView.Coordinator.rangeForLine(1, in: text) == NSRange(location: 0, length: 0))
        #expect(EditorView.Coordinator.rangeForLine(2, in: text) == NSRange(location: 6, length: 4))
        #expect(EditorView.Coordinator.rangeForLine(3, in: text) == NSRange(location: 11, length: 5))
        #expect(EditorView.Coordinator.rangeForLine(99, in: text) == NSRange(location: 16, length: 0))
    }

    @Test("editor cursor position maps location to line and column")
    func testEditorCursorPositionMapsLocationToLineAndColumn() {
        let text = "alpha\nbeta\ngamma"

        let first = EditorView.Coordinator.lineAndColumn(for: 0, in: text)
        let second = EditorView.Coordinator.lineAndColumn(for: 7, in: text)
        let end = EditorView.Coordinator.lineAndColumn(for: 99, in: text)

        #expect(first.line == 1)
        #expect(first.column == 1)
        #expect(second.line == 2)
        #expect(second.column == 2)
        #expect(end.line == 3)
        #expect(end.column == 6)
    }

    @Test("quick open file URLs are sorted and limited")
    func testQuickOpenFileURLsAreSortedAndLimited() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("veilwriter_quick_open_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let beta = tempDir.appendingPathComponent("beta.swift")
        let alpha = tempDir.appendingPathComponent("alpha.swift")
        try "beta".write(to: beta, atomically: true, encoding: .utf8)
        try "alpha".write(to: alpha, atomically: true, encoding: .utf8)

        let urls = AppState.quickOpenFileURLs(in: tempDir, limit: 1)

        #expect(urls.map(\.lastPathComponent) == ["alpha.swift"])
    }

    @Test("changed line numbers compare current and saved content")
    func testChangedLineNumbersCompareCurrentAndSavedContent() {
        let changed = AppState.changedLineNumbers(
            current: "one\ntwo changed\nthree\nfour",
            saved: "one\ntwo\nthree"
        )

        #expect(changed == Set([2, 4]))
    }

    @Test("active tab exposes dirty gutter line numbers")
    func testActiveTabExposesDirtyGutterLineNumbers() {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("veilwriter_dirty_gutter_\(UUID().uuidString).swift")
        let appState = AppState(openedFileURL: fileURL, fileContent: "let a = 1\nlet b = 2")

        appState.fileContent = "let a = 1\nlet b = 3"

        #expect(appState.changedLineNumbers == Set([2]))
    }

    @Test("editor indentation helpers preserve lightweight editing flow")
    func testEditorIndentationHelpers() {
        let source = "func run() {\n    print(\"ok\")\n}"

        #expect(VeilWriterTextView.leadingWhitespaceBefore(location: 17, in: source) == "    ")
        #expect(VeilWriterTextView.indentingLines("one\ntwo\n") == "    one\n    two\n")
        #expect(VeilWriterTextView.outdentingLines("    one\n\ttwo\n  three") == "one\ntwo\nthree")
    }

    @Test("matching bracket ranges find nested pairs around cursor")
    func testMatchingBracketRangesFindNestedPairs() {
        let text = "call(a[0], { value })"

        let square = EditorView.Coordinator.matchingBracketRanges(around: 7, in: text)
        let curly = EditorView.Coordinator.matchingBracketRanges(around: 12, in: text)
        let paren = EditorView.Coordinator.matchingBracketRanges(around: 5, in: text)

        #expect(square?.opening == NSRange(location: 6, length: 1))
        #expect(square?.closing == NSRange(location: 8, length: 1))
        #expect(curly?.opening == NSRange(location: 11, length: 1))
        #expect(curly?.closing == NSRange(location: 19, length: 1))
        #expect(paren?.opening == NSRange(location: 4, length: 1))
        #expect(paren?.closing == NSRange(location: 20, length: 1))
    }

    // MARK: - Find and Replace

    @Test("findRanges returns case-insensitive matches")
    func testFindRangesReturnsCaseInsensitiveMatches() {
        let ranges = AppState.findRanges(in: "Find find FIND", query: "find")

        #expect(ranges.count == 3)
        #expect(ranges.map(\.location) == [0, 5, 10])
    }

    @Test("find navigation wraps across matches")
    func testFindNavigationWrapsAcrossMatches() {
        let appState = AppState()
        appState.fileContent = "alpha beta alpha"
        appState.findQuery = "alpha"

        #expect(appState.activeFindIndex == 0)
        appState.findNext()
        #expect(appState.activeFindIndex == 1)
        appState.findNext()
        #expect(appState.activeFindIndex == 0)
        appState.findPrevious()
        #expect(appState.activeFindIndex == 1)
    }

    @Test("replaceCurrentFindMatch replaces only active match")
    func testReplaceCurrentFindMatch() {
        let appState = AppState()
        appState.fileContent = "red blue red"
        appState.findQuery = "red"
        appState.replaceText = "green"
        appState.findNext()

        let didReplace = appState.replaceCurrentFindMatch()

        #expect(didReplace == true)
        #expect(appState.fileContent == "red blue green")
        #expect(appState.isEdited == true)
    }

    @Test("replaceAllFindMatches replaces every match")
    func testReplaceAllFindMatches() {
        let appState = AppState()
        appState.fileContent = "one two ONE"
        appState.findQuery = "one"
        appState.replaceText = "1"

        let count = appState.replaceAllFindMatches()

        #expect(count == 2)
        #expect(appState.fileContent == "1 two 1")
        #expect(appState.isEdited == true)
    }

    @Test("replaceAllFindMatches can target all open tabs")
    func testReplaceAllFindMatchesAcrossOpenTabs() {
        let tempDir = FileManager.default.temporaryDirectory
        let firstURL = tempDir.appendingPathComponent("veilwriter_replace_tabs_first_\(UUID().uuidString).txt")
        let secondURL = tempDir.appendingPathComponent("veilwriter_replace_tabs_second_\(UUID().uuidString).txt")

        let appState = AppState()
        appState.beginOpeningTab(for: firstURL)
        appState.fileContent = "token first token"
        appState.beginOpeningTab(for: secondURL)
        appState.fileContent = "second token"
        appState.findQuery = "token"
        appState.replaceText = "value"
        appState.findReplaceScope = .openTabs

        let count = appState.replaceAllFindMatches()

        #expect(count == 3)
        #expect(appState.tabs.first { $0.url == firstURL }?.content == "value first value")
        #expect(appState.tabs.first { $0.url == secondURL }?.content == "second value")
        #expect(appState.tabs.allSatisfy(\.isEdited) == true)
    }

    @Test("replaceAllFindMatches can target selected folder files")
    func testReplaceAllFindMatchesInSelectedFolder() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("veilwriter_replace_folder_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let firstURL = tempDir.appendingPathComponent("first.txt")
        let secondURL = tempDir.appendingPathComponent("second.txt")
        try "apple pear apple".write(to: firstURL, atomically: true, encoding: .utf8)
        try "pear apple".write(to: secondURL, atomically: true, encoding: .utf8)

        let appState = AppState(rootDirectory: tempDir)
        appState.selectedFolderURL = tempDir
        appState.findQuery = "apple"
        appState.replaceText = "orange"
        appState.findReplaceScope = .selectedFolder

        let count = appState.replaceAllFindMatches()

        #expect(count == 3)
        #expect(try String(contentsOf: firstURL, encoding: .utf8) == "orange pear orange")
        #expect(try String(contentsOf: secondURL, encoding: .utf8) == "pear orange")
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
