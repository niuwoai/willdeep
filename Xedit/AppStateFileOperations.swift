//
//  AppStateFileOperations.swift
//  VeilWriter
//
//  Extracted from AppState.swift in v1.52.1-rc42 (stage-3 code-health
//  pass). Houses every file/folder-I/O entry point on AppState:
//
//    - Folder picker / file picker NSOpenPanel flows
//    - Binary detection, file-size guards
//    - Async loadFile pipeline + error UI
//    - Save / Save As + writeCurrentFile
//    - Session restore / persistSession
//    - setRootDirectory, security-scoped bookmark helpers,
//      terminalTargetURL, relativePath, promptForName,
//      showFileOperationError
//
//  The methods live on AppState via extension — call sites in
//  ContentView/sidebar/menus still write appState.openFile(),
//  appState.saveCurrentFile() exactly as before. A handful of private
//  stored fields had to be downgraded to internal so this file can
//  touch them (isApplyingTabSnapshot, knownModificationDates,
//  securityScopedAccessURLs); still invisible outside the Xedit target.
//

import AppKit
import Foundation

extension AppState {
    // MARK: - Folder Opening

    /// Presents an `NSOpenPanel` configured for directory selection and assigns
    /// the chosen URL to `rootDirectory`.
    func openFolder(openInNewWindow: ((URL) -> Void)? = nil) {
        let panel = Self.folderOpenPanel()

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openFolderURL(url, openInNewWindow: openInNewWindow)
        }
    }

    /// Composer-side entry point: open a folder picker AND, on success,
    /// immediately spin up a fresh Agent session anchored to that
    /// workspace path. Use this from the Composer's WorkspacePickerPill
    /// "Choose folder…" entry and the sidebar's "Workspaces +" button
    /// so the new directory shows up as its own workspace group right
    /// away (rather than the user picking a folder and then having to
    /// manually start a new chat to make the group appear).
    ///
    /// If the user already has the picked folder open and an active
    /// session sits in that workspace, we just switch root without
    /// creating a duplicate empty session.
    func openFolderAndStartAgentSession() {
        let panel = Self.folderOpenPanel()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let self else { return }
            let standardized = url.standardizedFileURL
            // Already rooted here AND already has a non-archived session
            // in this workspace → switching root would be a no-op and
            // creating another empty session is annoying noise.
            let alreadyHere = self.rootDirectory?.standardizedFileURL.path == standardized.path
            let hasSessionHere = self.agentSessions.contains { session in
                guard let path = session.workspaceRootPath, !path.isEmpty else { return false }
                return URL(fileURLWithPath: path).standardizedFileURL.path == standardized.path
                    && !session.isArchived
            }
            if alreadyHere && hasSessionHere,
               let runtime = self.activeRuntime,
               runtime.workspaceRootPath == standardized.path {
                self.openFolderURL(url)
                return
            }
            _ = self.moveActiveAgentSessionToWorkspace(at: standardized.path)
        }
    }

    static func folderOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder"
        panel.message = "Select a directory to browse in the sidebar."
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return panel
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
            self?.registerRecentFile(url)
            self?.registerRecentFolder(url.deletingLastPathComponent())
            // Same rationale as openExternalURL: opening a file no longer
            // promotes its parent to rootDirectory. Use Open Folder… (⇧⌘O)
            // to load the FileTree.
            self?.openedFileURL = url
            self?.persistSession()
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

    nonisolated static func modificationDate(at url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else {
            return nil
        }
        return date
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

    nonisolated static func isImageFile(at url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "ico", "icns":
            return true
        default:
            return false
        }
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

    func applyFileLoadResult(_ result: Result<String, FileLoadError>, for url: URL, fallbackURL: URL?) {
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

    func applyLoadedContent(_ content: String, for url: URL) {
        if let index = tabs.firstIndex(where: { $0.url == url }) {
            tabs[index].content = content
            tabs[index].savedContent = content
            tabs[index].isEdited = false
        }

        guard openedFileURL == url else {
            return
        }

        isApplyingTabSnapshot = true
        fileContent = content
        isEdited = false
        isApplyingTabSnapshot = false
        bumpEditorRenderRevision()
        bumpEditorHighlightRevision()
        updateWindowTitle(url: url, isEdited: false)
        knownModificationDates[url] = Self.modificationDate(at: url)
        hasExternalFileChanges = false
        registerRecentFile(url)
        registerRecentFolder(url.deletingLastPathComponent())
        persistSession()
    }

    func loadSplitFile(from url: URL) {
        guard !Self.isBinaryFile(at: url),
              let data = try? Self.readFileData(from: url),
              let content = String(data: data, encoding: .utf8) ?? Optional(Self.decodeText(from: data)) else {
            return
        }
        splitFileURL = url
        splitFileContent = content
        isSplitEditorVisible = true
        registerRecentFile(url)
    }

    func revertFailedLoad(for url: URL, fallbackURL: URL?) {
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
            bumpEditorRenderRevision()
            bumpEditorHighlightRevision()
            updateWindowTitle(url: nil, isEdited: false)
            persistSession()
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
        if activeTab?.isUntitled == true {
            return saveCurrentFileAs()
        }

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
        panel.nameFieldStringValue = activeTab?.isUntitled == true ? "Untitled.txt" : (openedFileURL?.lastPathComponent ?? "Untitled.txt")

        guard panel.runModal() == .OK, let url = panel.url else {
            return false
        }

        return writeCurrentFile(to: url, updateOpenedURL: true)
    }

    @discardableResult
    func writeCurrentFile(to url: URL, updateOpenedURL: Bool, showsAlert: Bool = true) -> Bool {
        do {
            let contentToWrite = Self.contentForSave(fileContent, settings: editorSettings)
            if contentToWrite != fileContent {
                fileContent = contentToWrite
            }
            try contentToWrite.write(to: url, atomically: true, encoding: .utf8)
            if updateOpenedURL {
                suppressURLChangeProcessing = true
                openedFileURL = url
                // Save As no longer hijacks the workspace root. If a folder
                // was explicitly opened, it stays; otherwise no FileTree
                // appears for the saved file's parent.
                updateActiveTabAfterURLChange(to: url)
            }
            updateActiveTab { tab in
                tab.savedContent = contentToWrite
            }
            isEdited = false
            updateWindowTitle(url: url, isEdited: false)
            knownModificationDates[url] = Self.modificationDate(at: url)
            hasExternalFileChanges = false
            registerRecentFile(url)
            registerRecentFolder(url.deletingLastPathComponent())
            refreshGitStatus()
            persistSession()
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

    // MARK: - Session Restore

    func restoreSessionIfAvailable() {
        guard tabs.isEmpty, openedFileURL == nil, let session = SessionStore.load() else {
            return
        }

        if let rootURL = resolvedRootDirectory(from: session) {
            setRootDirectory(rootURL)
            registerRecentFolder(rootURL)
        }

        var restoredTabs: [EditorTab] = []
        for path in session.tabPaths {
            let url = URL(fileURLWithPath: path)
            guard !Self.isBinaryFile(at: url),
                  let data = try? Self.readFileData(from: url),
                  let content = String(data: data, encoding: .utf8) ?? Optional(Self.decodeText(from: data)) else {
                continue
            }
            restoredTabs.append(EditorTab(url: url, content: content, savedContent: content, isEdited: false))
        }

        guard !restoredTabs.isEmpty else { return }

        tabs = restoredTabs
        let activeURL = session.activeTabPath.map { URL(fileURLWithPath: $0) }
        let activeTab = activeURL.flatMap { url in restoredTabs.first { $0.url == url } } ?? restoredTabs[0]
        activeTabID = activeTab.id
        applySnapshot(from: activeTab, suppressURLChange: true)
    }

    func persistSession() {
        let restorableTabs = tabs.filter { !$0.isUntitled }
        let session = EditorSessionSnapshot(
            rootDirectoryPath: rootDirectory?.path,
            rootDirectoryBookmarkData: rootDirectory.flatMap { bookmarkData(for: $0) },
            tabPaths: restorableTabs.map(\.url.path),
            activeTabPath: activeTab?.isUntitled == true ? nil : activeTab?.url.path
        )
        SessionStore.save(session)
    }

    func setRootDirectory(_ url: URL) {
        activateSecurityScope(for: url)
        rootDirectory = url
        selectedFolderURL = url
        // Security scope is active above, so the background verify scan can read
        // the project; the cache itself lives in Caches (outside the scope).
        refreshProjectFileList()
    }

    @discardableResult
    func activateSecurityScope(for url: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        guard !securityScopedAccessURLs.contains(standardizedURL) else {
            return true
        }

        guard standardizedURL.startAccessingSecurityScopedResource() else {
            return false
        }

        securityScopedAccessURLs.insert(standardizedURL)
        return true
    }

    func bookmarkData(for url: URL) -> Data? {
        activateSecurityScope(for: url)
        return try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolvedRootDirectory(from session: EditorSessionSnapshot) -> URL? {
        if let bookmarkData = session.rootDirectoryBookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                activateSecurityScope(for: url)
                return url
            }
        }

        guard let rootPath = session.rootDirectoryPath else { return nil }
        return URL(fileURLWithPath: rootPath)
    }

    func terminalTargetURL(for url: URL?) -> URL {
        let candidate = url ?? selectedFolderURL ?? openedFileURL ?? rootDirectory
        guard let candidate else {
            return FileManager.default.homeDirectoryForCurrentUser
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return candidate
        }

        return candidate.deletingLastPathComponent()
    }

    func relativePath(for url: URL) -> String {
        guard let rootDirectory else { return url.path }
        let rootPath = rootDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else {
            return path
        }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func promptForName(
        title: String,
        message: String,
        placeholder: String,
        onConfirm: @escaping (String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = placeholder
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            showFileOperationError("Enter a valid name.")
            return
        }

        onConfirm(name)
    }

    func showFileOperationError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "File Operation Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

}
