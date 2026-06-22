//
//  EditorCoreBehaviorTests.swift
//  WillDeepTests
//
//  Core editor, file detection, appearance, highlighting, and outline tests
//  split out of XeditTests.swift to keep the main integration suite small.
//

import Testing
import Foundation
import AppKit
@testable import WillDeep

@Suite(.serialized)
struct EditorCoreBehaviorTests {
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

    @MainActor
    private func drainMainQueue(
        timeout: TimeInterval = 1.0,
        until predicate: @MainActor () -> Bool = { false }
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
            await Task.yield()
        }
    }

    // MARK: - File Size Detection

    @Test("fileSize returns correct size for a known file")
    func testFileSizeReturnsCorrectSize() throws {
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

        var data = Data(repeating: 0x41, count: 100)
        data[50] = 0x00
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

    // MARK: - Encoding Detection

    @Test("decodeText correctly decodes UTF-8 with multi-byte characters")
    func testDecodeUTF8() {
        let input = "Hello, 世界! 🎉 café"
        let data = input.data(using: .utf8)!
        let result = AppState.decodeText(from: data)
        #expect(result == input)
    }

    @Test("decodeText correctly decodes ISO Latin 1 with accented characters")
    func testDecodeISOLatin1() {
        let bytes: [UInt8] = [0x63, 0x61, 0x66, 0xE9]
        let data = Data(bytes)
        let result = AppState.decodeText(from: data)
        #expect(result == "café")
    }

    @Test("decodeText falls back to error placeholder for undecodable data")
    func testDecodeErrorPlaceholder() {
        let bytes: [UInt8] = [0xFF, 0xFE, 0x00, 0x00, 0x80, 0x81, 0x82]
        let data = Data(bytes)
        let result = AppState.decodeText(from: data)
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
        #expect(settings.interfaceSkinID == EditorInterfaceSkin.system.id)
        #expect(EditorTheme.byID(settings.themeID) != nil)
        #expect(EditorFontChoice.byID(settings.fontID) != nil)
        #expect(EditorInterfaceSkin.byID(settings.interfaceSkinID) != nil)
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
            interfaceSkinID: "missing-skin",
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
        #expect(settings.interfaceSkinID == EditorSettings.default.interfaceSkinID)
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
        #expect(settings.interfaceSkinID == EditorSettings.default.interfaceSkinID)
    }

    @Test("interface skins are registered with localized names and editor themes")
    func testInterfaceSkinsAreRegistered() {
        #expect(EditorInterfaceSkin.allCases.count == 7)

        let ids = Set(EditorInterfaceSkin.allCases.map(\.id))
        #expect(ids.count == EditorInterfaceSkin.allCases.count)

        for skin in EditorInterfaceSkin.allCases {
            #expect(EditorInterfaceSkin.byID(skin.id)?.id == skin.id)
            #expect(EditorTheme.byID(skin.recommendedThemeID) != nil)
            #expect(!L10n.Settings.InterfaceSkin.name(skin).isEmpty)
            #expect(!L10n.Settings.InterfaceSkin.summary(skin).isEmpty)
        }
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

    // MARK: - App Opening

    @Test("command line installer script forwards paths to WillDeep")
    func testCommandLineInstallerScript() {
        let appURL = URL(fileURLWithPath: "/Applications/WillDeep.app")
        let script = CommandLineToolInstaller.scriptContent(appBundleURL: appURL)

        #expect(script.hasPrefix("#!/bin/zsh"))
        #expect(script.contains("encode_path()"))
        #expect(script.contains("willdeep://open?path=$encoded_path"))
        #expect(script.contains("/usr/bin/open -a \"$app_path\" \"$target\""))
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

        #expect(state.rootDirectory == nil)
        #expect(state.selectedFolderURL == nil)
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

    // MARK: - Highlighting and Structure

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
            (".kt", .kotlin),
            (".scala", .scala),
            (".dart", .dart),
            (".go", .go),
            (".html", .html),
            (".css", .css),
            (".vue", .vue),
            (".svelte", .svelte),
            (".astro", .astro),
            (".swift", .swift),
            (".bash", .shell),
            (".ps1", .powershell),
            (".yaml", .yaml),
            (".toml", .toml),
            (".xml", .xml),
            (".sql", .sql),
            (".ini", .ini),
            (".rs", .rust),
            (".c", .c),
            (".cpp", .cpp),
            (".m", .objectiveC),
            (".mm", .objectiveCpp),
            (".cs", .csharp),
            (".fs", .fsharp),
            (".vb", .visualBasic),
            (".lua", .lua),
            (".pl", .perl),
            (".r", .r),
            (".jl", .julia),
            (".ex", .elixir),
            (".erl", .erlang),
            (".hs", .haskell),
            (".clj", .clojure),
            (".tf", .terraform),
            (".graphql", .graphql),
            (".proto", .protobuf),
            (".cmake", .cmake),
            (".nix", .nix),
            (".sol", .solidity),
            (".zig", .zig),
            (".nim", .nim),
            (".d", .dlang),
            (".mlx", .matlab),
            (".f90", .fortran),
            (".pas", .pascal),
            (".asm", .assembly),
        ]

        for (ext, language) in expected {
            #expect(Language.fromExtension(ext) == language)
        }

        let tempDir = URL(fileURLWithPath: "/tmp")
        #expect(Language.fromURL(tempDir.appendingPathComponent("Dockerfile")) == .dockerfile)
        #expect(Language.fromURL(tempDir.appendingPathComponent("Makefile")) == .makefile)
        #expect(Language.fromURL(tempDir.appendingPathComponent("CMakeLists.txt")) == .cmake)
        #expect(Language.fromURL(tempDir.appendingPathComponent("nginx.conf")) == .nginx)
        #expect(Language.fromURL(tempDir.appendingPathComponent(".htaccess")) == .apache)
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
            (.kotlin, "data class Greeter(val name: String)\n", "data"),
            (.scala, "case class Greeter(name: String)\n", "case"),
            (.dart, "class Greeter { final name = true; }\n", "class"),
            (.json, "{\"enabled\": true, \"count\": 3}", "enabled"),
            (.javascript, "const value = true;\n", "const"),
            (.typescript, "interface User { name: string }\n", "interface"),
            (.go, "package main\nfunc main() { return }\n", "package"),
            (.html, "<section class=\"hero\"></section>\n", "section"),
            (.css, ".hero { color: #fff; }\n", "color"),
            (.vue, "<template><section>{{ title }}</section></template>\n", "template"),
            (.svelte, "<script>export let title;</script>\n", "script"),
            (.astro, "---\nconst title = 'x'\n---\n<section />\n", "const"),
            (.swift, "struct Greeter { let value = true }\n", "struct"),
            (.shell, "#!/usr/bin/env bash\nif [[ -f \"$HOME/.zshrc\" ]]; then echo ok; fi\n", "if"),
            (.powershell, "function Invoke-Thing { param($Name) return $Name }\n", "function"),
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
            (.objectiveC, "@interface Writer : NSObject\n@end\n", "@interface"),
            (.objectiveCpp, "@implementation Writer\n@end\n", "@implementation"),
            (.csharp, "public class Writer { string Name; }\n", "public"),
            (.fsharp, "module Writer\nlet save value = value\n", "module"),
            (.visualBasic, "Public Class Writer\nEnd Class\n", "Public"),
            (.lua, "local function save() return true end\n", "local"),
            (.perl, "package Writer;\nsub save { return 1; }\n", "package"),
            (.r, "save <- function(value) { return(TRUE) }\n", "function"),
            (.julia, "module Writer\nfunction save() end\nend\n", "module"),
            (.elixir, "defmodule Writer do\n  def save, do: true\nend\n", "defmodule"),
            (.erlang, "-module(writer).\nreceive after 0 -> ok end.\n", "receive"),
            (.haskell, "module Writer where\ndata Value = Value\n", "module"),
            (.clojure, "(defn save [] true)\n", "defn"),
            (.terraform, "resource \"aws_s3_bucket\" \"main\" { versioning = true }\n", "resource"),
            (.graphql, "type User { id: ID! }\n", "type"),
            (.protobuf, "message User { string name = 1; }\n", "message"),
            (.cmake, "project(Writer)\nadd_executable(writer main.cc)\n", "project"),
            (.nginx, "server { listen 80; }\n", "server"),
            (.apache, "<VirtualHost *:80>\nServerName example.test\n</VirtualHost>\n", "VirtualHost"),
            (.nix, "let pkg = null; in pkg\n", "let"),
            (.solidity, "contract Writer { function save() public {} }\n", "contract"),
            (.zig, "pub fn save() void {}\n", "pub"),
            (.nim, "proc save(): bool = true\n", "proc"),
            (.dlang, "module writer;\nclass Writer {}\n", "module"),
            (.matlab, "function value = save()\nend\n", "function"),
            (.fortran, "program writer\nend program writer\n", "program"),
            (.pascal, "program Writer;\nbegin end.\n", "program"),
            (.assembly, ".globl _main\n_main:\n", ".globl"),
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

    @Test("definition resolver finds Go Java TypeScript and config symbols")
    func testDefinitionResolverFindsProjectSymbols() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_definition_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let goFile = root.appendingPathComponent("service.go")
        try """
        package demo

        type Worker struct {}

        func (w Worker) Run() {}
        """.write(to: goFile, atomically: true, encoding: .utf8)

        let javaFile = root.appendingPathComponent("WorkerService.java")
        try """
        package demo;

        public class WorkerService {
            public void start() {}
        }
        """.write(to: javaFile, atomically: true, encoding: .utf8)

        let tsFile = root.appendingPathComponent("client.ts")
        try """
        export interface ClientOptions {}
        export function connect() {}
        """.write(to: tsFile, atomically: true, encoding: .utf8)

        let appConfig = root.appendingPathComponent("application.yml")
        try """
        spring:
          datasource:
            url: jdbc:postgresql://localhost/app
        """.write(to: appConfig, atomically: true, encoding: .utf8)

        let envFile = root.appendingPathComponent(".env")
        try """
        API_TOKEN=secret
        """.write(to: envFile, atomically: true, encoding: .utf8)

        #expect(EditorDefinitionResolver.definition(for: "Worker", from: goFile, rootDirectory: root)?.url.standardizedFileURL == goFile.standardizedFileURL)
        #expect(EditorDefinitionResolver.definition(for: "Run", from: goFile, rootDirectory: root)?.line == 4)
        #expect(EditorDefinitionResolver.definition(for: "WorkerService", from: javaFile, rootDirectory: root)?.url.standardizedFileURL == javaFile.standardizedFileURL)
        #expect(EditorDefinitionResolver.definition(for: "connect", from: tsFile, rootDirectory: root)?.url.standardizedFileURL == tsFile.standardizedFileURL)
        #expect(EditorDefinitionResolver.definition(for: "spring.datasource.url", from: javaFile, rootDirectory: root)?.url.standardizedFileURL == appConfig.standardizedFileURL)
        #expect(EditorDefinitionResolver.definition(for: "API_TOKEN", from: tsFile, rootDirectory: root)?.url.standardizedFileURL == envFile.standardizedFileURL)
    }

    @Test("editor terminal parses env and discovers package plus Go commands")
    func testEditorTerminalProjectCommandDiscovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_terminal_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        {
          "scripts": {
            "build": "vite build",
            "dev": "vite --host 127.0.0.1",
            "lint": "eslint ."
          },
          "devDependencies": {
            "vite": "^6.0.0"
          }
        }
        """.write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("yarn.lock"), atomically: true, encoding: .utf8)
        try """
        package main

        func main() {}
        """.write(to: root.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)

        let cmdServer = root.appendingPathComponent("cmd/server", isDirectory: true)
        try FileManager.default.createDirectory(at: cmdServer, withIntermediateDirectories: true)
        try """
        package main

        func main() {}
        """.write(to: cmdServer.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)

        let env = EditorTerminalEnvironmentParser.parse("""
        API_TOKEN=abc123
        QUOTED="hello world"
        # ignored
        EMPTY=
        """)
        #expect(env["API_TOKEN"] == "abc123")
        #expect(env["QUOTED"] == "hello world")
        #expect(env["EMPTY"] == "")

        let commands = EditorProjectCommandResolver.commands(rootDirectory: root, openedFileURL: nil)
        #expect(commands.contains { $0.title == "package.json: dev" && $0.command == "yarn run dev" })
        #expect(commands.contains { $0.title == "package.json: build" && $0.command == "yarn run build" })
        #expect(commands.contains { $0.title == "Go run main.go" && $0.command == "go run main.go" })
        #expect(commands.contains { $0.title == "Go run ./cmd/server" && $0.command == "go run ./cmd/server" })
    }
}
