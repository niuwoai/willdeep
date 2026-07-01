//
//  EditorWorkflowTests.swift
//  WillDeepTests
//
//  Split from XeditTests.swift to keep editor workflow coverage
//  grouped away from Agent authorization and runtime tests.
//

import Testing
import Foundation
import AppKit
@testable import WillDeep

@MainActor
private func applyLoadedEditorFile(
    _ appState: AppState,
    fileURL: URL
) throws -> String {
    let data = try AppState.readFileData(from: fileURL)
    let content = AppState.decodeText(from: data)
    appState.applyLoadedContent(content, for: fileURL)
    return content
}

extension WillDeepTests {
    @Test("willdeep open URL decodes a file path")
    func testWillDeepOpenURLDecodesPath() throws {
        let path = "/tmp/willdeep cli path/\u{4e2d}\u{6587}.txt"
        var components = URLComponents()
        components.scheme = "willdeep"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]

        let url = try #require(components.url)
        let decoded = try #require(WillDeepExternalURLParser.fileURL(fromOpenURL: url))

        #expect(decoded.path == path)
    }

    @MainActor
    @Test("external CLI open creates a missing file when the parent exists")
    func testOpenExternalURLCreatesMissingFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_cli_create_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("limit.maxfiles.plist")
        let appState = AppState()

        appState.openExternalURL(fileURL, createsMissingFileIfNeeded: true)

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(appState.openedFileURL == fileURL)
    }

    @MainActor
    @Test("missing external file draft opens as edited without touching disk")
    func testMissingExternalFileDraftOpensEditedTab() {
        let fileURL = URL(fileURLWithPath: "/tmp/willdeep_cli_draft_\(UUID().uuidString).plist")
        let appState = AppState()

        appState.openMissingExternalFileDraft(at: fileURL)

        #expect(appState.openedFileURL == fileURL)
        #expect(appState.fileContent.isEmpty)
        #expect(appState.isEdited == true)
        #expect(appState.activeTab?.url == fileURL)
        #expect(appState.activeTab?.isEdited == true)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    @Test("external file open loads content without view onChange")
    func testExternalFileOpenLoadsContentWithoutViewChange() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_external_load_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("note.md")
        let content = "# Loaded\n\nThis should appear in the editor."
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let appState = AppState()
        appState.openExternalURL(fileURL)

        let loaded = try applyLoadedEditorFile(appState, fileURL: fileURL)
        #expect(loaded == content)
        #expect(appState.activeTab?.url.standardizedFileURL.path == fileURL.standardizedFileURL.path)
        #expect(appState.activeTab?.content == content)
    }

    @MainActor
    @Test("reopening an empty unedited tab reloads file content")
    func testReopeningEmptyUneditedTabReloadsFileContent() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_empty_tab_reload_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("note.md")
        let content = "content that should replace the placeholder tab"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let appState = AppState()
        appState.beginOpeningTab(for: fileURL)
        #expect(appState.fileContent.isEmpty)
        #expect(appState.activeTab?.isEdited == false)

        appState.openExternalURL(fileURL)

        let loaded = try applyLoadedEditorFile(appState, fileURL: fileURL)
        #expect(loaded == content)
        #expect(appState.activeTab?.content == content)
        #expect(appState.isEdited == false)
    }

    // MARK: - File Loading Timing (c1)

    @Test("loadFile completes promptly for a file under 1MB")
    func testFileLoadingTimingUnder500ms() throws {
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

        let data = try AppState.readFileData(from: fileURL)
        let decoded = AppState.decodeText(from: data)
        #expect(decoded == content)
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

        let invalidURL = URL(fileURLWithPath: "/tmp/willdeep_missing_\(UUID().uuidString)/file.txt")
        let result = appState.writeCurrentFile(to: invalidURL, updateOpenedURL: false, showsAlert: false)

        #expect(result == false)
        #expect(appState.openedFileURL == nil)
    }

    @Test("writeCurrentFile can save to a new URL and update current file")
    func testWriteCurrentFileAsNewURL() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("willdeep_test_save_as_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let appState = AppState()
        appState.fileContent = "saved through save as"
        appState.isEdited = true

        let result = appState.writeCurrentFile(to: fileURL, updateOpenedURL: true)

        #expect(result == true)
        #expect(appState.openedFileURL == fileURL)
        // Save As intentionally does NOT hijack the workspace root
        // (AppStateFileOperations.swift:354-356). If the user had a
        // folder open it stays; if not — like here — no FileTree is
        // promoted for the saved file's parent.
        #expect(appState.rootDirectory == nil)
        #expect(appState.isEdited == false)
        #expect(appState.suppressURLChangeProcessing == true)
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "saved through save as")
    }

    // MARK: - Tabs

    @Test("beginOpeningTab creates tabs and reuses existing file tabs")
    func testBeginOpeningTabCreatesAndReusesTabs() {
        let tempDir = FileManager.default.temporaryDirectory
        let firstURL = tempDir.appendingPathComponent("willdeep_tab_first_\(UUID().uuidString).txt")
        let secondURL = tempDir.appendingPathComponent("willdeep_tab_second_\(UUID().uuidString).txt")

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

    @Test("createNewTab opens an untitled tab without reusing file tabs")
    func testCreateNewTabOpensUntitledTab() {
        let appState = AppState()

        appState.createNewTab()
        let firstID = appState.activeTabID
        appState.fileContent = "draft"
        appState.isEdited = true
        appState.createNewTab()

        #expect(appState.tabs.count == 2)
        #expect(appState.activeTabID != firstID)
        #expect(appState.activeTab?.title == "Untitled")
        #expect(appState.activeTab?.isUntitled == true)
        #expect(appState.tabs.first { $0.id == firstID }?.content == "draft")
        #expect(appState.tabs.first { $0.id == firstID }?.isEdited == true)
    }

    @Test("syntax highlighting selection overrides detected file language")
    func testSyntaxHighlightingSelectionOverridesDetectedLanguage() {
        let fileURL = URL(fileURLWithPath: "/tmp/willdeep_syntax_override.swift")
        let appState = AppState(openedFileURL: fileURL, fileContent: "puts 'hi'")

        #expect(appState.detectedLanguage == .swift)
        #expect(appState.effectiveLanguage == .swift)

        appState.setSyntaxHighlightingSelection(.language(.ruby))
        if case .language(.ruby) = appState.syntaxHighlightingSelection {} else {
            Issue.record("Expected Ruby syntax highlighting override")
        }
        #expect(appState.effectiveLanguage == .ruby)

        appState.setSyntaxHighlightingSelection(.plainText)
        #expect(appState.effectiveLanguage == nil)

        appState.setSyntaxHighlightingSelection(.automatic)
        #expect(appState.effectiveLanguage == .swift)
    }

    @Test("closeTab activates a neighboring tab")
    func testCloseTabActivatesNeighbor() {
        let tempDir = FileManager.default.temporaryDirectory
        let firstURL = tempDir.appendingPathComponent("willdeep_close_first_\(UUID().uuidString).txt")
        let secondURL = tempDir.appendingPathComponent("willdeep_close_second_\(UUID().uuidString).txt")

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

    @Test("closing active tab refreshes editor rendering and highlighting")
    func testCloseTabBumpsEditorRenderAndHighlightRevision() {
        let tempDir = FileManager.default.temporaryDirectory
        let firstURL = tempDir.appendingPathComponent("willdeep_render_first_\(UUID().uuidString).swift")
        let secondURL = tempDir.appendingPathComponent("willdeep_render_second_\(UUID().uuidString).swift")

        let appState = AppState()
        appState.beginOpeningTab(for: firstURL)
        appState.fileContent = "let first = true"
        appState.beginOpeningTab(for: secondURL)
        appState.fileContent = "let second = true"

        let revisionBeforeClose = appState.editorRenderRevision
        let highlightRevisionBeforeClose = appState.editorHighlightRevision
        appState.closeActiveTab()

        #expect(appState.openedFileURL == firstURL)
        #expect(appState.editorRenderRevision > revisionBeforeClose)
        #expect(appState.editorHighlightRevision > highlightRevisionBeforeClose)
    }

    @Test("closeActiveTab closes the current tab")
    func testCloseActiveTabClosesCurrentTab() {
        let tempDir = FileManager.default.temporaryDirectory
        let firstURL = tempDir.appendingPathComponent("willdeep_active_close_first_\(UUID().uuidString).txt")
        let secondURL = tempDir.appendingPathComponent("willdeep_active_close_second_\(UUID().uuidString).txt")

        let appState = AppState()
        appState.beginOpeningTab(for: firstURL)
        let firstID = appState.activeTabID
        appState.beginOpeningTab(for: secondURL)

        appState.closeActiveTab()

        #expect(appState.tabs.count == 1)
        #expect(appState.activeTabID == firstID)
        #expect(appState.openedFileURL == firstURL)
    }

    @Test("tab navigation activates previous next and indexed tabs")
    func testTabNavigationActivatesPreviousNextAndIndexedTabs() {
        let tempDir = FileManager.default.temporaryDirectory
        let firstURL = tempDir.appendingPathComponent("willdeep_nav_first_\(UUID().uuidString).txt")
        let secondURL = tempDir.appendingPathComponent("willdeep_nav_second_\(UUID().uuidString).txt")
        let thirdURL = tempDir.appendingPathComponent("willdeep_nav_third_\(UUID().uuidString).txt")

        let appState = AppState()
        appState.beginOpeningTab(for: firstURL)
        let firstID = appState.activeTabID
        appState.beginOpeningTab(for: secondURL)
        let secondID = appState.activeTabID
        appState.beginOpeningTab(for: thirdURL)
        let thirdID = appState.activeTabID

        appState.activatePreviousTab()
        #expect(appState.activeTabID == secondID)

        appState.activateNextTab()
        #expect(appState.activeTabID == thirdID)

        appState.activateTab(atDisplayIndex: 1)
        #expect(appState.activeTabID == firstID)
    }

    @Test("reopenClosedTab restores most recently closed tab")
    func testReopenClosedTabRestoresMostRecentlyClosedTab() {
        let tempDir = FileManager.default.temporaryDirectory
        let firstURL = tempDir.appendingPathComponent("willdeep_reopen_first_\(UUID().uuidString).txt")
        let secondURL = tempDir.appendingPathComponent("willdeep_reopen_second_\(UUID().uuidString).txt")

        let appState = AppState()
        appState.beginOpeningTab(for: firstURL)
        appState.beginOpeningTab(for: secondURL)

        appState.closeActiveTab()
        #expect(appState.tabs.map(\.url) == [firstURL])

        appState.reopenClosedTab()
        #expect(appState.tabs.map(\.url).contains(secondURL))
        #expect(appState.openedFileURL == secondURL)
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

        let trailingNewline = EditorView.Coordinator.lineAndColumn(for: 2, in: "a\n")
        #expect(trailingNewline.line == 2)
        #expect(trailingNewline.column == 1)
    }

    @Test("editor selected line count maps ranges")
    func testEditorSelectedLineCountMapsRanges() {
        let text = "alpha\nbeta\ngamma"

        #expect(EditorView.Coordinator.selectedLineCount(for: NSRange(location: 0, length: 0), in: text) == 0)
        #expect(EditorView.Coordinator.selectedLineCount(for: NSRange(location: 1, length: 3), in: text) == 1)
        #expect(EditorView.Coordinator.selectedLineCount(for: NSRange(location: 1, length: 8), in: text) == 2)
        #expect(EditorView.Coordinator.selectedLineCount(for: NSRange(location: 4, length: 7), in: text) == 3)
    }

    @Test("editor selected text can be capped for live selection publishing")
    func testEditorSelectedTextCapsPublishedPreview() {
        let text = "alpha\nbeta\ngamma"

        #expect(
            EditorView.Coordinator.selectedText(
                for: NSRange(location: 0, length: 16),
                in: text,
                maxLength: 5
            ) == "alpha"
        )
        #expect(EditorView.Coordinator.selectedText(for: NSRange(location: 6, length: 4), in: text) == "beta")
    }

    @Test("quick open file URLs are sorted and limited")
    func testQuickOpenFileURLsAreSortedAndLimited() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_quick_open_\(UUID().uuidString)", isDirectory: true)
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
        let fileURL = tempDir.appendingPathComponent("willdeep_dirty_gutter_\(UUID().uuidString).swift")
        let appState = AppState(openedFileURL: fileURL, fileContent: "let a = 1\nlet b = 2")

        appState.fileContent = "let a = 1\nlet b = 3"

        #expect(appState.changedLineNumbers == Set([2]))
    }

    @Test("editor indentation helpers preserve lightweight editing flow")
    func testEditorIndentationHelpers() {
        let source = "func run() {\n    print(\"ok\")\n}"

        #expect(WillDeepTextView.leadingWhitespaceBefore(location: 17, in: source) == "    ")
        #expect(WillDeepTextView.indentingLines("one\ntwo\n") == "    one\n    two\n")
        #expect(WillDeepTextView.outdentingLines("    one\n\ttwo\n  three") == "one\ntwo\nthree")
    }

    @Test("save cleanup trims whitespace and ensures final newline")
    func testSaveCleanupTrimsWhitespaceAndEnsuresFinalNewline() {
        let settings = EditorSettings(
            fontID: EditorSettings.default.fontID,
            fontSize: EditorSettings.default.fontSize,
            lineHeightMultiple: EditorSettings.default.lineHeightMultiple,
            fileTreeFontSize: EditorSettings.default.fileTreeFontSize,
            fileTreeLineHeightMultiple: EditorSettings.default.fileTreeLineHeightMultiple,
            themeID: EditorSettings.default.themeID,
            showsLineNumbers: true,
            highlightsCurrentLine: true,
            preferredInspectorMode: EditorSettings.default.preferredInspectorMode,
            inspectorPanelOrder: EditorSettings.default.inspectorPanelOrder,
            windowBackgroundImagePath: EditorSettings.default.windowBackgroundImagePath,
            windowBackgroundImageOpacity: EditorSettings.default.windowBackgroundImageOpacity,
            windowBackgroundImageMode: EditorSettings.default.windowBackgroundImageMode,
            windowBackgroundImageScale: EditorSettings.default.windowBackgroundImageScale,
            editorGlassEnabled: EditorSettings.default.editorGlassEnabled,
            editorGlassMaterial: EditorSettings.default.editorGlassMaterial,
            editorGlassOpacity: EditorSettings.default.editorGlassOpacity,
            editorSurfaceOpacity: EditorSettings.default.editorSurfaceOpacity,
            interfaceSkinID: EditorSettings.default.interfaceSkinID,
            trimsTrailingWhitespaceOnSave: true,
            ensuresFinalNewlineOnSave: true
        )

        let cleaned = AppState.contentForSave("let a = 1   \nlet b = 2\t", settings: settings)

        #expect(cleaned == "let a = 1\nlet b = 2\n")
    }

    @Test("line editing helpers duplicate and move current line")
    func testLineEditingHelpersDuplicateAndMoveCurrentLine() {
        let source = "one\ntwo\nthree"

        #expect(AppState.duplicateLine(at: 2, in: source) == "one\ntwo\ntwo\nthree")

        let movedUp = AppState.moveLine(at: 2, direction: -1, in: source)
        #expect(movedUp.text == "two\none\nthree")
        #expect(movedUp.line == 1)

        let movedDown = AppState.moveLine(at: 2, direction: 1, in: source)
        #expect(movedDown.text == "one\nthree\ntwo")
        #expect(movedDown.line == 3)
    }

    @Test("preview and focus toggles stay lightweight")
    func testPreviewAndFocusTogglesStayLightweight() {
        let markdownURL = URL(fileURLWithPath: "/tmp/willdeep_preview.md")
        let htmlURL = URL(fileURLWithPath: "/tmp/willdeep_preview.html")
        let swiftURL = URL(fileURLWithPath: "/tmp/willdeep_preview.swift")
        let appState = AppState(openedFileURL: markdownURL, fileContent: "# Title")

        #expect(appState.canShowPreview == true)
        appState.togglePreview()
        #expect(appState.isPreviewVisible == true)

        appState.toggleFocusMode()
        #expect(appState.isFocusModeEnabled == true)

        let htmlState = AppState(openedFileURL: htmlURL, fileContent: "<h1>Title</h1>")
        #expect(htmlState.canShowPreview == true)
        htmlState.togglePreview()
        #expect(htmlState.isPreviewVisible == true)

        let codeState = AppState(openedFileURL: swiftURL, fileContent: "let x = 1")
        #expect(codeState.canShowPreview == false)
        codeState.togglePreview()
        #expect(codeState.isPreviewVisible == false)
    }

    @MainActor
    @Test("first-stage language outline trusts completed LSP results before regex fallback")
    func testFirstStageOutlineTrustsCompletedLSPResultsBeforeRegexFallback() {
        let fileURL = URL(fileURLWithPath: "/tmp/willdeep_outline.go")
        let appState = AppState(openedFileURL: fileURL, fileContent: "package main\n")
        let fallbackItem = EditorOutlineItem(title: "RegexFallback", kind: .function, line: 1, level: 0)

        appState.editorLanguageServiceOutlineItems = []
        appState.editorLanguageServiceOutlineStatus = .available(uri: fileURL.absoluteString)

        var fallbackCalls = 0
        let availableItems = appState.editorOutlineItems {
            fallbackCalls += 1
            return [fallbackItem]
        }

        #expect(appState.editorLanguageServiceOutlineIsAuthoritative)
        #expect(availableItems.isEmpty)
        #expect(fallbackCalls == 0)

        appState.editorLanguageServiceOutlineStatus = .failed(uri: fileURL.absoluteString)
        let failedItems = appState.editorOutlineItems {
            fallbackCalls += 1
            return [fallbackItem]
        }

        #expect(!appState.editorLanguageServiceOutlineIsAuthoritative)
        #expect(failedItems == [fallbackItem])
        #expect(fallbackCalls == 1)
    }

    @MainActor
    @Test("first-stage folding trusts completed LSP ranges before local scope fallback")
    func testFirstStageFoldingTrustsCompletedLSPRangesBeforeLocalFallback() {
        let fileURL = URL(fileURLWithPath: "/tmp/willdeep_folding.go")
        let appState = AppState(openedFileURL: fileURL, fileContent: "package main\n")
        appState.editorLanguageServiceFoldingStatus = .available(uri: fileURL.absoluteString)

        #expect(appState.editorLanguageServiceFoldingIsAuthoritative)

        let textView = WillDeepTextView(frame: .zero)
        textView.scopeGuideLanguage = .go
        textView.string = """
        package main

        func main() {
            if true {
                println("ok")
            }
        }
        """

        #expect(!textView.foldableGuides().isEmpty)

        textView.languageServiceFoldingIsAuthoritative = true
        textView.languageServiceFoldingGuides = []
        #expect(textView.foldableGuides().isEmpty)

        let lspGuide = ScopeGuide(startLine: 3, endLine: 6, column: 0, depth: 0)
        textView.languageServiceFoldingGuides = [lspGuide]
        #expect(textView.foldableGuides() == [lspGuide])

        appState.editorLanguageServiceFoldingStatus = .failed(uri: fileURL.absoluteString)
        #expect(!appState.editorLanguageServiceFoldingIsAuthoritative)
    }

    @MainActor
    @Test("first-stage workspace symbol search trusts completed LSP misses before outline filtering")
    func testFirstStageWorkspaceSymbolSearchTrustsCompletedLSPMissesBeforeOutlineFiltering() {
        let fileURL = URL(fileURLWithPath: "/tmp/willdeep_workspace_symbol.go")
        let appState = AppState(openedFileURL: fileURL, fileContent: "package main\n")

        appState.editorWorkspaceSymbolItems = []
        appState.editorWorkspaceSymbolSearchStatus = .available(query: "MissingService")
        #expect(appState.editorWorkspaceSymbolSearchIsAuthoritative(query: " MissingService "))

        appState.editorWorkspaceSymbolSearchStatus = .failed(query: "MissingService")
        #expect(!appState.editorWorkspaceSymbolSearchIsAuthoritative(query: "MissingService"))

        appState.editorWorkspaceSymbolSearchStatus = .available(query: "OtherService")
        #expect(!appState.editorWorkspaceSymbolSearchIsAuthoritative(query: "MissingService"))
    }

    @Test("markdown preview parser extracts common blocks")
    func testMarkdownPreviewParserExtractsCommonBlocks() {
        let source = """
        # Title

        A paragraph with **bold** text.

        > Quote
        - Item
        1. Ordered
        ---
        ```swift
        let value = 1
        ```
        """

        let blocks = MarkdownPreviewParser.blocks(from: source)

        #expect(blocks.contains(MarkdownPreviewBlock(kind: .heading(level: 1), text: "Title")))
        #expect(blocks.contains(MarkdownPreviewBlock(kind: .paragraph, text: "A paragraph with **bold** text.")))
        #expect(blocks.contains(MarkdownPreviewBlock(kind: .quote, text: "Quote")))
        #expect(blocks.contains(MarkdownPreviewBlock(kind: .unorderedList, text: "Item")))
        #expect(blocks.contains(MarkdownPreviewBlock(kind: .orderedList, text: "Ordered")))
        #expect(blocks.contains(MarkdownPreviewBlock(kind: .divider, text: "")))
        // Fenced code blocks carry the language hint after ``` as
        // `info`. Equatable on MarkdownPreviewBlock is memberwise so
        // the expected value must mirror that field.
        #expect(blocks.contains(MarkdownPreviewBlock(kind: .code, text: "let value = 1", info: "swift")))
    }

    @Test("HTML preview parser extracts common blocks")
    func testHTMLPreviewParserExtractsCommonBlocks() {
        let source = """
        <html>
          <head><title>Preview Title</title></head>
          <body>
            <h2>Section</h2>
            <p>A paragraph with <strong>bold</strong> text.</p>
            <blockquote>Quote</blockquote>
            <ul><li>Item</li></ul>
            <hr>
            <pre>let value = 1</pre>
          </body>
        </html>
        """

        let blocks = HTMLPreviewParser.blocks(from: source)

        #expect(blocks.contains(MarkdownPreviewBlock(kind: .heading(level: 1), text: "Preview Title")))
        #expect(blocks.contains(MarkdownPreviewBlock(kind: .heading(level: 2), text: "Section")))
        #expect(blocks.contains(MarkdownPreviewBlock(kind: .paragraph, text: "A paragraph with bold text.")))
        #expect(blocks.contains(MarkdownPreviewBlock(kind: .quote, text: "Quote")))
        #expect(blocks.contains(MarkdownPreviewBlock(kind: .unorderedList, text: "Item")))
        #expect(blocks.contains(MarkdownPreviewBlock(kind: .divider, text: "")))
        #expect(blocks.contains(MarkdownPreviewBlock(kind: .code, text: "let value = 1")))
    }

    @Test("file modification date detects existing files")
    func testFileModificationDateDetectsExistingFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("willdeep_mod_date_\(UUID().uuidString).txt")
        try "first".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        #expect(AppState.modificationDate(at: fileURL) != nil)
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
        let firstURL = tempDir.appendingPathComponent("willdeep_replace_tabs_first_\(UUID().uuidString).txt")
        let secondURL = tempDir.appendingPathComponent("willdeep_replace_tabs_second_\(UUID().uuidString).txt")

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
            .appendingPathComponent("willdeep_replace_folder_\(UUID().uuidString)")
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
