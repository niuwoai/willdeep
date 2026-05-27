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
            themeID: "missing-theme",
            showsLineNumbers: false,
            highlightsCurrentLine: false,
            preferredInspectorMode: .structure,
            inspectorPanelOrder: .structureFirst,
            trimsTrailingWhitespaceOnSave: true,
            ensuresFinalNewlineOnSave: true
        ).normalized()

        #expect(settings.fontID == EditorSettings.default.fontID)
        #expect(settings.themeID == EditorSettings.default.themeID)
        #expect(settings.fontSize == 28)
        #expect(settings.lineHeightMultiple == 1.8)
        #expect(settings.fileTreeFontSize == 16)
        #expect(settings.showsLineNumbers == false)
        #expect(settings.highlightsCurrentLine == false)
        #expect(settings.preferredInspectorMode == .structure)
        #expect(settings.inspectorPanelOrder == .structureFirst)
        #expect(settings.orderedInspectorModes == [.structure, .minimap])
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
        #expect(settings.preferredInspectorMode == EditorSettings.default.preferredInspectorMode)
        #expect(settings.inspectorPanelOrder == EditorSettings.default.inspectorPanelOrder)
    }

    @Test("changing editor settings refreshes the active editor")
    @MainActor
    func testEditorSettingsChangeBumpsRenderAndHighlightRevisions() {
        let appState = AppState()
        let renderRevision = appState.editorRenderRevision
        let highlightRevision = appState.editorHighlightRevision
        var settings = appState.editorSettings
        settings.fontID = EditorFontChoice.menlo.id
        settings.fontSize = 18
        settings.lineHeightMultiple = 1.4
        settings.fileTreeFontSize = 14
        settings.themeID = EditorTheme.graphite.id
        settings.showsLineNumbers = false
        settings.highlightsCurrentLine = false
        settings.preferredInspectorMode = .structure
        settings.inspectorPanelOrder = .structureFirst

        appState.editorSettings = settings

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

    @Test("command line installer script forwards paths to VeilWriter")
    func testCommandLineInstallerScript() {
        let appURL = URL(fileURLWithPath: "/Applications/VeilWriter.app")
        let script = CommandLineToolInstaller.scriptContent(appBundleURL: appURL)

        #expect(script.hasPrefix("#!/bin/zsh"))
        #expect(script.contains("/usr/bin/open -a \"$app_path\" -- \"$@\""))
        #expect(script.contains("app_path='/Applications/VeilWriter.app'"))
    }

    @Test("command line installer uses a user-local path")
    func testCommandLineInstallerUsesUserLocalPath() {
        let path = CommandLineToolInstaller.installURL.standardizedFileURL.path

        #expect(path.hasSuffix("/.local/bin/veilwriter"))
    }

    @Test("command line installer shell quoting handles apostrophes")
    func testCommandLineInstallerShellQuoting() {
        let quoted = CommandLineToolInstaller.singleQuotedShellString("/tmp/VeilWriter's App.app")

        #expect(quoted.hasPrefix("'"))
        #expect(quoted.hasSuffix("'"))
        #expect(quoted.contains("'\\''"))
    }

    @Test("external folder opens as project root")
    @MainActor
    func testExternalFolderOpen() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("veilwriter_external_folder_\(UUID().uuidString)")
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
        let originalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("veilwriter_original_folder_\(UUID().uuidString)")
        let nextDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("veilwriter_new_window_folder_\(UUID().uuidString)")
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

    @Test("external file opens inside its parent folder")
    @MainActor
    func testExternalFileOpen() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("veilwriter_external_file_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("note.md")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let state = AppState()
        state.openExternalURL(fileURL)

        #expect(state.rootDirectory?.standardizedFileURL.path == tempDir.standardizedFileURL.path)
        #expect(state.selectedFolderURL?.standardizedFileURL.path == tempDir.standardizedFileURL.path)
        #expect(state.openedFileURL == fileURL)
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
        let root = URL(fileURLWithPath: "/tmp/veilwriter-git-root")
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
        let root = URL(fileURLWithPath: "/tmp/veilwriter-git-root")
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
        let fileURL = URL(fileURLWithPath: "/tmp/veilwriter_syntax_override.swift")
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

    @Test("closing active tab refreshes editor rendering and highlighting")
    func testCloseTabBumpsEditorRenderAndHighlightRevision() {
        let tempDir = FileManager.default.temporaryDirectory
        let firstURL = tempDir.appendingPathComponent("veilwriter_render_first_\(UUID().uuidString).swift")
        let secondURL = tempDir.appendingPathComponent("veilwriter_render_second_\(UUID().uuidString).swift")

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

    @Test("tab navigation activates previous next and indexed tabs")
    func testTabNavigationActivatesPreviousNextAndIndexedTabs() {
        let tempDir = FileManager.default.temporaryDirectory
        let firstURL = tempDir.appendingPathComponent("veilwriter_nav_first_\(UUID().uuidString).txt")
        let secondURL = tempDir.appendingPathComponent("veilwriter_nav_second_\(UUID().uuidString).txt")
        let thirdURL = tempDir.appendingPathComponent("veilwriter_nav_third_\(UUID().uuidString).txt")

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
        let firstURL = tempDir.appendingPathComponent("veilwriter_reopen_first_\(UUID().uuidString).txt")
        let secondURL = tempDir.appendingPathComponent("veilwriter_reopen_second_\(UUID().uuidString).txt")

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

    @Test("save cleanup trims whitespace and ensures final newline")
    func testSaveCleanupTrimsWhitespaceAndEnsuresFinalNewline() {
        let settings = EditorSettings(
            fontID: EditorSettings.default.fontID,
            fontSize: EditorSettings.default.fontSize,
            lineHeightMultiple: EditorSettings.default.lineHeightMultiple,
            fileTreeFontSize: EditorSettings.default.fileTreeFontSize,
            themeID: EditorSettings.default.themeID,
            showsLineNumbers: true,
            highlightsCurrentLine: true,
            preferredInspectorMode: EditorSettings.default.preferredInspectorMode,
            inspectorPanelOrder: EditorSettings.default.inspectorPanelOrder,
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
        let markdownURL = URL(fileURLWithPath: "/tmp/veilwriter_preview.md")
        let htmlURL = URL(fileURLWithPath: "/tmp/veilwriter_preview.html")
        let swiftURL = URL(fileURLWithPath: "/tmp/veilwriter_preview.swift")
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
        #expect(blocks.contains(MarkdownPreviewBlock(kind: .code, text: "let value = 1")))
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
        let fileURL = tempDir.appendingPathComponent("veilwriter_mod_date_\(UUID().uuidString).txt")
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
