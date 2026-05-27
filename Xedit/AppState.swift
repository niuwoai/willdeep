//
//  AppState.swift
//  VeilWriter
//
//  Created by rocky on 2026/5/27.
//

import Combine
import Foundation
import SwiftUI
import AppKit

/// Central observable state hub for the VeilWriter app.
/// Manages the currently opened file URL, its text content, the dirty (edited) flag,
/// and the root directory for the sidebar file tree.
final class AppState: ObservableObject {
    @Published var openedFileURL: URL?
    @Published var fileContent: String {
        didSet {
            updateActiveTab { tab in
                tab.content = fileContent
            }
        }
    }
    @Published var isEdited: Bool {
        didSet {
            updateActiveTab { tab in
                tab.isEdited = isEdited
            }
        }
    }
    @Published var rootDirectory: URL?
    @Published var tabs: [EditorTab]
    @Published var activeTabID: EditorTab.ID?
    @Published var editorSettings: EditorSettings {
        didSet {
            EditorSettingsStore.save(editorSettings)
        }
    }

    /// Internal flag to suppress re-entrant `onChange` processing when a URL
    /// change is a programmatic revert (e.g. binary file rejected, user cancelled).
    var suppressURLChangeProcessing = false
    private var isApplyingTabSnapshot = false

    init(
        openedFileURL: URL? = nil,
        fileContent: String = "",
        isEdited: Bool = false,
        rootDirectory: URL? = nil,
        editorSettings: EditorSettings = EditorSettingsStore.load()
    ) {
        self.openedFileURL = openedFileURL
        self.fileContent = fileContent
        self.isEdited = isEdited
        self.rootDirectory = rootDirectory
        if let openedFileURL {
            let tab = EditorTab(url: openedFileURL, content: fileContent, isEdited: isEdited)
            self.tabs = [tab]
            self.activeTabID = tab.id
        } else {
            self.tabs = []
            self.activeTabID = nil
        }
        self.editorSettings = editorSettings.normalized()
    }

    var activeTab: EditorTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    func beginOpeningTab(for url: URL) {
        if activateTab(for: url) {
            return
        }

        let tab = EditorTab(url: url)
        tabs.append(tab)
        activeTabID = tab.id
        applySnapshot(from: tab, suppressURLChange: true)
    }

