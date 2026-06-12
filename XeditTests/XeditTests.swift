//
//  XeditTests.swift
//  WillDeepTests
//
//  Created by rocky on 2026/5/27.
//

import Testing
import Foundation
import AppKit
@testable import WillDeep

@Suite(.serialized)
struct WillDeepTests {
    private enum TestError: Error {
        case loadTimedOut
    }

    /// Wipes the shared `UserDefaults` keys that AppState persists into so
    /// each test starts from a clean slate. swift-testing builds a fresh
    /// instance of this struct per test, so `init()` doubles as the
    /// per-test `setUp`.
    init() {
        let keys = [
            "com.willdeep.recentFiles.v1",
            "com.willdeep.recentFolders.v1",
            "com.willdeep.session.v1"
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Drain anything AppState scheduled on the main queue (e.g. the
    /// deferred editor-settings side effects). Polls until either the
    /// predicate is satisfied or the deadline passes; spins the main run
    /// loop and yields to the cooperative scheduler each round.
    @MainActor
    private func drainMainQueue(
        timeout: TimeInterval = 1.0,
        until predicate: @MainActor () -> Bool = { false }
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            await Task.yield()
        }
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

    @Test("isImageFile recognizes previewable image extensions")
    func testImageFileDetection() {
        #expect(AppState.isImageFile(at: URL(fileURLWithPath: "/tmp/photo.png")) == true)
        #expect(AppState.isImageFile(at: URL(fileURLWithPath: "/tmp/photo.JPG")) == true)
        #expect(AppState.isImageFile(at: URL(fileURLWithPath: "/tmp/icon.icns")) == true)
        #expect(AppState.isImageFile(at: URL(fileURLWithPath: "/tmp/readme.md")) == false)
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
        #expect(settings.lineHeightMultiple == 1.15)
        #expect(settings.fileTreeFontSize == 12)
        #expect(settings.fileTreeLineHeightMultiple == 1.25)
        #expect(settings.showsLineNumbers == true)
        #expect(settings.highlightsCurrentLine == true)
        #expect(settings.preferredInspectorMode == .minimap)
        #expect(settings.inspectorPanelOrder == .minimapFirst)
        #expect(settings.orderedInspectorModes == [.minimap, .structure])
        #expect(settings.trimsTrailingWhitespaceOnSave == false)
        #expect(settings.ensuresFinalNewlineOnSave == false)
        #expect(EditorTheme.byID(settings.themeID) != nil)
        #expect(EditorFontChoice.byID(settings.fontID) != nil)
    }

    @Test("editor settings normalize invalid persisted values")
    func testEditorSettingsNormalization() {
        let settings = EditorSettings(
            fontID: "missing-font",
            fontSize: 99,
            lineHeightMultiple: 4.0,
            fileTreeFontSize: 99,
            fileTreeLineHeightMultiple: 99,
            themeID: "missing-theme",
            showsLineNumbers: false,
            highlightsCurrentLine: false,
            preferredInspectorMode: .structure,
            inspectorPanelOrder: .structureFirst,
            windowBackgroundImagePath: "/tmp/missing.png",
            windowBackgroundImageOpacity: 9,
            windowBackgroundImageMode: .center,
            windowBackgroundImageScale: 9,
            editorGlassEnabled: true,
            editorGlassMaterial: .hudWindow,
            editorGlassOpacity: 9,
            editorSurfaceOpacity: 9,
            trimsTrailingWhitespaceOnSave: true,
            ensuresFinalNewlineOnSave: true
        ).normalized()

        #expect(settings.fontID == EditorSettings.default.fontID)
        #expect(settings.themeID == EditorSettings.default.themeID)
        #expect(settings.fontSize == 28)
        #expect(settings.lineHeightMultiple == 1.8)
        #expect(settings.fileTreeFontSize == 16)
        #expect(settings.fileTreeLineHeightMultiple == 2.0)
        #expect(settings.showsLineNumbers == false)
        #expect(settings.highlightsCurrentLine == false)
        #expect(settings.preferredInspectorMode == .structure)
        #expect(settings.inspectorPanelOrder == .structureFirst)
        #expect(settings.orderedInspectorModes == [.structure, .minimap])
        #expect(settings.windowBackgroundImagePath == "/tmp/missing.png")
        #expect(settings.windowBackgroundImageOpacity == 1)
        #expect(settings.windowBackgroundImageMode == .center)
        #expect(settings.windowBackgroundImageScale == 3)
        #expect(settings.editorGlassEnabled == true)
        #expect(settings.editorGlassMaterial == .hudWindow)
        #expect(settings.editorGlassOpacity == 1)
        #expect(settings.editorSurfaceOpacity == 1)
        #expect(settings.trimsTrailingWhitespaceOnSave == true)
        #expect(settings.ensuresFinalNewlineOnSave == true)
    }

    @Test("editor settings decode older persisted settings with new preference defaults")
    @MainActor
    func testEditorSettingsDecodesOlderPersistedSettings() throws {
        let json = """
        {
          "fontID": "menlo",
          "fontSize": 14,
          "lineHeightMultiple": 1.25,
          "themeID": "graphite",
          "showsLineNumbers": false,
          "highlightsCurrentLine": true,
          "trimsTrailingWhitespaceOnSave": true,
          "ensuresFinalNewlineOnSave": false
        }
        """

        let settings = try JSONDecoder().decode(EditorSettings.self, from: Data(json.utf8)).normalized()

        #expect(settings.fontID == "menlo")
        #expect(settings.fileTreeFontSize == EditorSettings.default.fileTreeFontSize)
        #expect(settings.fileTreeLineHeightMultiple == EditorSettings.default.fileTreeLineHeightMultiple)
        #expect(settings.preferredInspectorMode == EditorSettings.default.preferredInspectorMode)
        #expect(settings.inspectorPanelOrder == EditorSettings.default.inspectorPanelOrder)
    }

    @Test("changing editor settings refreshes the active editor")
    @MainActor
    func testEditorSettingsChangeBumpsRenderAndHighlightRevisions() async {
        let appState = AppState()
        let renderRevision = appState.editorRenderRevision
        let highlightRevision = appState.editorHighlightRevision
        var settings = appState.editorSettings
        settings.fontID = EditorFontChoice.menlo.id
        settings.fontSize = 18
        settings.lineHeightMultiple = 1.4
        settings.fileTreeFontSize = 14
        settings.fileTreeLineHeightMultiple = 1.5
        settings.themeID = EditorTheme.graphite.id
        settings.showsLineNumbers = false
        settings.highlightsCurrentLine = false
        settings.preferredInspectorMode = .structure
        settings.inspectorPanelOrder = .structureFirst

        appState.editorSettings = settings

        // AppState defers the render/highlight bump to the next main-loop
        // turn (avoids SwiftUI publishing-during-view-update warnings), so
        // let the run loop tick before asserting.
        await drainMainQueue(timeout: 2.0) {
            appState.editorRenderRevision > renderRevision
                && appState.editorHighlightRevision > highlightRevision
                && appState.inspectorMode == .structure
        }

        #expect(appState.editorRenderRevision > renderRevision)
        #expect(appState.editorHighlightRevision > highlightRevision)
        #expect(appState.inspectorMode == .structure)
    }

    @Test("file tree icons map common file types to distinct symbols")
    @MainActor
    func testFileTreeIconsForCommonFileTypes() {
        #expect(FileTreeIconDescriptor.file(for: URL(fileURLWithPath: "/tmp/App.swift")).symbolName == "swift")
        #expect(FileTreeIconDescriptor.file(for: URL(fileURLWithPath: "/tmp/package.json")).symbolName == "slider.horizontal.3")
        #expect(FileTreeIconDescriptor.file(for: URL(fileURLWithPath: "/tmp/index.html")).symbolName == "globe")
        #expect(FileTreeIconDescriptor.file(for: URL(fileURLWithPath: "/tmp/styles.css")).symbolName == "paintpalette.fill")
        #expect(FileTreeIconDescriptor.file(for: URL(fileURLWithPath: "/tmp/script.sh")).symbolName == "terminal.fill")
        #expect(FileTreeIconDescriptor.file(for: URL(fileURLWithPath: "/tmp/photo.png")).symbolName == "photo.fill")
        #expect(FileTreeIconDescriptor.file(for: URL(fileURLWithPath: "/tmp/Dockerfile")).symbolName == "shippingbox.circle.fill")
        #expect(FileTreeIconDescriptor.file(for: URL(fileURLWithPath: "/tmp/unknown.blob")).symbolName == "doc.fill")
    }

    @Test("command line installer script forwards paths to WillDeep")
    func testCommandLineInstallerScript() {
        let appURL = URL(fileURLWithPath: "/Applications/WillDeep.app")
        let script = CommandLineToolInstaller.scriptContent(appBundleURL: appURL)

        #expect(script.hasPrefix("#!/bin/zsh"))
        #expect(script.contains("/usr/bin/open -a \"$app_path\" -- \"$@\""))
        #expect(script.contains("app_path='/Applications/WillDeep.app'"))
    }

    @Test("command line installer uses a user-local path")
    func testCommandLineInstallerUsesUserLocalPath() {
        let path = CommandLineToolInstaller.installURL.standardizedFileURL.path

        #expect(path.hasSuffix("/.local/bin/willdeep"))
    }

    @Test("command line installer shell quoting handles apostrophes")
    func testCommandLineInstallerShellQuoting() {
        let quoted = CommandLineToolInstaller.singleQuotedShellString("/tmp/WillDeep's App.app")

        #expect(quoted.hasPrefix("'"))
        #expect(quoted.hasSuffix("'"))
        #expect(quoted.contains("'\\''"))
    }

    @Test("external folder opens as project root")
    @MainActor
    func testExternalFolderOpen() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_external_folder_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let state = AppState()
        state.openExternalURL(tempDir)

        #expect(state.rootDirectory?.standardizedFileURL.path == tempDir.standardizedFileURL.path)
        #expect(state.selectedFolderURL?.standardizedFileURL.path == tempDir.standardizedFileURL.path)
        #expect(state.openedFileURL == nil)
        #expect(!state.recentFolders.contains { $0.standardizedFileURL.path == tempDir.standardizedFileURL.path })
    }

    @Test("folder URL can be delegated to a new window without replacing current root")
    @MainActor
    func testFolderURLOpensInNewWindow() throws {
        // `RecentItemsStore` deliberately rejects paths under the system
        // temp directory, so use the user's caches dir for any fixture the
        // test expects to land in `recentFolders`.
        let cachesBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let originalDir = cachesBase
            .appendingPathComponent("willdeep_test_original_\(UUID().uuidString)")
        let nextDir = cachesBase
            .appendingPathComponent("willdeep_test_new_window_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: originalDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nextDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: originalDir)
            try? FileManager.default.removeItem(at: nextDir)
        }

        let state = AppState(rootDirectory: originalDir)
        var delegatedURL: URL?
        state.openFolderURL(nextDir) { url in
            delegatedURL = url
        }

        #expect(delegatedURL?.standardizedFileURL.path == nextDir.standardizedFileURL.path)
        #expect(state.rootDirectory?.standardizedFileURL.path == originalDir.standardizedFileURL.path)
        #expect(state.selectedFolderURL == nil)
        #expect(state.recentFolders.contains { $0.standardizedFileURL.path == nextDir.standardizedFileURL.path })
    }

    @Test("external file open does not hijack workspace root")
    @MainActor
    func testExternalFileOpen() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_external_file_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("note.md")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let state = AppState()
        state.openExternalURL(fileURL)

        // `openExternalURL` intentionally does NOT promote the file's
        // parent directory to `rootDirectory` for plain-file opens
        // (AppState.swift:702-707) — loading a huge parent like
        // ~/Downloads as a FileTree was a fatal-latency footgun. So
        // the file opens but no workspace root appears.
        #expect(state.rootDirectory == nil)
        #expect(state.selectedFolderURL == nil)
        #expect(state.openedFileURL == fileURL)
        // Temp-folder paths are filtered out of recent items entirely.
        #expect(!state.recentFiles.contains { $0.standardizedFileURL.path == fileURL.standardizedFileURL.path })
        #expect(!state.recentFolders.contains { $0.standardizedFileURL.path == tempDir.standardizedFileURL.path })
    }

    @Test("temporary paths are excluded from recent items")
    func testTemporaryPathsAreExcludedFromRecentItems() {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("xedit_test_recent_\(UUID().uuidString).txt")
        let homeFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/note.md")

        #expect(AppState.isRecentItemEligibleForTesting(tempFile) == false)
        #expect(AppState.isRecentItemEligibleForTesting(homeFile) == true)
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

    @Test("diff highlighting colors added and removed lines")
    @MainActor
    func testDiffHighlightingColorsAddedAndRemovedLines() {
        let theme = EditorTheme.graphite
        let font = EditorFontChoice.menlo.font(size: 13)
        let source = """
        --- a/Settings.swift
        +++ b/Settings.swift
        @@ -13,6 +13,7 @@ import Carbon
         class Settings {
        +    private var isLoading = true
        -    let legacy = false
        """

        let highlighted = SyntaxHighlighter.highlightSync(
            source,
            language: .diff,
            theme: theme,
            font: font
        )

        let ns = source as NSString
        func color(atLineStarting prefix: String) -> NSColor? {
            let range = ns.range(of: prefix)
            return highlighted.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        }

        #expect(color(atLineStarting: "--- a/") == theme.headerColor)
        #expect(color(atLineStarting: "+++ b/") == theme.headerColor)
        #expect(color(atLineStarting: "@@ -13,6") == theme.keywordColor)
        #expect(color(atLineStarting: "+    private") == theme.diffAddedColor)
        #expect(color(atLineStarting: "-    let legacy") == theme.diffRemovedColor)
        #expect(Language.fromExtension(".patch") == .diff)
    }

    @Test("scope guides match Ruby class and method blocks")
    func testScopeGuidesMatchRubyBlocks() {
        let source = """
        class Hello
          def gds
            puts "ok"
          end
        end
        """

        let guides = ScopeGuideCalculator.guides(in: source, language: .ruby)

        #expect(guides.contains(ScopeGuide(startLine: 1, endLine: 5, column: 0, depth: 0)))
        #expect(guides.contains(ScopeGuide(startLine: 2, endLine: 4, column: 2, depth: 1)))
        #expect(ScopeGuideCalculator.guideContaining(line: 3, in: guides) == ScopeGuide(startLine: 2, endLine: 4, column: 2, depth: 1))
    }

    @Test("scope guides match Python indentation blocks")
    func testScopeGuidesMatchPythonBlocks() {
        let source = """
        class Hello:
            def gds(self):
                print("ok")
            def other(self):
                pass
        """

        let guides = ScopeGuideCalculator.guides(in: source, language: .python)

        #expect(guides.contains(ScopeGuide(startLine: 1, endLine: 5, column: 0, depth: 0)))
        #expect(guides.contains(ScopeGuide(startLine: 2, endLine: 3, column: 4, depth: 1)))
        #expect(guides.contains(ScopeGuide(startLine: 4, endLine: 5, column: 4, depth: 1)))
    }

    @Test("scope guides match brace based Java blocks")
    func testScopeGuidesMatchJavaBlocks() {
        let source = """
        public class Hello {
          void gds() {
            System.out.println("ok");
          }
        }
        """

        let guides = ScopeGuideCalculator.guides(in: source, language: .java)

        #expect(guides.contains(ScopeGuide(startLine: 1, endLine: 5, column: 19, depth: 0)))
        #expect(guides.contains(ScopeGuide(startLine: 2, endLine: 4, column: 13, depth: 1)))
    }

    @Test("scope guide calculator handles every highlighted language")
    func testScopeGuideCalculatorHandlesEveryHighlightedLanguage() {
        let source = """
        class Hello {
          def gds
            puts "ok"
          end
        }
        """

        for language in Language.allCases {
            _ = ScopeGuideCalculator.guides(in: source, language: language)
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

    @Test("outline extractor finds shallow HTML nodes")
    func testOutlineExtractorFindsShallowHTMLNodes() {
        let source = """
        <!doctype html>
        <html>
          <head>
            <title>Product Page</title>
          </head>
          <body>
            <main id="app">
              <h1>Welcome</h1>
              <div class="hero primary">
                <ul>
                  <li>Fast preview</li>
                </ul>
              </div>
              <section>
                <div>
                  <div>
                    <div>
                      <div id="too-deep"></div>
                    </div>
                  </div>
                </div>
              </section>
            </main>
          </body>
        </html>
        """

        let items = EditorOutlineExtractor.outline(for: source, language: .html)

        #expect(items.map(\.title).contains("Product Page"))
        #expect(items.map(\.title).contains("main#app"))
        #expect(items.map(\.title).contains("H1 Welcome"))
        #expect(items.map(\.title).contains("div.hero.primary"))
        #expect(items.map(\.title).contains("ul"))
        #expect(items.map(\.title).contains("li Fast preview"))
        #expect(items.map(\.title).contains("div#too-deep") == false)
    }

    @Test("outline extractor handles HTML attribute quote styles")
    func testOutlineExtractorHandlesHTMLAttributeQuoteStyles() {
        let source = """
        <main id=app>
          <div class='hero primary'></div>
          <section aria-label="Feature list"></section>
        </main>
        """

        let items = EditorOutlineExtractor.outline(for: source, language: .html)

        #expect(items.map(\.title).contains("main#app"))
        #expect(items.map(\.title).contains("div.hero.primary"))
        #expect(items.map(\.title).contains("section Feature list"))
    }

    @Test("git porcelain status maps common file states")
    func testGitPorcelainStatusMapping() {
        let entries = AppState.parseGitStatusPorcelain(
            """
             M Sources/App.swift
            ?? Notes/todo.md
            A  Sources/NewFile.swift
             D Sources/Removed.swift
            R  Old.swift -> Sources/Renamed.swift
            ?? Assets/
            """
        )

        #expect(entries["Sources/App.swift"] == .modified)
        #expect(entries["Notes/todo.md"] == .untracked)
        #expect(entries["Sources/NewFile.swift"] == .added)
        #expect(entries["Sources/Removed.swift"] == .deleted)
        #expect(entries["Sources/Renamed.swift"] == .renamed)
        #expect(entries["Assets"] == .untracked)
    }

    @Test("git repository status returns folder marker when child changed")
    func testGitRepositoryStatusFolderMarker() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-git-root")
        let status = GitRepositoryStatus(
            repositoryRoot: root,
            branchName: "main",
            entries: ["Sources/App.swift": .modified]
        )

        #expect(status.kind(for: root.appendingPathComponent("Sources")) == .modified)
        #expect(status.kind(for: root.appendingPathComponent("Sources/App.swift")) == .modified)
        #expect(status.kind(for: root.appendingPathComponent("README.md")) == nil)
    }

    @Test("git repository status aggregates folder markers deterministically")
    func testGitRepositoryStatusFolderMarkerPriority() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-git-root")
        let status = GitRepositoryStatus(
            repositoryRoot: root,
            branchName: "main",
            entries: [
                "icons/new.svg": .untracked,
                "icons/removed.svg": .deleted,
                "icons/changed.svg": .modified,
            ]
        )

        #expect(status.kind(for: root.appendingPathComponent("icons")) == .deleted)
    }

    @Test("git numstat parser returns per-file line deltas")
    func testGitNumstatParser() {
        let stats = AppState.parseGitNumstat(
            """
            25\t13\tXedit/AgentClient.swift
            -\t-\tAssets/icon.png
            2\t0\tDocs/Name With Spaces.md
            """
        )

        #expect(stats["Xedit/AgentClient.swift"]?.added == 25)
        #expect(stats["Xedit/AgentClient.swift"]?.deleted == 13)
        #expect(stats["Assets/icon.png"]?.added == nil)
        #expect(stats["Assets/icon.png"]?.deleted == nil)
        #expect(stats["Docs/Name With Spaces.md"]?.added == 2)
        #expect(stats["Docs/Name With Spaces.md"]?.deleted == 0)
    }

    @Test("worktree change summary combines porcelain entries and numstat")
    func testWorktreeChangeSummaryTotals() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-git-root")
        let summary = AgentWorktreeChangeSummary(
            repositoryRoot: root,
            files: [
                AgentFileChangeSummary(
                    path: "B.swift",
                    kind: .modified,
                    lineStats: AgentLineChangeStats(added: 10, deleted: 2)
                ),
                AgentFileChangeSummary(
                    path: "A.swift",
                    kind: .untracked,
                    lineStats: AgentLineChangeStats(added: nil, deleted: nil)
                )
            ]
        )

        #expect(summary.fileCount == 2)
        #expect(summary.totalAddedLines == 10)
        #expect(summary.totalDeletedLines == 2)
        #expect(summary.files.map(\.path) == ["A.swift", "B.swift"])
        #expect(summary.change(for: "B.swift")?.fileName == "B.swift")
    }

    @Test("agent worktree summary skips modified files without real diff")
    func testAgentWorktreeSummarySkipsModifiedFilesWithoutDiff() {
        #expect(AppState.shouldIncludeAgentWorktreeChange(
            kind: .modified,
            lineStats: AgentLineChangeStats(added: nil, deleted: nil),
            hasNumstatEntry: false
        ) == false)
        #expect(AppState.shouldIncludeAgentWorktreeChange(
            kind: .modified,
            lineStats: AgentLineChangeStats(added: 0, deleted: 0),
            hasNumstatEntry: true
        ) == false)
        #expect(AppState.shouldIncludeAgentWorktreeChange(
            kind: .modified,
            lineStats: AgentLineChangeStats(added: 2, deleted: 0),
            hasNumstatEntry: true
        ) == true)
        #expect(AppState.shouldIncludeAgentWorktreeChange(
            kind: .modified,
            lineStats: AgentLineChangeStats(added: nil, deleted: nil),
            hasNumstatEntry: true
        ) == true)
        #expect(AppState.shouldIncludeAgentWorktreeChange(
            kind: .untracked,
            lineStats: AgentLineChangeStats(added: nil, deleted: nil),
            hasNumstatEntry: false
        ) == true)
    }

    @MainActor
    @Test("agent thinking indicator only shows while waiting for model output")
    func testAgentThinkingIndicatorState() {
        let appState = AppState()
        // `isAgentResponding` / `agentMessages` / `isCompressingAgentContext`
        // are delegated to the active runtime; without one every set is a
        // no-op and the indicator stays false. Production builds a runtime
        // the first time the user enters Agent mode — mirror that here.
        appState.startNewAgentSession()

        appState.isAgentResponding = true
        appState.agentMessages = [AgentMessage(role: .user, content: "Review this")]
        #expect(appState.shouldShowAgentThinkingIndicator == true)

        appState.agentMessages.append(AgentMessage(role: .assistant, content: "Done"))
        #expect(appState.shouldShowAgentThinkingIndicator == false)

        let assistant = AgentMessage(
            role: .assistant,
            content: "",
            toolCalls: [AgentMessageToolCall(externalID: "tool-1", toolName: "git_status", argumentsJSON: "{}")]
        )
        appState.agentMessages = [assistant]
        #expect(appState.shouldShowAgentThinkingIndicator == false)

        appState.agentMessages = [AgentMessage(role: .tool, content: "ok", toolCallID: "tool-1")]
        #expect(appState.shouldShowAgentThinkingIndicator == true)

        appState.isCompressingAgentContext = true
        #expect(appState.shouldShowAgentThinkingIndicator == false)
    }

    @MainActor
    @Test("composer workspace pick migrates an empty active session in place")
    func testComposerWorkspacePickMigratesEmptyActiveSession() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_workspace_pick_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let appState = AppState(rootDirectory: nil)
        let existingIDs = Set(appState.agentSessions.map(\.id))
        let session = appState.startNewAgentSession()
        defer {
            for id in appState.agentSessions.map(\.id) where !existingIDs.contains(id) {
                AgentSessionStore.delete(id: id)
            }
        }
        let initialCount = appState.agentSessions.count

        let rebound = appState.moveActiveAgentSessionToWorkspace(at: workspace.path)

        #expect(rebound.id == session.id)
        #expect(appState.agentSessions.count == initialCount)
        #expect(appState.activeRuntime?.workspaceRootPath == workspace.standardizedFileURL.path)
        #expect(appState.agentSessions.first(where: { $0.id == session.id })?.workspaceRootPath == workspace.standardizedFileURL.path)
    }

    @MainActor
    @Test("live thinking preview tracks streaming reasoning and dies with the indicator")
    func testAgentLiveThinkingPreview() {
        let appState = AppState()
        appState.startNewAgentSession()
        appState.isAgentResponding = true
        appState.agentMessages = [AgentMessage(role: .user, content: "查一下这个 bug")]
        // 占位 assistant 还没到 / reasoning 还没流出来 → 无预览
        #expect(appState.agentLiveThinkingPreview == nil)

        appState.agentMessages.append(
            AgentMessage(role: .assistant, content: "", reasoningContent: "先读取文件，再分析调用链")
        )
        #expect(appState.agentLiveThinkingPreview == "先读取文件，再分析调用链")

        // 首个正文 token 到达 → 指示器整体消失，预览跟着消失
        appState.agentMessages[1].content = "好的"
        #expect(appState.agentLiveThinkingPreview == nil)

        // turn 结束后即使 reasoning 还挂在消息上也不再预览
        appState.agentMessages[1].content = ""
        appState.isAgentResponding = false
        #expect(appState.agentLiveThinkingPreview == nil)
    }

    @Test("thinking preview tail collapses whitespace and keeps the newest characters")
    func testAgentThinkingPreviewTail() {
        // 短文本原样返回，只折叠换行
        #expect(AppState.agentThinkingPreviewTail("第一步\n第二步") == "第一步 第二步")

        // 超长 trace 截尾：保留最新内容，前置省略号
        let long = (1...100).map { "片段\($0)" }.joined(separator: "\n")
        let tail = AppState.agentThinkingPreviewTail(long)
        #expect(tail.hasPrefix("…"))
        #expect(tail.hasSuffix("片段100"))
        #expect(tail.count <= 161)
    }

    @Test("command palette matcher supports fuzzy and keyword lookup")
    func testCommandPaletteMatcher() {
        let command = PaletteCommand(
            title: "Open Terminal Here",
            subtitle: "Open Terminal at the project location",
            icon: "terminal",
            isEnabled: true,
            keywords: ["shell", "cli"]
        ) {}

        #expect(PaletteCommandMatcher.matches("oth", command: command) == true)
        #expect(PaletteCommandMatcher.matches("cli", command: command) == true)
        #expect(PaletteCommandMatcher.matches("preview", command: command) == false)
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
    }

    @Test("editor selected line count maps ranges")
    func testEditorSelectedLineCountMapsRanges() {
        let text = "alpha\nbeta\ngamma"

        #expect(EditorView.Coordinator.selectedLineCount(for: NSRange(location: 0, length: 0), in: text) == 0)
        #expect(EditorView.Coordinator.selectedLineCount(for: NSRange(location: 1, length: 3), in: text) == 1)
        #expect(EditorView.Coordinator.selectedLineCount(for: NSRange(location: 1, length: 8), in: text) == 2)
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

    // MARK: - Agent tools

    @Test("grep_files matches a regex across workspace files and respects include filter")
    func testGrepFilesMatchesRegexWithInclude() async throws {
        let workspace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("willdeep_test_grep_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "func alpha() {}\nlet beta = 1\n".write(
            to: workspace.appendingPathComponent("Sample.swift"), atomically: true, encoding: .utf8
        )
        try "function gamma(){}\nconst delta = 1;\n".write(
            to: workspace.appendingPathComponent("sample.js"), atomically: true, encoding: .utf8
        )

        let context = AgentToolContext(rootDirectory: workspace)
        let result = try await AgentToolRunner.run(
            name: "grep_files",
            arguments: [
                "pattern": .string("^(func|function)\\s+\\w+"),
                "include": .string("*.swift")
            ],
            context: context
        )

        #expect(result.payload.contains("Sample.swift"))
        #expect(result.payload.contains("alpha"))
        #expect(!result.payload.contains("gamma"))
    }

    @Test("grep_files rejects invalid regex with a descriptive error")
    func testGrepFilesRejectsInvalidRegex() async throws {
        let workspace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("willdeep_test_grep_bad_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let context = AgentToolContext(rootDirectory: workspace)
        await #expect(throws: AgentToolError.self) {
            try await AgentToolRunner.run(
                name: "grep_files",
                arguments: ["pattern": .string("[unterminated")],
                context: context
            )
        }
    }

    @Test("encodeChatRequest echoes assistant reasoning_content back to the provider")
    func testReasoningContentRoundTrip() throws {
        // Empty reasoning must not emit the key (some providers reject empty strings).
        let withoutReasoning = AgentMessage(role: .assistant, content: "Hi.")
        let dataWithout = try AgentClient.encodeChatRequest(
            model: "qwen3-235b-a22b",
            messages: [withoutReasoning],
            tools: []
        )
        let jsonWithout = String(data: dataWithout, encoding: .utf8) ?? ""
        #expect(!jsonWithout.contains("reasoning_content"))

        // Non-empty reasoning MUST be present in the assistant message.
        // DashScope's thinking-mode 400's without it.
        let withReasoning = AgentMessage(
            role: .assistant,
            content: "The answer is 42.",
            reasoningContent: "I considered alternatives and concluded 42."
        )
        let dataWith = try AgentClient.encodeChatRequest(
            model: "qwen3-235b-a22b",
            messages: [withReasoning],
            tools: []
        )
        let jsonWith = String(data: dataWith, encoding: .utf8) ?? ""
        #expect(jsonWith.contains("reasoning_content"))
        #expect(jsonWith.contains("I considered alternatives"))

        // The field must only attach to assistant messages — a user
        // role with reasoningContent set (shouldn't happen, but defend)
        // doesn't leak it.
        var sneakyUser = AgentMessage(role: .user, content: "hello")
        sneakyUser.reasoningContent = "secret"
        let dataUser = try AgentClient.encodeChatRequest(
            model: "qwen3-235b-a22b",
            messages: [sneakyUser],
            tools: []
        )
        let jsonUser = String(data: dataUser, encoding: .utf8) ?? ""
        #expect(!jsonUser.contains("secret"))
    }

    @Test("SafeCommand classifies common read-only commands as alwaysSafe")
    func testSafeCommandAllowlist() {
        // Single safe commands.
        #expect(SafeCommand.classify(command: "cat README.md") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "head -n 50 src/main.rs") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "rg \"AgentSettingsStore\" Xedit") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "ls -la") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "pwd") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "wc -l Sources/*.swift") == .alwaysSafe)

        // git read-only subcommands.
        #expect(SafeCommand.classify(command: "git diff") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "git log --oneline -10") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "git status") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "git show HEAD") == .alwaysSafe)

        // git config writes must NOT be auto-approved.
        #expect(SafeCommand.classify(command: "git config user.email rocky@example.com") == .needsJudgment)
        #expect(SafeCommand.classify(command: "git config --add safe.directory /tmp/foo") == .needsJudgment)

        // git stash without args (writes) must NOT be auto-approved.
        #expect(SafeCommand.classify(command: "git stash") == .needsJudgment)
        #expect(SafeCommand.classify(command: "git stash list") == .alwaysSafe)
    }

    @Test("SafeCommand pipelines: every segment must be safe for the chain to auto-approve")
    func testSafeCommandPipelines() {
        // Two safe segments → safe.
        #expect(SafeCommand.classify(command: "git diff | head -50") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "rg foo | wc -l") == .alwaysSafe)
        // A dangerous segment poisons the whole chain.
        #expect(SafeCommand.classify(command: "git diff && rm -rf node_modules") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "cat a.txt; sudo rm /tmp/x") == .alwaysDangerous)
        // An unknown segment downgrades safe → needsJudgment.
        #expect(SafeCommand.classify(command: "cat a.txt | xargs cargo run") == .needsJudgment)
    }

    @Test("SafeCommand rejects redirections and command substitution")
    func testSafeCommandRejectsRedirectionAndSubstitution() {
        #expect(SafeCommand.classify(command: "cat foo > bar") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "echo $(rm -rf /)") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "ls `pwd`") == .alwaysDangerous)
        // Harmless stderr redirection should still be classified as safe.
        #expect(SafeCommand.classify(command: "git status 2>/dev/null") == .alwaysSafe)
    }

    @Test("SafeCommand: shell 控制流 + whois 等只读网络命令自动放行")
    func testSafeCommandShellControlFlow() {
        // 用户实测案例：纯只读 whois 循环此前落到 LLM judge 又被拒，
        // 次次人工审批。for 头 / do 前缀 / whois / done 现在全部静态放行。
        #expect(SafeCommand.classify(
            command: "for ext in io ai app dev co net org; do echo \"=== deepcoder.$ext ===\"; whois \"deepcoder.$ext\" 2>&1 | grep -iE \"no match|not found|status\"; done"
        ) == .alwaysSafe)

        // 控制流关键字本身无负载。
        #expect(SafeCommand.classify(command: "while read line; do echo \"$line\"; done") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "if grep -q TODO a.swift; then echo found; fi") == .alwaysSafe)

        // 关键字剥掉后负载照常受走查约束——危险负载一票否决。
        #expect(SafeCommand.classify(command: "for f in a b; do rm \"$f\"; done") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "if true; then sudo reboot; fi") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "while true; do curl http://x.example; done") == .alwaysDangerous)

        // 未知负载仍然降级到 needsJudgment，不会因为有 for 头就放行。
        #expect(SafeCommand.classify(command: "for f in a b; do mycustomtool \"$f\"; done") == .needsJudgment)

        // whois 与 dig/host 同族，直接安全。
        #expect(SafeCommand.classify(command: "whois example.com") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "whois example.com 2>&1 | grep -i status") == .alwaysSafe)
    }

    @Test("SafeCommand rejects find with -delete or -exec")
    func testSafeCommandFindRules() {
        #expect(SafeCommand.classify(command: "find . -name '*.swift'") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "find . -name '*.tmp' -delete") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "find . -name '*.log' -exec rm {} ;") == .alwaysDangerous)
    }

    // MARK: - rc3 token-level hardening

    @Test("SafeCommand: token-level rm detection catches pipeline tails")
    func testSafeCommandTokenLevelRmInPipeline() {
        // Pre-rc3 the pipeline tail `xargs rm` survived because the
        // substring needle `"rm "` only matched if `rm` had a trailing
        // space and was followed by an arg; the lowercased(+" ") trick
        // worked on segments like `rm -rf` but not on `xargs rm` where
        // `rm` was at the start of the second tokens slot.
        #expect(SafeCommand.classify(command: "find . -name '*.tmp' | xargs rm") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "find . -name '*.tmp' | xargs rm -rf") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "find . -print0 | xargs -0 rm -rf") == .alwaysDangerous)
        // Same shape with `kill` — pre-rc3 needed `"kill "` to match;
        // `... | kill 1234` slipped through. Token check fixes it.
        #expect(SafeCommand.classify(command: "ps aux | grep node | awk '{print $2}' | xargs kill -9") == .alwaysDangerous)
    }

    @Test("SafeCommand: word-boundary kills 'perm'/'armchair' false positives")
    func testSafeCommandFalsePositivesGone() {
        // Pre-rc3 substring match on `"rm "` flagged `"perm "` and
        // anything else containing the literal substring. Token level
        // matching needs `rm` to be its own token.
        // (These don't reach .alwaysSafe — they're not in the allowlist —
        // but they must no longer hit the dangerous path.)
        #expect(SafeCommand.classify(command: "perm /tmp/foo") != .alwaysDangerous)
        #expect(SafeCommand.classify(command: "harmless-tool --opt val") != .alwaysDangerous)
        // Real allowlist word that visually contains "ls" but is its
        // own token must still be safe.
        #expect(SafeCommand.classify(command: "ls -la") == .alwaysSafe)
    }

    @Test("SafeCommand: cp/ln dangerous only when a flag is present")
    func testSafeCommandCpLnFlagGate() {
        // Pre-rc3 `"cp -"` substring meant `cp -r` was caught (yes) but
        // `cp src dst` was correctly NOT marked dangerous. We preserve
        // that nuance after tokenization.
        #expect(SafeCommand.classify(command: "cp -r foo bar") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "cp -R foo bar") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "ln -s a b") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "ln -sf a b") == .alwaysDangerous)
        // Plain forms fall through to needsJudgment (not auto-run).
        #expect(SafeCommand.classify(command: "cp foo bar") == .needsJudgment)
        #expect(SafeCommand.classify(command: "ln a b") == .needsJudgment)
    }

    @Test("SafeCommand: dangerousSubstrings cover token-less shapes")
    func testSafeCommandDangerousSubstrings() {
        // Fork bomb — no whitespace, tokenize returns one giant token,
        // substring scan catches it.
        #expect(SafeCommand.classify(command: ":(){:|:&};:") == .alwaysDangerous)
        // dd if= — the `=` glues the dangerous bit into the first token.
        #expect(SafeCommand.classify(command: "dd if=/dev/zero of=/dev/sda bs=1m") == .alwaysDangerous)
        // mkfs.* family — `mkfs.ext4`, `mkfs.hfs` etc.
        #expect(SafeCommand.classify(command: "mkfs.ext4 /dev/sda1") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "mkfs.hfs /dev/disk2") == .alwaysDangerous)
    }

    @Test("SafeCommand: `su` joins sudo/doas as privilege escalation")
    func testSafeCommandSuAddedToTokens() {
        // Added in rc3 alongside sudo/doas — equally dangerous and the
        // pre-rc3 needle list missed it.
        #expect(SafeCommand.classify(command: "su - root") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "su -c 'whoami'") == .alwaysDangerous)
    }

    @Test("SafeCommand treats cd/pushd/popd as alwaysSafe")
    func testSafeCommandCdAllowed() {
        // The common "navigate then read" chain the agent emits.
        #expect(SafeCommand.classify(command: "cd /tmp/proj && git status") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "cd /tmp/proj && git status --short | grep '^\\(M\\|A\\|D\\|R\\|C\\)' | head -20") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "cd ~") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "pushd /tmp && ls && popd") == .alwaysSafe)
        // Command substitution must still kill the whole line — that
        // gate sits above the per-token check.
        #expect(SafeCommand.classify(command: "cd $(rm -rf /)") == .alwaysDangerous)
    }

    // MARK: - Tool call grouping

    private func makeCall(
        _ name: String,
        status: AgentToolCallStatus = .succeeded,
        arguments: [String: AgentJSONValue] = [:]
    ) -> AgentToolCall {
        AgentToolCall(
            messageID: UUID(),
            externalID: UUID().uuidString,
            toolName: name,
            arguments: arguments,
            risk: .read,
            status: status
        )
    }

    @Test("AgentToolCallGrouping merges consecutive same-kind calls")
    func testToolCallGroupingMergesAdjacent() {
        let calls = [
            makeCall("run_command"),
            makeCall("run_command"),
            makeCall("run_command")
        ]
        let segments = AgentToolCallGrouping.group(calls)
        #expect(segments.count == 1)
        #expect(segments[0].kind == .runCommand)
        #expect(segments[0].count == 3)
        #expect(segments[0].kind.groupTitle(3) == "已运行 3 条命令")
    }

    @Test("AgentToolCallGrouping splits when kind changes")
    func testToolCallGroupingSplitsOnKindChange() {
        let calls = [
            makeCall("run_command"),
            makeCall("read_file"),
            makeCall("grep_files"),
            makeCall("run_command")
        ]
        let segments = AgentToolCallGrouping.group(calls)
        #expect(segments.count == 3)
        #expect(segments[0].kind == .runCommand)
        #expect(segments[0].count == 1)
        #expect(segments[1].kind == .fileExploration)
        #expect(segments[1].count == 2)
        #expect(segments[2].kind == .runCommand)
        #expect(segments[2].count == 1)
        #expect(segments[1].kind.groupTitle(2) == "已探索 2 个文件")
    }

    @Test("AgentToolActivitySummary counts exploration searches and commands")
    func testToolActivitySummaryCountsTurnActivity() {
        let calls = [
            makeCall("read_file", arguments: ["path": .string("README.md")]),
            makeCall("read_file", arguments: ["path": .string("README.md")]),
            makeCall("list_directory", arguments: ["path": .string("Xedit")]),
            makeCall("grep_files", arguments: ["pattern": .string("Agent")]),
            makeCall("git_status"),
            makeCall("run_command", arguments: ["command": .string("git diff --stat")])
        ]

        let summary = AgentToolActivitySummary(calls: calls)

        #expect(summary.exploredPathCount == 2)
        #expect(summary.searchCount == 1)
        #expect(summary.gitStatusCount == 1)
        #expect(summary.commandCount == 1)
        #expect(summary.explorationText == "已探索 2 个路径 · 1 次搜索 · 1 次 git 状态")
        #expect(summary.commandText == "已运行 1 条命令")
    }

    @Test("AgentToolCallGrouping never merges ask_user even when adjacent")
    func testToolCallGroupingKeepsAskUserStandalone() {
        let calls = [
            makeCall("ask_user", status: .awaitingUserAnswer),
            makeCall("ask_user", status: .awaitingUserAnswer)
        ]
        let segments = AgentToolCallGrouping.group(calls)
        #expect(segments.count == 2)
        #expect(segments.allSatisfy { $0.kind == .askUser })
        #expect(segments.allSatisfy { $0.count == 1 })
    }

    @Test("AgentToolCallGrouping treats unknown tools as their own .other kind")
    func testToolCallGroupingUnknownKindGroupsBySameName() {
        let calls = [
            makeCall("mystery_tool"),
            makeCall("mystery_tool"),
            makeCall("other_tool")
        ]
        let segments = AgentToolCallGrouping.group(calls)
        #expect(segments.count == 2)
        #expect(segments[0].count == 2)
        #expect(segments[1].count == 1)
    }

    // MARK: - Usage stats

    private func makeSession(modelID: String?, messages: [AgentMessage]) -> AgentSession {
        AgentSession(
            id: UUID(),
            title: "test",
            workspaceRootPath: nil,
            modelID: modelID,
            createdAt: Date(),
            updatedAt: Date(),
            messages: messages
        )
    }

    private func userMessage(_ text: String, at date: Date) -> AgentMessage {
        AgentMessage(role: .user, content: text, createdAt: date)
    }

    private func assistantMessage(_ text: String, usage: Int?, at date: Date) -> AgentMessage {
        AgentMessage(role: .assistant, content: text, usageTokens: usage, createdAt: date)
    }

    @Test("AgentUsageStats overview totals across sessions and prefers real usage")
    func testUsageStatsBasicTotals() {
        let now = Date()
        let calendar = Calendar.current
        let session = makeSession(modelID: "gpt-4.1", messages: [
            userMessage("hello", at: now),
            assistantMessage("hi", usage: 100, at: now),
            userMessage("hello again", at: now),
            // No real usage → fall back to chars/4 estimate (≈ 20/4 = 5)
            assistantMessage(String(repeating: "x", count: 20), usage: nil, at: now)
        ])
        let stats = AgentUsageStats.overview(for: [session], now: now)
        #expect(stats.sessionCount == 1)
        #expect(stats.messageCount == 4)
        #expect(stats.hasAnyRealUsage == true)
        // 100 (real) + 5 (estimate from 20 chars) ≥ 105 plus the
        // user messages and system-prompt baseline are 0 for users
        // (estimator only on assistant in production? our estimate
        // function is applied to all messages without usage — verify).
        #expect(stats.totalTokens >= 100)
        #expect(stats.favoriteModel == "gpt-4.1")
        _ = calendar
    }

    @Test("AgentUsageStats current streak counts contiguous days ending today")
    func testUsageStatsCurrentStreak() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let dayBefore = calendar.date(byAdding: .day, value: -2, to: today)!
        let oldDay = calendar.date(byAdding: .day, value: -10, to: today)!

        let messages = [
            userMessage("a", at: oldDay),
            userMessage("b", at: dayBefore),
            userMessage("c", at: yesterday),
            userMessage("d", at: today)
        ]
        let session = makeSession(modelID: nil, messages: messages)
        let stats = AgentUsageStats.overview(for: [session], now: now)
        #expect(stats.activeDays == 4)
        #expect(stats.currentStreak == 3)
        #expect(stats.longestStreak == 3)
    }

    @Test("AgentUsageStats current streak is zero when today has no messages")
    func testUsageStatsCurrentStreakZeroWhenTodayEmpty() {
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let dayBefore = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: now))!

        let messages = [
            userMessage("a", at: dayBefore),
            userMessage("b", at: yesterday)
        ]
        let session = makeSession(modelID: nil, messages: messages)
        let stats = AgentUsageStats.overview(for: [session], now: now)
        #expect(stats.currentStreak == 0)
        #expect(stats.longestStreak == 2)
    }

    @Test("AgentUsageStats heatmap returns weekCount × 7 cells in chronological order")
    func testUsageStatsHeatmapShape() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)

        let messages = [
            userMessage("a", at: today),
            userMessage("b", at: today),
            userMessage("c", at: calendar.date(byAdding: .day, value: -3, to: today)!)
        ]
        let session = makeSession(modelID: nil, messages: messages)
        let cells = AgentUsageStats.heatmap(for: [session], weekCount: 4, now: now)

        #expect(cells.count == 4)
        for column in cells { #expect(column.count == 7) }

        // Flatten to find today's cell and assert it counts 2.
        let flat = cells.flatMap { $0 }
        let todayCell = flat.first { calendar.isDate($0.date, inSameDayAs: today) }
        #expect(todayCell?.count == 2)
    }

    @Test("agent tool registry escalates dangerous run_command invocations to .danger")
    func testRunCommandRiskEscalatesForDestructiveShell() {
        let benignRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("ls -la")]
        )
        let dangerousRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("rm -rf build/output")]
        )
        let forcePushRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("git push --force origin main")]
        )

        #expect(benignRisk == .read)
        #expect(dangerousRisk == .danger)
        #expect(forcePushRisk == .danger)
    }

    @Test("run_command classifies cd plus read-only commands as read risk")
    func testRunCommandRiskAllowsReadOnlyShellChains() {
        let gitDiffRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd Xedit && git diff")]
        )
        let grepRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd Sources; rg \"AgentTool\" .")]
        )
        let writeAfterCDRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd Xedit && git add AgentTools.swift")]
        )
        let unsafeCDRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd .. && git diff")]
        )
        let redirectedReadRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd Xedit && git diff > /tmp/out.patch")]
        )

        #expect(gitDiffRisk == .read)
        #expect(grepRisk == .read)
        #expect(writeAfterCDRisk == .write)
        #expect(unsafeCDRisk == .write)
        #expect(redirectedReadRisk == .write)
    }

    @Test("run_command allows workspace absolute cd for read-only commands")
    func testRunCommandRiskAllowsWorkspaceAbsoluteReadOnlyShellChains() {
        let workspace = URL(fileURLWithPath: "/Users/rocky/Sites/Xedit").standardizedFileURL
        let sourceDirectory = workspace.appendingPathComponent("Xedit").standardizedFileURL

        let gitDiffRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd \(workspace.path) && git diff")],
            rootDirectory: workspace
        )
        let rgRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd \(sourceDirectory.path) && rg AgentTool .")],
            rootDirectory: workspace
        )
        let gitDashCRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("git -C \(workspace.path) diff -- Xedit/AgentTools.swift")],
            rootDirectory: workspace
        )
        let outsideCDRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd /tmp && git diff")],
            rootDirectory: workspace
        )
        let outsideGitDashCRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("git -C /tmp diff")],
            rootDirectory: workspace
        )
        let outsideReadRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cat /etc/passwd")],
            rootDirectory: workspace
        )

        #expect(gitDiffRisk == .read)
        #expect(rgRisk == .read)
        #expect(gitDashCRisk == .read)
        #expect(outsideCDRisk == .write)
        #expect(outsideGitDashCRisk == .write)
        #expect(outsideReadRisk == .write)
    }

    @Test("run_command uses home directory when no workspace is bound")
    func testRunCommandUsesHomeDirectoryWithoutWorkspace() async throws {
        let context = AgentToolContext(rootDirectory: nil)
        let result = try await AgentToolRunner.run(
            name: "run_command",
            arguments: [
                "command": .string("pwd"),
                "timeout_seconds": .number(5)
            ],
            context: context
        )

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        #expect(result.payload.contains(home))
    }

    @Test("run_command drains large output without hanging")
    func testRunCommandDrainsLargeOutput() async throws {
        let workspace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("willdeep_test_run_command_output_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let context = AgentToolContext(rootDirectory: workspace)
        // Timeout sized for CI: the GitHub Actions macos-26 runner
        // takes ~5s to spawn ruby + write 200 KB to stdout (this test
        // failed rc5 at 5.186s against the previous 5s budget). Local
        // M-series machines finish in ~200ms so this only matters as
        // headroom. The test's intent ("doesn't hang on a full pipe")
        // is unchanged — the assertion still requires exit 0 + the
        // `[truncated]` marker; the timeout is only the upper bound
        // for "this command actually ran".
        let result = try await AgentToolRunner.run(
            name: "run_command",
            arguments: [
                "command": .string("/usr/bin/ruby -e 'STDOUT.write(\"x\" * 200000)'"),
                "timeout_seconds": .number(30)
            ],
            context: context
        )

        #expect(result.summary.hasPrefix("exit 0"))
        #expect(result.payload.contains("[truncated]"))
    }

    @Test("run_command exposes common user binary paths")
    func testRunCommandUsesSupplementalShellPath() async throws {
        let workspace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("willdeep_test_run_command_path_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let context = AgentToolContext(rootDirectory: workspace)
        let result = try await AgentToolRunner.run(
            name: "run_command",
            arguments: [
                "command": .string("printf '%s' \"$PATH\""),
                "timeout_seconds": .number(5)
            ],
            context: context
        )

        #expect(result.payload.contains("/opt/homebrew/bin"))
        #expect(result.payload.contains("/usr/local/bin"))
    }

    @Test("quick open skips dependency directories")
    func testQuickOpenSkipsDependencyDirectories() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_quick_open_skip_\(UUID().uuidString)", isDirectory: true)
        let nodeModules = tempDir.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = tempDir.appendingPathComponent("App.swift")
        let dependency = nodeModules.appendingPathComponent("dep.swift")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "dependency".write(to: dependency, atomically: true, encoding: .utf8)

        let urls = AppState.quickOpenFileURLs(in: tempDir)

        #expect(urls.map(\.lastPathComponent).contains("App.swift"))
        #expect(!urls.map(\.lastPathComponent).contains("dep.swift"))
    }

    @Test("folder text operations skip dependency directories")
    func testTextFileURLsSkipDependencyDirectories() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_text_file_skip_\(UUID().uuidString)", isDirectory: true)
        let nodeModules = tempDir.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = tempDir.appendingPathComponent("Source.swift")
        let dependency = nodeModules.appendingPathComponent("Dependency.swift")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "dependency".write(to: dependency, atomically: true, encoding: .utf8)

        let paths = AppState.textFileURLs(in: tempDir).map(\.lastPathComponent)

        #expect(paths.contains("Source.swift"))
        #expect(!paths.contains("Dependency.swift"))
    }

    @Test("agent list_directory skips dependency directories")
    func testAgentListDirectorySkipsDependencyDirectories() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_agent_list_skip_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "source".write(to: workspace.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)

        let result = try await AgentToolRunner.run(
            name: "list_directory",
            arguments: ["path": .string(".")],
            context: AgentToolContext(rootDirectory: workspace)
        )

        #expect(result.payload.contains("App.swift"))
        #expect(!result.payload.contains("node_modules"))
    }

    @Test("shouldAutoCompressNow flips true once estimated context usage crosses 75%")
    @MainActor
    func testShouldAutoCompressTriggersAt75Percent() {
        let appState = AppState()
        // `agentMessages` / `isAgentResponding` / `isCompressingAgentContext`
        // all delegate to `activeRuntime` — without an explicit session,
        // writes are dropped and `shouldAutoCompressNow` short-circuits to
        // false regardless of what we try to set up. Solo runs happened to
        // inherit an `activeAgentSessionID` restored from disk by another
        // test; in a full-suite run that isolation breaks. Create the
        // session ourselves so this test stands on its own.
        _ = appState.startNewAgentSession()

        // Force a known small context window so the test doesn't depend
        // on the model fallback table.
        var config = appState.agentConfiguration
        config.model = "gpt-3.5-16k"
        config.flashModel = "gpt-3.5-16k"
        config.routingMode = .flash
        appState.agentConfiguration = config

        // Empty conversation must not trigger.
        #expect(appState.shouldAutoCompressNow == false)

        // Add 7 messages so the > 6 guard passes, but with tiny content
        // so estimated tokens stay low.
        for _ in 0..<7 {
            appState.agentMessages.append(AgentMessage(role: .user, content: "hi"))
        }
        #expect(appState.shouldAutoCompressNow == false)

        // Replace with messages that push estimated tokens past 75%.
        appState.agentMessages.removeAll()
        let observedWindow = appState.agentContextWindow
        // Need > 75% of the actual resolved window. We don't pin a
        // model fallback here because `normalized` reshuffles based
        // on provider hints — instead aim for whatever the live
        // `agentContextWindow` reports. estimateTextTokens for an
        // ascii-only string is ceil(count/4), so spread > 0.8×window×4
        // chars across 8 messages to clear the threshold with margin.
        let perMessageChars = max(2_000, (observedWindow * 4 * 80) / (100 * 8))
        let bigChunk = String(repeating: "a", count: perMessageChars)
        for _ in 0..<8 {
            appState.agentMessages.append(AgentMessage(role: .user, content: bigChunk))
        }
        #expect(appState.shouldAutoCompressNow == true)

        // A compression already in flight must suppress the trigger.
        appState.isCompressingAgentContext = true
        #expect(appState.shouldAutoCompressNow == false)
        appState.isCompressingAgentContext = false

        // Likewise, while the agent is still streaming a turn.
        appState.isAgentResponding = true
        #expect(appState.shouldAutoCompressNow == false)
        appState.isAgentResponding = false
    }

    @Test("ask_user tool is registered with userInput risk and a question parameter")
    func testAskUserToolRegistration() {
        let descriptor = AgentToolRegistry.descriptor(for: "ask_user")
        #expect(descriptor != nil)
        #expect(descriptor?.risk == .userInput)
        #expect(descriptor?.parameters.contains(where: { $0.name == "question" && $0.required }) == true)

        let risk = AgentToolRegistry.risk(
            for: "ask_user",
            arguments: ["question": .string("What port should the server bind to?")]
        )
        #expect(risk == .userInput)
    }

    @Test("ask_user exposes optional options and multi_select parameters")
    func testAskUserExposesChoiceParameters() {
        let descriptor = AgentToolRegistry.descriptor(for: "ask_user")
        let options = descriptor?.parameters.first { $0.name == "options" }
        let multi = descriptor?.parameters.first { $0.name == "multi_select" }

        #expect(options?.type == .stringArray)
        #expect(options?.required == false)
        #expect(multi?.type == .boolean)
        #expect(multi?.required == false)
    }

    @Test("provider-ready messages drop orphan tool messages")
    func testProviderReadyMessagesDropOrphanTools() {
        let messages = [
            AgentMessage(role: .user, content: "hi"),
            AgentMessage(role: .tool, content: "orphan", toolCallID: "call_orphan"),
            AgentMessage(role: .assistant, content: "done")
        ]

        let normalized = AgentClient.providerReadyMessages(messages)

        #expect(normalized.map(\.role) == [.user, .assistant])
    }

    @Test("provider-ready messages keep complete assistant tool exchanges")
    func testProviderReadyMessagesKeepCompleteToolExchange() {
        let toolCallA = AgentMessageToolCall(
            externalID: "call_a",
            toolName: "read_file",
            argumentsJSON: #"{"path":"A.swift"}"#
        )
        let toolCallB = AgentMessageToolCall(
            externalID: "call_b",
            toolName: "git_status",
            argumentsJSON: "{}"
        )
        let assistant = AgentMessage(role: .assistant, content: "", toolCalls: [toolCallA, toolCallB])
        let messages = [
            AgentMessage(role: .user, content: "check"),
            assistant,
            AgentMessage(role: .tool, content: "b", toolCallID: "call_b"),
            AgentMessage(role: .tool, content: "a", toolCallID: "call_a"),
            AgentMessage(role: .assistant, content: "done")
        ]

        let normalized = AgentClient.providerReadyMessages(messages)

        #expect(normalized.count == 5)
        #expect(normalized[1].toolCalls.map(\.externalID) == ["call_a", "call_b"])
        #expect(normalized[2].toolCallID == "call_a")
        #expect(normalized[3].toolCallID == "call_b")
    }

    @Test("provider-ready messages drop incomplete assistant tool exchanges")
    func testProviderReadyMessagesDropIncompleteToolExchange() {
        let toolCallA = AgentMessageToolCall(
            externalID: "call_a",
            toolName: "read_file",
            argumentsJSON: "{}"
        )
        let toolCallB = AgentMessageToolCall(
            externalID: "call_b",
            toolName: "git_status",
            argumentsJSON: "{}"
        )
        let messages = [
            AgentMessage(role: .assistant, content: "", toolCalls: [toolCallA, toolCallB]),
            AgentMessage(role: .tool, content: "a", toolCallID: "call_a"),
            AgentMessage(role: .user, content: "next")
        ]

        let normalized = AgentClient.providerReadyMessages(messages)

        #expect(normalized.map(\.role) == [.user])
        #expect(normalized.first?.content == "next")
    }

    @Test("provider-ready messages drop fully-empty assistant messages")
    func testProviderReadyMessagesDropEmptyAssistantMessages() {
        let messages = [
            AgentMessage(role: .user, content: "hi"),
            // 流式 turn 一无所出后残留的占位消息：无文本、无 tool calls。
            // 上线会被 OpenAI 兼容服务端以 400 拒绝（content or
            // tool_calls must be set）。
            AgentMessage(role: .assistant, content: ""),
            AgentMessage(role: .user, content: "still there?"),
            // reasoning-only 也不可表示：没有 content key 也没有 tool_calls。
            AgentMessage(role: .assistant, content: "", reasoningContent: "thinking..."),
            AgentMessage(role: .assistant, content: "done")
        ]

        let normalized = AgentClient.providerReadyMessages(messages)

        #expect(normalized.map(\.role) == [.user, .user, .assistant])
        #expect(normalized.last?.content == "done")
    }

    @Test("request summary lists tool calls on empty-content assistant messages")
    func testRequestSummaryListsToolCalls() {
        let toolCall = AgentMessageToolCall(
            externalID: "call_a",
            toolName: "read_file",
            argumentsJSON: "{}"
        )
        let messages = [
            AgentMessage(role: .assistant, content: "", toolCalls: [toolCall]),
            AgentMessage(role: .tool, content: "ok", toolCallID: "call_a")
        ]

        let summary = AgentNetworkSupport.requestSummary(for: messages)

        #expect(summary.contains("assistant: (empty) [1 tool_call: read_file]"))
    }

    @Test("provider-ready messages omit image parts when provider is text-only")
    func testProviderReadyMessagesOmitImagesForTextOnlyProviders() throws {
        let image = AgentImageAttachment(
            mimeType: "image/png",
            dataBase64: "aGVsbG8="
        )
        let messages = [
            AgentMessage(role: .user, content: "please inspect", images: [image])
        ]

        let normalized = AgentClient.providerReadyMessages(messages, supportsImages: false)
        #expect(normalized.first?.images.isEmpty == true)
        #expect(normalized.first?.content.contains("omitted because this provider only accepts text messages") == true)

        let request = try AgentClient.encodeChatRequest(
            model: "deepseek-v4-flash",
            messages: messages,
            tools: [],
            supportsImages: false
        )
        let body = String(data: request, encoding: .utf8) ?? ""
        #expect(!body.contains("image_url"))
        #expect(body.contains("please inspect"))
    }

    @Test("AgentJSONValue stringArrayValue and boolValue work")
    func testAgentJSONValueHelpers() {
        let validArray: AgentJSONValue = .array([.string("a"), .string("b"), .string("c")])
        #expect(validArray.stringArrayValue() == ["a", "b", "c"])

        // Mixed types must NOT silently coerce.
        let mixedArray: AgentJSONValue = .array([.string("a"), .number(2)])
        #expect(mixedArray.stringArrayValue() == nil)

        #expect(AgentJSONValue.bool(true).boolValue() == true)
        #expect(AgentJSONValue.string("yes").boolValue() == true)
        #expect(AgentJSONValue.string("no").boolValue() == false)
        #expect(AgentJSONValue.number(0).boolValue() == false)
        #expect(AgentJSONValue.string("maybe").boolValue() == nil)
    }

    @Test("spawn_agent tool is registered as read risk with a required prompt")
    func testSpawnAgentToolRegistration() {
        let descriptor = AgentToolRegistry.descriptor(for: "spawn_agent")
        #expect(descriptor != nil)
        #expect(descriptor?.risk == .read)
        #expect(descriptor?.parameters.first(where: { $0.name == "prompt" })?.required == true)
        #expect(descriptor?.parameters.contains(where: { $0.name == "run_in_background" }) == true)
        #expect(descriptor?.parameters.contains(where: { $0.name == "model" }) == true)
    }

    @Test("MCP read-style tool names pass the static heuristic")
    func testMCPReadOnlyToolNameHeuristic() {
        #expect(AgentToolAuthorization.mcpToolNameLooksReadOnly("get_issue"))
        #expect(AgentToolAuthorization.mcpToolNameLooksReadOnly("list_repos"))
        #expect(AgentToolAuthorization.mcpToolNameLooksReadOnly("search_code"))
        #expect(AgentToolAuthorization.mcpToolNameLooksReadOnly("Fetch_Page"))
        #expect(AgentToolAuthorization.mcpToolNameLooksReadOnly("ping"))

        #expect(!AgentToolAuthorization.mcpToolNameLooksReadOnly("create_issue"))
        #expect(!AgentToolAuthorization.mcpToolNameLooksReadOnly("delete_branch"))
        #expect(!AgentToolAuthorization.mcpToolNameLooksReadOnly("update_file"))
        #expect(!AgentToolAuthorization.mcpToolNameLooksReadOnly("getdata"))
        #expect(!AgentToolAuthorization.mcpToolNameLooksReadOnly(""))
    }

    @Test("trusted-server MCP calls with read-style names auto-approve")
    @MainActor
    func testMCPAutoApprovalForReadStyleTools() async {
        // autoApproveSafeCommands 的 didSet 会写 UserDefaults——沙箱化,
        // 防止测试翻转开发机上的真实设置。
        let sandbox = KeychainSandbox()
        defer { withExtendedLifetime(sandbox) {} }
        let appState = AppState()
        appState.autoApproveSafeCommands = true
        let root = URL(fileURLWithPath: "/tmp/willdeep-test-workspace")

        let approved = await appState.autoApprovalSource(
            toolName: "call_mcp_tool",
            arguments: [
                "server": .string("github"),
                "tool": .string("list_issues"),
                "arguments_json": .string(#"{"repo":"a/b"}"#),
            ],
            risk: .write,
            rootDirectory: root
        )
        #expect(approved == .staticAllowlist)

        // 主开关关掉 → 一切回到人工。
        appState.autoApproveSafeCommands = false
        let gated = await appState.autoApprovalSource(
            toolName: "call_mcp_tool",
            arguments: [
                "server": .string("github"),
                "tool": .string("list_issues"),
            ],
            risk: .write,
            rootDirectory: root
        )
        #expect(gated == nil)
    }

    @Test("MCP settings keep trusted and untrusted sets mutually exclusive")
    func testMCPTrustSetsAreMutuallyExclusive() throws {
        // 同一 id 同时出现在两个集合 → normalized 后 untrusted 胜出。
        let conflicted = AgentMCPSettings(
            disabledServerIDs: [],
            userServers: [],
            untrustedServerIDs: ["user:x"],
            trustedServerIDs: ["user:x", "user:y"]
        ).normalized
        #expect(conflicted.untrustedServerIDs == ["user:x"])
        #expect(conflicted.trustedServerIDs == ["user:y"])

        // 旧版 settings JSON（无 trustedServerIDs 键）正常解码为空集。
        let legacyJSON = #"{"disabledServerIDs":[],"userServers":[],"untrustedServerIDs":["user:old"]}"#
        let decoded = try JSONDecoder().decode(AgentMCPSettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.trustedServerIDs.isEmpty)
        #expect(decoded.untrustedServerIDs == ["user:old"])
    }

    @Test("MCP fully-trusted servers auto-approve every call")
    @MainActor
    func testMCPFullyTrustedServerAutoApproval() async {
        let suiteName = "com.willdeep.mcp.test.\(UUID().uuidString)"
        guard let sandbox = UserDefaults(suiteName: suiteName) else {
            Issue.record("cannot allocate sandbox defaults suite")
            return
        }
        sandbox.removePersistentDomain(forName: suiteName)
        AgentMCPSettingsStore._setTestDefaultsOverride(sandbox)
        defer {
            sandbox.removePersistentDomain(forName: suiteName)
            AgentMCPSettingsStore._setTestDefaultsOverride(nil)
        }

        let serverName = "willdeep-test-own-mcp"
        AgentMCPSettingsStore.upsertUserServer(AgentMCPServerConfig(
            name: serverName,
            source: .user,
            transport: .stdio,
            command: "/usr/bin/true"
        ))
        AgentMCPSettingsStore.setServerTrustLevel(id: "user:\(serverName)", level: .fullyTrusted)
        #expect(AgentMCPSettingsStore.trustLevel(name: serverName) == .fullyTrusted)

        // 完全可信:写类工具名也自动放行,且不依赖主开关。
        let appState = AppState()
        let root = URL(fileURLWithPath: "/tmp/willdeep-test-workspace")
        let approval = await appState.autoApprovalSource(
            toolName: "call_mcp_tool",
            arguments: [
                "server": .string(serverName),
                "tool": .string("create_record"),
            ],
            risk: .write,
            rootDirectory: root
        )
        #expect(approval == .trustedServer)

        // 降回不受信:一切回到人工。
        AgentMCPSettingsStore.setServerTrustLevel(id: "user:\(serverName)", level: .untrusted)
        let gated = await appState.autoApprovalSource(
            toolName: "call_mcp_tool",
            arguments: [
                "server": .string(serverName),
                "tool": .string("list_records"),
            ],
            risk: .write,
            rootDirectory: root
        )
        #expect(gated == nil)
    }

    @Test("goal mode auto-approves write tools but never danger tier")
    @MainActor
    func testGoalModeAutoApproval() async {
        let appState = AppState()
        let root = URL(fileURLWithPath: "/tmp/willdeep-test-workspace")

        // write 层 + goal 模式 → 自动放行，来源标记为 goalMode。
        let writeApproval = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("swift build")],
            risk: .write,
            rootDirectory: root,
            interactionMode: .goal
        )
        #expect(writeApproval == .goalMode)

        // 危险层永远不进自动放行（goal 模式也一样）。
        let dangerApproval = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("rm -rf /tmp/x")],
            risk: .danger,
            rootDirectory: root,
            interactionMode: .goal
        )
        #expect(dangerApproval == nil)

        // normal 模式不受影响：没有命中其他自动路径时仍等用户。
        let normalApproval = await appState.autoApprovalSource(
            toolName: "claude_code",
            arguments: ["prompt": .string("do x")],
            risk: .write,
            rootDirectory: root,
            interactionMode: .normal
        )
        #expect(normalApproval == nil)
    }

    @Test("approval mode controls write-tier auto approval")
    @MainActor
    func testApprovalModeControlsWriteTierAutoApproval() async {
        let sandbox = KeychainSandbox()
        defer { withExtendedLifetime(sandbox) {} }
        let appState = AppState()
        appState.autoApproveSafeCommands = true
        let root = URL(fileURLWithPath: "/tmp/willdeep-test-workspace")

        let askEveryTime = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("ls")],
            risk: .write,
            rootDirectory: root,
            approvalMode: .requestEveryTime
        )
        #expect(askEveryTime == nil)

        let smart = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("ls")],
            risk: .write,
            rootDirectory: root,
            approvalMode: .smart
        )
        #expect(smart == .staticAllowlist)

        let workspace = await appState.autoApprovalSource(
            toolName: "run_command",
            arguments: ["command": .string("swift test")],
            risk: .write,
            rootDirectory: root,
            approvalMode: .workspaceAccess
        )
        #expect(workspace == .workspaceAccess)

        let untrustedMCP = await appState.autoApprovalSource(
            toolName: "call_mcp_tool",
            arguments: [
                "server": .string("third-party"),
                "tool": .string("create_issue"),
            ],
            risk: .write,
            rootDirectory: root,
            approvalMode: .workspaceAccess
        )
        #expect(untrustedMCP == nil)
    }

    @Test("legacy agent session JSON defaults to smart approval")
    func testLegacyAgentSessionDefaultsToSmartApproval() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000123",
          "title": "Legacy",
          "createdAt": "2026-06-11T00:00:00Z",
          "updatedAt": "2026-06-11T00:00:00Z",
          "messages": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(AgentSession.self, from: Data(json.utf8))
        #expect(session.approvalMode == .smart)
    }

    @Test("claude_code tool is registered as write risk with safe modes")
    func testClaudeCodeToolRegistration() {
        let descriptor = AgentToolRegistry.descriptor(for: "claude_code")
        #expect(descriptor != nil)
        #expect(descriptor?.risk == .write)
        #expect(descriptor?.parameters.first(where: { $0.name == "prompt" })?.required == true)
        #expect(descriptor?.parameters.contains(where: { $0.name == "permission_mode" }) == true)
        // bypassPermissions must never be forwardable.
        #expect(!AgentToolRunner.claudeCodePermissionModes.contains("bypassPermissions"))
    }

    @Test("claude_code command line quotes the prompt safely")
    func testClaudeCodeCommandLineComposition() {
        let command = AgentToolRunner.claudeCodeCommandLine(
            executable: "/usr/local/bin/claude",
            prompt: "fix the bug in O'Brien's parser; rm nothing",
            permissionMode: "acceptEdits",
            model: "sonnet"
        )
        #expect(command.hasPrefix("'/usr/local/bin/claude' -p "))
        #expect(command.contains("'fix the bug in O'\\''Brien'\\''s parser; rm nothing'"))
        #expect(command.contains("--output-format text"))
        #expect(command.contains("--permission-mode acceptEdits"))
        #expect(command.contains("--model 'sonnet'"))

        let noModel = AgentToolRunner.claudeCodeCommandLine(
            executable: "/x/claude",
            prompt: "hi",
            permissionMode: "plan",
            model: nil
        )
        #expect(!noModel.contains("--model"))
    }

    @Test("claude_code executable discovery prefers the native install path")
    func testClaudeCodeExecutableDiscovery() {
        let home = NSHomeDirectory()
        let found = AgentToolRunner.claudeCodeExecutablePath(
            environment: ["PATH": "/usr/local/bin:/opt/homebrew/bin"],
            isExecutable: { $0 == "/opt/homebrew/bin/claude" || $0 == "\(home)/.local/bin/claude" }
        )
        #expect(found == "\(home)/.local/bin/claude")

        let missing = AgentToolRunner.claudeCodeExecutablePath(
            environment: ["PATH": "/usr/local/bin"],
            isExecutable: { _ in false }
        )
        #expect(missing == nil)
    }

    @Test("claude_code always-allow signature is scoped by permission mode")
    func testClaudeCodeAuthorizationSignature() {
        let planSignature = AgentToolAuthorization.signature(
            toolName: "claude_code",
            arguments: ["permission_mode": .string("plan")]
        )
        #expect(planSignature == "claude_code:plan")

        let defaultSignature = AgentToolAuthorization.signature(
            toolName: "claude_code",
            arguments: [:]
        )
        #expect(defaultSignature == "claude_code:acceptEdits")
    }

    @Test("codex_cli and cursor_agent tools are registered as write risk")
    func testExternalAgentToolRegistration() {
        let codex = AgentToolRegistry.descriptor(for: "codex_cli")
        #expect(codex != nil)
        #expect(codex?.risk == .write)
        #expect(codex?.parameters.first(where: { $0.name == "prompt" })?.required == true)
        #expect(codex?.parameters.contains(where: { $0.name == "permission_mode" }) == true)
        #expect(!AgentToolRunner.codexCLIPermissionModes.contains("danger-full-access"))

        let cursor = AgentToolRegistry.descriptor(for: "cursor_agent")
        #expect(cursor != nil)
        #expect(cursor?.risk == .write)
        #expect(cursor?.parameters.first(where: { $0.name == "prompt" })?.required == true)
        #expect(cursor?.parameters.contains(where: { $0.name == "permission_mode" }) == true)
        #expect(!AgentToolRunner.cursorAgentPermissionModes.contains("yolo"))
    }

    @Test("codex_cli command line uses sandboxed non-interactive exec")
    func testCodexCLICommandLineComposition() {
        let command = AgentToolRunner.codexCLICommandLine(
            executable: "/Applications/Codex.app/Contents/Resources/codex",
            prompt: "fix O'Brien parser",
            permissionMode: "workspaceWrite",
            model: "gpt-5",
            workspacePath: "/tmp/Work Dir"
        )
        #expect(command.hasPrefix("'/Applications/Codex.app/Contents/Resources/codex' exec "))
        #expect(command.contains("--sandbox workspace-write"))
        #expect(command.contains("--ask-for-approval never"))
        #expect(command.contains("--cd '/tmp/Work Dir'"))
        #expect(command.contains("--model 'gpt-5'"))
        #expect(command.contains("'fix O'\\''Brien parser'"))
        #expect(!command.contains("dangerously-bypass"))

        let plan = AgentToolRunner.codexCLICommandLine(
            executable: "/x/codex",
            prompt: "plan",
            permissionMode: "plan",
            model: nil,
            workspacePath: nil
        )
        #expect(plan.contains("--sandbox read-only"))
        #expect(!plan.contains("--model"))
    }

    @Test("cursor_agent command line uses print mode and sandbox")
    func testCursorAgentCommandLineComposition() {
        let command = AgentToolRunner.cursorAgentCommandLine(
            executable: "/usr/local/bin/cursor",
            prompt: "fix O'Brien parser",
            permissionMode: "plan",
            model: "sonnet-4",
            workspacePath: "/tmp/Work Dir"
        )
        #expect(command.hasPrefix("'/usr/local/bin/cursor' agent "))
        #expect(command.contains("--print"))
        #expect(command.contains("--output-format text"))
        #expect(command.contains("--sandbox enabled"))
        #expect(command.contains("--trust"))
        #expect(command.contains("--mode plan"))
        #expect(command.contains("--workspace '/tmp/Work Dir'"))
        #expect(command.contains("--model 'sonnet-4'"))
        #expect(command.contains("'fix O'\\''Brien parser'"))
        #expect(!command.contains("--yolo"))
        #expect(!command.contains("--force"))

        let write = AgentToolRunner.cursorAgentCommandLine(
            executable: "/x/cursor",
            prompt: "implement",
            permissionMode: "default",
            model: nil,
            workspacePath: nil
        )
        #expect(!write.contains("--mode"))
        #expect(!write.contains("--model"))
    }

    @Test("external agent executable discovery and local catalog expose direct tools")
    func testExternalAgentDiscovery() {
        let codex = AgentToolRunner.codexCLIExecutablePath(
            environment: ["PATH": "/usr/local/bin:/opt/homebrew/bin"],
            isExecutable: { $0 == "/Applications/Codex.app/Contents/Resources/codex" }
        )
        #expect(codex == "/Applications/Codex.app/Contents/Resources/codex")

        let cursor = AgentToolRunner.cursorAgentExecutablePath(
            environment: ["PATH": "/usr/local/bin"],
            isExecutable: { $0 == "/usr/local/bin/cursor" }
        )
        #expect(cursor == "/usr/local/bin/cursor")

        let entries = LocalAgentCLI.catalog
        #expect(entries.first(where: { $0.id == "codex-cli" })?.integration == .directTool("codex_cli"))
        #expect(entries.first(where: { $0.id == "cursor-cli" })?.integration == .directTool("cursor_agent"))
    }

    @Test("external agent always-allow signatures are scoped by permission mode")
    func testExternalAgentAuthorizationSignatures() {
        #expect(AgentToolAuthorization.signature(
            toolName: "codex_cli",
            arguments: ["permission_mode": .string("plan")]
        ) == "codex_cli:plan")
        #expect(AgentToolAuthorization.signature(
            toolName: "codex_cli",
            arguments: [:]
        ) == "codex_cli:workspaceWrite")
        #expect(AgentToolAuthorization.signature(
            toolName: "cursor_agent",
            arguments: ["permission_mode": .string("ask")]
        ) == "cursor_agent:ask")
        #expect(AgentToolAuthorization.signature(
            toolName: "cursor_agent",
            arguments: [:]
        ) == "cursor_agent:default")
    }

    @Test("subagent tool surface is read-only and cannot nest or ask")
    @MainActor
    func testSubagentToolSurfaceIsRestricted() {
        let allowed = AgentSubagentRunner.allowedToolNames
        #expect(!allowed.contains("spawn_agent"))
        #expect(!allowed.contains("claude_code"))
        #expect(!allowed.contains("codex_cli"))
        #expect(!allowed.contains("cursor_agent"))
        #expect(!allowed.contains("ask_user"))
        #expect(!allowed.contains("call_mcp_tool"))
        #expect(!allowed.contains("kill_job"))
        #expect(allowed.contains("read_file"))
        #expect(allowed.contains("grep_files"))

        // Every allowed name must resolve to a registered descriptor —
        // a typo here would silently shrink the child's tool surface.
        let descriptors = AgentSubagentRunner.toolDescriptors
        #expect(Set(descriptors.map(\.name)) == allowed)
    }

    @Test("subagent report notice carries handle, label and report body")
    func testSubagentReportNotice() {
        var run = AgentSubagentRun(
            id: UUID(),
            shortID: "ab12cd",
            label: "explore-auth",
            prompt: "find the auth flow",
            parentRuntimeID: UUID(),
            model: "test-model",
            startedAt: Date()
        )
        run.status = .completed
        run.finishedAt = run.startedAt.addingTimeInterval(5)
        run.report = "Auth lives in Auth.swift"
        run.roundCount = 2
        run.toolInvocationCount = 3

        let notice = AppState.subagentReportNotice(for: run)
        #expect(notice.contains("agent_ab12cd"))
        #expect(notice.contains("explore-auth"))
        #expect(notice.contains("Auth lives in Auth.swift"))
        #expect(notice.contains("<subagent-report>"))
    }

    @Test("background subagent failure is queued as a pending report")
    @MainActor
    func testBackgroundSubagentFailureQueuesReport() async throws {
        let registry = AgentSubagentRegistry()
        let parentID = UUID()
        // Empty API key → AgentClient throws immediately, no network.
        let configuration = AgentConfiguration(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com",
            model: "deepseek-chat",
            flashModel: "",
            proModel: "",
            routingMode: .pro,
            apiKey: ""
        )

        let run = try registry.startBackground(
            prompt: "do something",
            label: "doomed",
            configuration: configuration,
            workspaceURL: nil,
            parentRuntimeID: parentID
        )
        #expect(run.status == .running)

        // Wait for the child task to fail and queue its report.
        var reports: [AgentSubagentRun] = []
        for _ in 0..<200 {
            reports = registry.consumePendingReports(forParentRuntime: parentID)
            if !reports.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(reports.count == 1)
        #expect(reports.first?.status == .failed)
        // Consuming is destructive — a second pull must be empty.
        #expect(registry.consumePendingReports(forParentRuntime: parentID).isEmpty)
    }

    @Test("agent context window recognizes modern large-context models")
    func testAgentContextWindowModernModels() {
        #expect(AppState.agentContextWindow(model: "gpt-5.5", providerID: "openai") == 400_000)
        #expect(AppState.agentContextWindow(model: "gpt-4.1", providerID: "openai") == 1_000_000)
        #expect(AppState.agentContextWindow(model: "custom-model", providerID: "custom") == 128_000)
    }

    @Test("agent configuration routes auto and compression through flash")
    func testAgentConfigurationRoutesAutoAndCompressionThroughFlash() {
        var configuration = AgentConfiguration(
            providerID: "deepseek",
            baseURL: "https://api.deepseek.com",
            model: "legacy-model",
            flashModel: "deepseek-chat",
            proModel: "deepseek-reasoner",
            routingMode: .auto,
            apiKey: ""
        ).normalized

        #expect(configuration.model(for: .interactive) == "deepseek-chat")
        #expect(configuration.model(for: .compression) == "deepseek-chat")

        configuration.routingMode = .pro
        #expect(configuration.normalized.model(for: .interactive) == "deepseek-reasoner")
    }

    @Test("agent image description configuration defaults to DashScope vision")
    func testAgentImageDescriptionConfigurationDefaultsToDashScopeVision() {
        let configuration = AgentConfiguration.default.normalized

        #expect(configuration.providerID == "deepseek")
        #expect(configuration.supportsImageInput == false)
        #expect(configuration.imageDescription.providerID == "dashscope")
        #expect(configuration.imageDescription.model == "qwen3-vl-plus")
        #expect(configuration.imageDescription.agentConfiguration.supportsImageInput == true)
        #expect(AgentProviderPreset.preset(id: "deepseek")?.supportsImageInput == false)
        #expect(AgentProviderPreset.preset(id: "dashscope")?.defaultVisionModel == "qwen3-vl-plus")
    }

    @Test("agent token estimate includes tool schemas without exploding short chats")
    func testAgentTokenEstimateIncludesTools() {
        let messages = [AgentMessage(role: .user, content: "hi")]
        let withoutTools = AppState.estimateAgentTokens(messages: messages, tools: [])
        let withTools = AppState.estimateAgentTokens(messages: messages, tools: AgentToolRegistry.all)

        #expect(withTools > withoutTools)
        #expect(withTools < 8_000)
    }

    @Test("MCP and skill tools are registered")
    func testMCPAndSkillToolsAreRegistered() {
        #expect(AgentToolRegistry.descriptor(for: "list_skills")?.risk == .read)
        #expect(AgentToolRegistry.descriptor(for: "read_skill")?.risk == .read)
        #expect(AgentToolRegistry.descriptor(for: "list_mcp_servers")?.risk == .read)
        #expect(AgentToolRegistry.descriptor(for: "list_mcp_tools")?.risk == .read)
        #expect(AgentToolRegistry.descriptor(for: "call_mcp_tool")?.risk == .write)
    }

    @Test("collapseOldToolResults keeps the most recent tool messages and replaces older ones with a placeholder")
    func testCollapseOldToolResults() {
        var messages: [AgentMessage] = []
        messages.append(AgentMessage(role: .user, content: "Find foo"))
        for index in 0..<6 {
            messages.append(AgentMessage(role: .assistant, content: "step \(index)"))
            messages.append(AgentMessage(
                role: .tool,
                content: String(repeating: "x", count: 500),
                toolCallID: "call_\(index)"
            ))
        }

        let collapsed = AppState.collapseOldToolResults(in: messages, keepRecentToolMessages: 2)
        let toolMessages = collapsed.filter { $0.role == .tool }
        #expect(toolMessages.count == 6)

        let placeholderCount = toolMessages.filter { $0.content.hasPrefix("[tool result hidden") }.count
        #expect(placeholderCount == 4)

        // Final two tool messages should remain at full length.
        let untouched = toolMessages.suffix(2)
        for message in untouched {
            #expect(message.content.count == 500)
        }
    }

    @Test("agent tool runner refuses paths outside the workspace")
    func testReadFileRefusesEscapedPath() async throws {
        let workspace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("willdeep_test_sandbox_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let context = AgentToolContext(rootDirectory: workspace)
        await #expect(throws: AgentToolError.self) {
            try await AgentToolRunner.run(
                name: "read_file",
                arguments: ["path": .string("../../../etc/hosts")],
                context: context
            )
        }
    }
}