    @discardableResult
    func activateTab(id: EditorTab.ID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }) else {
            return false
        }

        activeTabID = id
        applySnapshot(from: tab, suppressURLChange: true)
        return true
    }

    @discardableResult
    func activateTab(for url: URL) -> Bool {
        guard let tab = tabs.first(where: { $0.url == url }) else {
            return false
        }
        return activateTab(id: tab.id)
    }

    func closeTab(id: EditorTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        if tabs[index].isEdited {
            let tab = tabs[index]
            let alert = NSAlert()
            alert.messageText = "Unsaved Changes"
            alert.informativeText = "Do you want to save the changes made to \"\(tab.title)\"?"
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                do {
                    try tab.content.write(to: tab.url, atomically: true, encoding: .utf8)
                    tabs[index].isEdited = false
                } catch {
                    let saveAlert = NSAlert()
                    saveAlert.messageText = "Save Failed"
                    saveAlert.informativeText = "Could not save \"\(tab.title)\": \(error.localizedDescription)"
                    saveAlert.alertStyle = .critical
                    saveAlert.addButton(withTitle: "OK")
                    saveAlert.runModal()
                    return
                }
            case .alertThirdButtonReturn:
                return
            default:
                break
            }
        }

        let wasActive = tabs[index].id == activeTabID
        tabs.remove(at: index)

        guard wasActive else { return }

        if tabs.isEmpty {
            activeTabID = nil
            isApplyingTabSnapshot = true
            suppressURLChangeProcessing = true
            openedFileURL = nil
            fileContent = ""
            isEdited = false
            isApplyingTabSnapshot = false
            updateWindowTitle(url: nil, isEdited: false)
            return
        }

        let nextIndex = min(index, tabs.count - 1)
        let nextTab = tabs[nextIndex]
        activeTabID = nextTab.id
        applySnapshot(from: nextTab, suppressURLChange: true)
    }

    private func applySnapshot(from tab: EditorTab, suppressURLChange: Bool) {
        isApplyingTabSnapshot = true
        if suppressURLChange, openedFileURL != tab.url {
            suppressURLChangeProcessing = true
        }
        openedFileURL = tab.url
        fileContent = tab.content
        isEdited = tab.isEdited
        isApplyingTabSnapshot = false
        updateWindowTitle(url: tab.url, isEdited: tab.isEdited)
    }

    private func updateActiveTab(_ mutation: (inout EditorTab) -> Void) {
        guard !isApplyingTabSnapshot,
              let activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID }) else {
            return
        }
        mutation(&tabs[index])
    }

    private func updateActiveTabAfterURLChange(to url: URL) {
        guard let activeTabID,
              let index = tabs.firstIndex(where: { $0.id == activeTabID }) else {
            return
        }
        tabs[index].url = url
        tabs[index].content = fileContent
        tabs[index].isEdited = isEdited
    }

    private func updateWindowTitle(url: URL?, isEdited: Bool) {
        guard let window = NSApplication.shared.keyWindow else { return }
        window.title = url?.lastPathComponent ?? ""
        window.isDocumentEdited = isEdited
    }

    // MARK: - Folder Opening

    /// Presents an `NSOpenPanel` configured for directory selection and assigns
    /// the chosen URL to `rootDirectory`.
    func openFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder"
        panel.message = "Select a directory to browse in the sidebar."
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.rootDirectory = url
        }
    }

    // MARK: - File Opening

    /// Presents an `NSOpenPanel` configured for file selection. The selected file
    /// is assigned to `openedFileURL`; the view layer handles unsaved prompts,
    /// binary checks, size confirmation, and loading.
    func openFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a File"
        panel.message = "Select a text file to open in VeilWriter."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openedFileURL = url
            self?.rootDirectory = url.deletingLastPathComponent()
        }
    }

    // MARK: - File Size

    /// Maximum recommended file size for the editor (1 MB).
    /// Files larger than this trigger a user-confirmation dialog before loading.
    nonisolated static let maxFileSize: Int = 1_048_576

    enum FileLoadError: Error, Equatable {
        case fileTooLarge(Int64)
        case unreadable
    }

    /// Returns the file size (in bytes) of the resource at `url`, or `nil` if
    /// the attributes cannot be read.
    nonisolated static func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return nil
        }
        return size
    }

    nonisolated static func shouldRequireLargeFileConfirmation(at url: URL) -> Bool {
        guard let size = fileSize(at: url) else { return false }
        return size > Int64(maxFileSize)
    }

    // MARK: - Binary Detection

    /// Reads the first 8192 bytes of the file at `url` and returns `true` if
    /// any null byte (`0x00`) is found, indicating a binary (non-text) file.
    nonisolated static func isBinaryFile(at url: URL) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            // If we can't open the file at all, treat as non-binary —
            // the read attempt in loadFile will surface the actual error.
            return false
        }
        defer { try? handle.close() }
        let chunk = handle.readData(ofLength: 8192)
        return chunk.contains(0)
    }

    // MARK: - File Loading

    /// Reads the file at `url` on a background queue, applies encoding detection
    /// (UTF-8 → NSString detection → ISO Latin 1 fallback), and updates
    /// `fileContent`, `isEdited`, and the window title on the main thread.
    ///
    /// If reading fails, the selection is reverted to `fallbackURL` (or `nil`).
    ///
    /// Caller is responsible for binary detection and unsaved-change dialogs
    /// before invoking this method. Size checks are enforced here as a backstop.
    func loadFile(from url: URL, fallbackURL: URL? = nil, allowLargeFile: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<String, FileLoadError>

            do {
                let data = try Self.readFileData(from: url, allowLargeFile: allowLargeFile)
                result = .success(Self.decodeText(from: data))
            } catch let error as FileLoadError {
                result = .failure(error)
            } catch {
                result = .failure(.unreadable)
            }

            DispatchQueue.main.async { [weak self] in
                self?.applyFileLoadResult(result, for: url, fallbackURL: fallbackURL)
            }
        }
    }

    private func applyFileLoadResult(_ result: Result<String, FileLoadError>, for url: URL, fallbackURL: URL?) {
        switch result {
        case .success(let content):
            applyLoadedContent(content, for: url)
        case .failure(.fileTooLarge(let size)):
            let alert = NSAlert()
            alert.messageText = "File Too Large"
            let limit = ByteCountFormatter.string(
                fromByteCount: Int64(Self.maxFileSize),
                countStyle: .file
            )
            let actualSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            alert.informativeText = "\"\(url.lastPathComponent)\" is \(actualSize); files over \(limit) require confirmation before loading."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            revertFailedLoad(for: url, fallbackURL: fallbackURL)
        case .failure(.unreadable):
            let alert = NSAlert()
            alert.messageText = "Cannot Read File"
            alert.informativeText = "The file \"\(url.lastPathComponent)\" could not be read."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            revertFailedLoad(for: url, fallbackURL: fallbackURL)
        }
    }

    private func applyLoadedContent(_ content: String, for url: URL) {
        if let index = tabs.firstIndex(where: { $0.url == url }) {
            tabs[index].content = content
            tabs[index].isEdited = false
        }

        guard openedFileURL == url else {
            return
        }

        isApplyingTabSnapshot = true
        fileContent = content
        isEdited = false
        isApplyingTabSnapshot = false
        updateWindowTitle(url: url, isEdited: false)
    }

    private func revertFailedLoad(for url: URL, fallbackURL: URL?) {
        tabs.removeAll { $0.url == url && $0.content.isEmpty && !$0.isEdited }

        guard openedFileURL == url else {
            return
        }

        suppressURLChangeProcessing = true
        openedFileURL = fallbackURL
        if let fallbackURL, let fallbackTab = tabs.first(where: { $0.url == fallbackURL }) {
            activeTabID = fallbackTab.id
            applySnapshot(from: fallbackTab, suppressURLChange: false)
        } else {
            activeTabID = nil
            isApplyingTabSnapshot = true
            fileContent = ""
            isEdited = false
            isApplyingTabSnapshot = false
            updateWindowTitle(url: nil, isEdited: false)
        }
    }

    nonisolated static func readFileData(from url: URL, allowLargeFile: Bool = false) throws -> Data {
        if !allowLargeFile, let size = fileSize(at: url), size > Int64(maxFileSize) {
            throw FileLoadError.fileTooLarge(size)
        }

        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw FileLoadError.unreadable
        }
    }

    /// Runs the encoding detection pipeline on raw file data.
    ///
    /// 1. Try UTF-8.
    /// 2. Ask NSString to detect the encoding.
    /// 3. Fall back to ISO Latin 1.
    /// 4. Ultimate fallback: error placeholder.
    nonisolated static func decodeText(from data: Data) -> String {
        // 1. UTF-8 (covers the vast majority of modern text files).
        if let str = String(data: data, encoding: .utf8) {
            return str
        }

        // 2. NSString encoding detection.
        var convertedString: NSString?
        let rawEncoding = NSString.stringEncoding(
            for: data,
            encodingOptions: nil,
            convertedString: &convertedString,
            usedLossyConversion: nil
        )
        if rawEncoding != 0 {
            if let converted = convertedString {
                return converted as String
            }
            if let str = String(data: data, encoding: String.Encoding(rawValue: rawEncoding)) {
                return str
            }
        }

        // 3. ISO Latin 1 (covers many Western European encodings).
        if let str = String(data: data, encoding: .isoLatin1) {
            return str
        }

        // 4. Unable to decode — return a placeholder so the user sees something.
        return "Error: Unable to decode file contents."
    }

    // MARK: - File Saving

    /// Writes `fileContent` back to `openedFileURL` using UTF-8 encoding.
    /// On success clears the dirty flag and window indicator and returns `true`.
    /// On failure optionally presents an alert describing the error and returns `false`.
    @discardableResult
    func saveCurrentFile() -> Bool {
        guard let url = openedFileURL else {
            return saveCurrentFileAs()
        }
        return writeCurrentFile(to: url, updateOpenedURL: false)
    }

    /// Presents an `NSSavePanel` and writes `fileContent` to the chosen URL.
    /// On success updates the current file URL and clears dirty state.
    @discardableResult
    func saveCurrentFileAs() -> Bool {
        let panel = NSSavePanel()
        panel.title = "Save As"
        panel.message = "Choose where to save this file."
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = openedFileURL?.lastPathComponent ?? "Untitled.txt"

        guard panel.runModal() == .OK, let url = panel.url else {
            return false
        }

        return writeCurrentFile(to: url, updateOpenedURL: true)
    }

    @discardableResult
    func writeCurrentFile(to url: URL, updateOpenedURL: Bool, showsAlert: Bool = true) -> Bool {
        do {
            try fileContent.write(to: url, atomically: true, encoding: .utf8)
            if updateOpenedURL {
                suppressURLChangeProcessing = true
                openedFileURL = url
                rootDirectory = url.deletingLastPathComponent()
                updateActiveTabAfterURLChange(to: url)
            }
            isEdited = false
            updateWindowTitle(url: url, isEdited: false)
            return true
        } catch {
            guard showsAlert else {
                return false
            }

            let alert = NSAlert()
            alert.messageText = "Save Failed"
            alert.informativeText = "Could not save \"\(url.lastPathComponent)\": \(error.localizedDescription)"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
    }
}
