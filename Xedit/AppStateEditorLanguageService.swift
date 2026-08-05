//
//  AppStateEditorLanguageService.swift
//  WillDeep
//
//  Bridges editor file lifecycle events into the LSP language service.
//

import Foundation
import AppKit

private enum EditorWorkspaceEditApplicationError: Error {
    case noChanges
    case invalidEdit(URL)
    case unsafeFile(URL)
    case unsavedOpenTab(URL)
}

extension AppState {
    var editorDiagnosticSummary: (errors: Int, warnings: Int, total: Int) {
        let errors = editorLanguageServiceDiagnosticIssues.filter { $0.severity == .error }.count
        let warnings = editorLanguageServiceDiagnosticIssues.filter { $0.severity == .warning }.count
        return (errors, warnings, editorLanguageServiceDiagnosticIssues.count)
    }

    func navigateToFirstDiagnostic() {
        guard let issue = editorLanguageServiceDiagnosticIssues
            .sorted(by: { $0.range.location < $1.range.location })
            .first else {
            return
        }
        navigateEditor(toLine: issue.line)
    }

    func dismissEditorHoverInfo() {
        editorHoverInfo = nil
    }

    func dismissEditorCompletionPanel() {
        editorCompletionPanel = nil
    }

    func dismissEditorSignatureHelpPanel() {
        editorSignatureHelpPanel = nil
    }

    func dismissEditorCodeActionPanel() {
        editorCodeActionPanel = nil
    }

    func dismissEditorReferencesPanel() {
        editorReferencesPanel = nil
    }

    func dismissEditorCallHierarchyPanel() {
        editorCallHierarchyPanel = nil
    }

    func refreshEditorDocumentHighlights(characterOffset: Int, selectedLength: Int) {
        guard selectedLength == 0,
              let fileURL = openedFileURL,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            editorDocumentHighlightRevision += 1
            editorDocumentHighlightRequestKey = nil
            editorLanguageServiceDocumentHighlightsURI = nil
            editorDocumentHighlightSpans = []
            return
        }

        let text = fileContent
        let nsText = text as NSString
        let safeOffset = min(max(0, characterOffset), nsText.length)
        let language = effectiveLanguage
        let root = rootDirectory
        let contentRevision = activeTab?.contentRevision ?? 0
        let requestKey = "\(fileURL.absoluteString)#\(safeOffset)#\(contentRevision)"
        guard requestKey != editorDocumentHighlightRequestKey else { return }

        editorDocumentHighlightRevision += 1
        let revision = editorDocumentHighlightRevision
        editorDocumentHighlightRequestKey = requestKey

        Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
                let shouldContinue = await MainActor.run {
                    self.editorDocumentHighlightRevision == revision
                        && self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL
                        && self.effectiveLanguage == language
                        && self.fileContent == text
                }
                guard shouldContinue else { return }

                let spans = try await self.editorLanguageServiceManager.documentHighlights(
                    fileURL: fileURL,
                    language: language,
                    rootDirectory: root,
                    text: text,
                    characterOffset: safeOffset
                )
                await MainActor.run {
                    guard self.editorDocumentHighlightRevision == revision,
                          self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    self.editorLanguageServiceDocumentHighlightsURI = fileURL.absoluteString
                    self.editorDocumentHighlightSpans = spans
                }
            } catch {
                await MainActor.run {
                    guard self.editorDocumentHighlightRevision == revision,
                          self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    self.editorLanguageServiceDocumentHighlightsURI = nil
                    self.editorDocumentHighlightSpans = []
                }
            }
        }
    }

    func showEditorReferences(request: EditorReferenceRequest) {
        guard let fileURL = openedFileURL,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            return
        }

        let language = effectiveLanguage
        let root = rootDirectory
        let text = fileContent
        editorReferencesPanel = EditorReferencesPanelState(
            request: request,
            items: [],
            isLoading: true,
            message: L10n.EditorReferences.loading
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let locations = try await self.editorLanguageServiceManager.references(
                    fileURL: fileURL,
                    language: language,
                    rootDirectory: root,
                    text: text,
                    characterOffset: request.characterOffset
                )
                let items = locations.compactMap { location in
                    EditorReferenceItem(location: location, previewText: self.previewLine(for: location, currentURL: fileURL, currentText: text))
                }
                .sorted { lhs, rhs in
                    if lhs.fileURL.path == rhs.fileURL.path {
                        if lhs.line == rhs.line {
                            return lhs.column < rhs.column
                        }
                        return lhs.line < rhs.line
                    }
                    return lhs.fileURL.path.localizedCaseInsensitiveCompare(rhs.fileURL.path) == .orderedAscending
                }

                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    self.editorReferencesPanel = EditorReferencesPanelState(
                        request: request,
                        items: items,
                        message: items.isEmpty ? L10n.EditorReferences.noItems : nil
                    )
                }
            } catch {
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language else {
                        return
                    }
                    self.editorReferencesPanel = EditorReferencesPanelState(
                        request: request,
                        items: [],
                        message: L10n.EditorReferences.unavailable
                    )
                }
            }
        }
    }

    func navigateToEditorReference(_ item: EditorReferenceItem) {
        editorReferencesPanel = nil
        Task { [weak self] in
            await self?.navigateToLanguageServerLocation(item.location)
        }
    }

    func showEditorCallHierarchy(request: EditorCallHierarchyRequest) {
        guard let fileURL = openedFileURL,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            return
        }

        let language = effectiveLanguage
        let root = rootDirectory
        let text = fileContent
        editorCallHierarchyPanel = EditorCallHierarchyPanelState(
            request: request,
            incoming: [],
            outgoing: [],
            isLoading: true,
            message: L10n.EditorCallHierarchy.loading
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.editorLanguageServiceManager.callHierarchy(
                    fileURL: fileURL,
                    language: language,
                    rootDirectory: root,
                    text: text,
                    characterOffset: request.characterOffset
                )
                let incoming = response.incoming.compactMap { call in
                    EditorCallHierarchyEntry(
                        direction: .incoming,
                        item: call.from,
                        preview: self.previewLine(for: call.from, currentURL: fileURL, currentText: text) ?? ""
                    )
                }
                .sorted(by: Self.sortCallHierarchyEntries)
                let outgoing = response.outgoing.compactMap { call in
                    EditorCallHierarchyEntry(
                        direction: .outgoing,
                        item: call.to,
                        preview: self.previewLine(for: call.to, currentURL: fileURL, currentText: text) ?? ""
                    )
                }
                .sorted(by: Self.sortCallHierarchyEntries)

                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    let hasItems = !incoming.isEmpty || !outgoing.isEmpty
                    self.editorCallHierarchyPanel = EditorCallHierarchyPanelState(
                        request: request,
                        incoming: incoming,
                        outgoing: outgoing,
                        message: hasItems ? nil : L10n.EditorCallHierarchy.noItems
                    )
                }
            } catch {
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language else {
                        return
                    }
                    self.editorCallHierarchyPanel = EditorCallHierarchyPanelState(
                        request: request,
                        incoming: [],
                        outgoing: [],
                        message: L10n.EditorCallHierarchy.unavailable
                    )
                }
            }
        }
    }

    func navigateToEditorCallHierarchyEntry(_ entry: EditorCallHierarchyEntry) {
        editorCallHierarchyPanel = nil
        navigateToDefinitionLocation(EditorDefinitionLocation(
            url: entry.fileURL,
            line: entry.line,
            title: entry.name
        ))
    }

    func renameEditorSymbol(request: EditorRenameRequest) {
        guard let fileURL = openedFileURL,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            return
        }

        let language = effectiveLanguage
        let root = rootDirectory
        let rootForSafety = EditorLanguageServiceRegistry.workspaceRoot(
            for: fileURL,
            language: language,
            explicitRoot: root
        )
        let text = fileContent

        Task { [weak self] in
            guard let self else { return }
            do {
                var initialName = request.symbol
                do {
                    guard let prepared = try await self.editorLanguageServiceManager.prepareRename(
                        fileURL: fileURL,
                        language: language,
                        rootDirectory: root,
                        text: text,
                        characterOffset: request.characterOffset
                    ) else {
                        await MainActor.run {
                            self.showFileOperationError(L10n.EditorRename.notRenameable)
                        }
                        return
                    }
                    if let placeholder = prepared.placeholder?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !placeholder.isEmpty {
                        initialName = placeholder
                    } else if let range = prepared.range,
                              range.length > 0,
                              NSMaxRange(range) <= (text as NSString).length {
                        initialName = (text as NSString).substring(with: range)
                    }
                } catch LanguageServerClientError.unsupportedCapability {
                    initialName = request.symbol
                }

                let newName = await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return nil as String?
                    }
                    return self.promptForEditorRename(initialName: initialName)
                }
                guard let newName else { return }
                guard newName != initialName else { return }

                let edit = try await self.editorLanguageServiceManager.rename(
                    fileURL: fileURL,
                    language: language,
                    rootDirectory: root,
                    text: text,
                    characterOffset: request.characterOffset,
                    newName: newName
                )
                let changes = EditorWorkspaceEditApplier.fileChanges(from: edit)
                let resourceChanges = EditorWorkspaceEditApplier.resourceChanges(from: edit)
                try await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    try self.applyEditorWorkspaceEditChanges(
                        changes,
                        resourceChanges: resourceChanges,
                        currentFileURL: fileURL,
                        currentText: text,
                        rootURL: rootForSafety
                    )
                }
            } catch let error as EditorWorkspaceEditApplicationError {
                await MainActor.run {
                    self.showFileOperationError(self.editorRenameErrorMessage(error))
                }
            } catch LanguageServerClientError.responseError {
                await MainActor.run {
                    self.showFileOperationError(L10n.EditorRename.notRenameable)
                }
            } catch {
                await MainActor.run {
                    self.showFileOperationError(L10n.EditorRename.failed(error.localizedDescription))
                }
            }
        }
    }

    private func promptForEditorRename(initialName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = L10n.EditorRename.title
        alert.informativeText = L10n.EditorRename.message(initialName)
        alert.addButton(withTitle: L10n.EditorRename.confirm)
        alert.addButton(withTitle: L10n.EditorRename.cancel)

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        textField.stringValue = initialName
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else {
            showFileOperationError(L10n.EditorRename.emptyName)
            return nil
        }
        return newName
    }

    func showEditorCompletions(request: EditorCompletionRequest) {
        guard let fileURL = openedFileURL,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            return
        }

        let language = effectiveLanguage
        let root = rootDirectory
        let text = fileContent
        editorCompletionPanel = EditorCompletionPanelState(
            request: request,
            items: [],
            isLoading: true,
            message: L10n.EditorCompletion.loading
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let completions = try await self.editorLanguageServiceManager.completion(
                    fileURL: fileURL,
                    language: language,
                    rootDirectory: root,
                    text: text,
                    characterOffset: request.characterOffset
                )
                let prefix = request.prefix.lowercased()
                let items = completions.enumerated().map { index, item in
                    EditorCompletionItem(item: item, index: index)
                }
                .filter { item in
                    prefix.isEmpty || item.label.lowercased().hasPrefix(prefix) || item.insertText.lowercased().hasPrefix(prefix)
                }
                .sorted { lhs, rhs in
                    lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
                }

                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    self.editorCompletionPanel = EditorCompletionPanelState(
                        request: request,
                        items: items,
                        message: items.isEmpty ? L10n.EditorCompletion.noItems : nil
                    )
                }
            } catch {
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language else {
                        return
                    }
                    self.editorCompletionPanel = EditorCompletionPanelState(
                        request: request,
                        items: [],
                        message: L10n.EditorCompletion.unavailable
                    )
                }
            }
        }
    }

    func applyEditorCompletion(_ item: EditorCompletionItem) {
        guard let panel = editorCompletionPanel else { return }
        guard let fileURL = openedFileURL,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            applyResolvedEditorCompletion(item, request: panel.request)
            return
        }

        let language = effectiveLanguage
        let root = rootDirectory
        let text = fileContent
        let request = panel.request
        Task { [weak self] in
            guard let self else { return }
            let resolvedItem: EditorCompletionItem
            do {
                let resolved = try await self.editorLanguageServiceManager.resolveCompletionItem(
                    fileURL: fileURL,
                    language: language,
                    rootDirectory: root,
                    text: text,
                    item: item.lspItem
                )
                resolvedItem = EditorCompletionItem(item: resolved, index: item.id.hashValue)
            } catch {
                resolvedItem = item
            }

            await MainActor.run {
                guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                      self.effectiveLanguage == language,
                      self.fileContent == text,
                      self.editorCompletionPanel?.request == request else {
                    return
                }
                self.applyResolvedEditorCompletion(resolvedItem, request: request)
            }
        }
    }

    private func applyResolvedEditorCompletion(_ item: EditorCompletionItem, request: EditorCompletionRequest) {
        guard let result = EditorCompletionTextEditApplier.apply(item: item, request: request, to: fileContent) else {
            editorCompletionPanel = nil
            return
        }

        fileContent = result.text
        isEdited = true
        editorCompletionPanel = nil
        editorTextSelectionRevision += 1
        editorTextSelectionRequest = EditorTextSelectionRequest(
            location: result.cursorLocation,
            revision: editorTextSelectionRevision
        )
        synchronizeEditorLanguageServiceDocument()
        NSApplication.shared.keyWindow?.isDocumentEdited = true
    }

    func expandEditorSelection(request: EditorSelectionRangeRequest) {
        guard let fileURL = openedFileURL,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            showFileOperationError(L10n.EditorSelectionRange.unavailable)
            return
        }

        let language = effectiveLanguage
        let root = rootDirectory
        let text = fileContent
        Task {
            do {
                let ranges = try await self.editorLanguageServiceManager.selectionRanges(
                    fileURL: fileURL,
                    language: language,
                    rootDirectory: root,
                    text: text,
                    characterOffset: request.characterOffset
                )
                let textLength = (text as NSString).length
                guard let expanded = EditorSelectionRangeResolver.expandedRange(
                    from: ranges,
                    currentRange: request.currentRange,
                    textLength: textLength
                ) else {
                    await MainActor.run {
                        self.showFileOperationError(L10n.EditorSelectionRange.noRange)
                    }
                    return
                }

                await MainActor.run {
                    guard self.openedFileURL == fileURL, self.fileContent == text else { return }
                    self.editorTextSelectionRevision += 1
                    self.editorTextSelectionRequest = EditorTextSelectionRequest(
                        range: expanded,
                        revision: self.editorTextSelectionRevision
                    )
                }
            } catch {
                await MainActor.run {
                    self.showFileOperationError(L10n.EditorSelectionRange.failed(error.localizedDescription))
                }
            }
        }
    }

    func openEditorDocumentLink(_ link: EditorDocumentLinkSpan) {
        guard let fileURL = openedFileURL,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            if let target = link.target {
                NSWorkspace.shared.open(target)
            }
            return
        }

        if let target = link.target {
            NSWorkspace.shared.open(target)
            return
        }

        let language = effectiveLanguage
        let root = rootDirectory
        let text = fileContent
        Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await self.editorLanguageServiceManager.resolveDocumentLink(
                    fileURL: fileURL,
                    language: language,
                    rootDirectory: root,
                    text: text,
                    link: link.lspLink
                )
                guard let target = resolved.targetURL else { return }
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    _ = NSWorkspace.shared.open(target)
                }
            } catch {
                guard let target = link.target else { return }
                await MainActor.run {
                    _ = NSWorkspace.shared.open(target)
                }
            }
        }
    }

    func showEditorSignatureHelp(request: EditorSignatureHelpRequest) {
        guard let fileURL = openedFileURL,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            return
        }

        let language = effectiveLanguage
        let root = rootDirectory
        let text = fileContent
        editorSignatureHelpPanel = EditorSignatureHelpPanelState(
            request: request,
            isLoading: true,
            message: L10n.EditorSignatureHelp.loading
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let signatureHelp = try await self.editorLanguageServiceManager.signatureHelp(
                    fileURL: fileURL,
                    language: language,
                    rootDirectory: root,
                    text: text,
                    characterOffset: request.characterOffset
                )
                let panel = EditorSignatureHelpPanelState(request: request, signatureHelp: signatureHelp)
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    self.editorSignatureHelpPanel = panel ?? EditorSignatureHelpPanelState(
                        request: request,
                        message: L10n.EditorSignatureHelp.noItems
                    )
                }
            } catch {
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language else {
                        return
                    }
                    self.editorSignatureHelpPanel = EditorSignatureHelpPanelState(
                        request: request,
                        message: L10n.EditorSignatureHelp.unavailable
                    )
                }
            }
        }
    }

    func showEditorCodeActions(request: EditorCodeActionRequest) {
        guard let fileURL = openedFileURL,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            return
        }

        let language = effectiveLanguage
        let root = rootDirectory
        let text = fileContent
        let lspRange = lspRange(from: request.range, in: text)
        let diagnostics = lspDiagnostics(overlapping: request.range, in: text)
        editorCodeActionPanel = EditorCodeActionPanelState(
            request: request,
            items: [],
            isLoading: true,
            message: L10n.EditorCodeAction.loading
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let actions = try await self.editorLanguageServiceManager.codeActions(
                    fileURL: fileURL,
                    language: language,
                    rootDirectory: root,
                    text: text,
                    range: lspRange,
                    diagnostics: diagnostics
                )
                let items = actions.enumerated().map { index, action in
                    EditorCodeActionItem(action: action, index: index)
                }
                .sorted { lhs, rhs in
                    if lhs.isPreferred != rhs.isPreferred {
                        return lhs.isPreferred && !rhs.isPreferred
                    }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }

                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    self.editorCodeActionPanel = EditorCodeActionPanelState(
                        request: request,
                        items: items,
                        message: items.isEmpty ? L10n.EditorCodeAction.noItems : nil
                    )
                }
            } catch {
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language else {
                        return
                    }
                    self.editorCodeActionPanel = EditorCodeActionPanelState(
                        request: request,
                        items: [],
                        message: L10n.EditorCodeAction.unavailable
                    )
                }
            }
        }
    }

    func applyEditorCodeAction(_ item: EditorCodeActionItem) {
        guard let fileURL = openedFileURL,
              let language = effectiveLanguage,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(language) else {
            return
        }

        let root = rootDirectory
        let text = fileContent
        Task { [weak self] in
            guard let self else { return }
            let resolvedItem: EditorCodeActionItem
            do {
                let resolved = try await self.editorLanguageServiceManager.resolveCodeAction(
                    fileURL: fileURL,
                    language: language,
                    rootDirectory: root,
                    text: text,
                    action: item.lspAction
                )
                resolvedItem = EditorCodeActionItem(action: resolved, index: item.id.hashValue)
            } catch {
                resolvedItem = item
            }

            await MainActor.run {
                guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                      self.effectiveLanguage == language,
                      self.fileContent == text else {
                    return
                }
                self.applyResolvedEditorCodeAction(resolvedItem, fileURL: fileURL, language: language, rootDirectory: root)
            }
        }
    }

    private func applyResolvedEditorCodeAction(
        _ item: EditorCodeActionItem,
        fileURL: URL,
        language: Language,
        rootDirectory root: URL?
    ) {
        guard item.edit != nil || item.command != nil else {
            showFileOperationError(L10n.EditorCodeAction.unsupportedCommand)
            return
        }

        let text = fileContent
        let rootForSafety = EditorLanguageServiceRegistry.workspaceRoot(
            for: fileURL,
            language: language,
            explicitRoot: root
        )
        if let edit = item.edit {
            let changes = EditorWorkspaceEditApplier.fileChanges(from: edit)
            let resourceChanges = EditorWorkspaceEditApplier.resourceChanges(from: edit)
            do {
                try applyEditorWorkspaceEditChanges(
                    changes,
                    resourceChanges: resourceChanges,
                    currentFileURL: fileURL,
                    currentText: text,
                    rootURL: rootForSafety
                )
            } catch let error as EditorWorkspaceEditApplicationError {
                showFileOperationError(editorCodeActionErrorMessage(error))
                return
            } catch {
                showFileOperationError(L10n.EditorCodeAction.failed(error.localizedDescription))
                return
            }
        }

        guard let command = item.command else {
            editorCodeActionPanel = nil
            synchronizeEditorLanguageServiceDocument()
            if inspectorMode == .structure || isSymbolJumpVisible {
                refreshEditorLanguageServiceOutline()
            }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let commandText = await MainActor.run { self.fileContent }
                try await self.editorLanguageServiceManager.executeCommand(
                    fileURL: fileURL,
                    language: language,
                    rootDirectory: root,
                    text: commandText,
                    command: command
                )
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language else {
                        return
                    }
                    self.editorCodeActionPanel = nil
                    self.synchronizeEditorLanguageServiceDocument()
                    if self.inspectorMode == .structure || self.isSymbolJumpVisible {
                        self.refreshEditorLanguageServiceOutline()
                    }
                }
            } catch {
                await MainActor.run {
                    self.showFileOperationError(L10n.EditorCodeAction.failed(error.localizedDescription))
                }
            }
        }
    }

    func formatEditorDocument() {
        guard let fileURL = openedFileURL,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            return
        }

        let language = effectiveLanguage
        let root = rootDirectory
        let text = fileContent
        let options = LSPFormattingOptions(
            tabSize: 4,
            insertSpaces: true,
            trimTrailingWhitespace: editorSettings.trimsTrailingWhitespaceOnSave,
            insertFinalNewline: editorSettings.ensuresFinalNewlineOnSave,
            trimFinalNewlines: false
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let edits = try await self.editorLanguageServiceManager.documentFormatting(
                    fileURL: fileURL,
                    language: language,
                    rootDirectory: root,
                    text: text,
                    options: options
                )
                guard let formatted = EditorTextEditApplier.apply(edits: edits, to: text) else { return }
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text,
                          formatted != self.fileContent else {
                        return
                    }
                    self.fileContent = formatted
                    self.isEdited = true
                    self.editorCompletionPanel = nil
                    self.editorSignatureHelpPanel = nil
                    self.editorCodeActionPanel = nil
                    self.editorHoverInfo = nil
                    self.editorReferencesPanel = nil
                    self.editorCallHierarchyPanel = nil
                    self.synchronizeEditorLanguageServiceDocument()
                    if self.inspectorMode == .structure || self.isSymbolJumpVisible {
                        self.refreshEditorLanguageServiceOutline()
                    }
                    NSApplication.shared.keyWindow?.isDocumentEdited = true
                }
            } catch {
                return
            }
        }
    }

    func formatEditorSelection(request: EditorRangeFormattingRequest) {
        guard let fileURL = openedFileURL,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage),
              request.range.length > 0 else {
            return
        }

        let language = effectiveLanguage
        let root = rootDirectory
        let text = fileContent
        let lspRange = lspRange(from: request.range, in: text)
        let options = LSPFormattingOptions(
            tabSize: 4,
            insertSpaces: true,
            trimTrailingWhitespace: editorSettings.trimsTrailingWhitespaceOnSave,
            insertFinalNewline: false,
            trimFinalNewlines: false
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let edits = try await self.editorLanguageServiceManager.documentRangeFormatting(
                    fileURL: fileURL,
                    language: language,
                    rootDirectory: root,
                    text: text,
                    range: lspRange,
                    options: options
                )
                guard let formatted = EditorTextEditApplier.apply(edits: edits, to: text) else { return }
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text,
                          formatted != self.fileContent else {
                        return
                    }
                    self.fileContent = formatted
                    self.isEdited = true
                    self.editorCompletionPanel = nil
                    self.editorSignatureHelpPanel = nil
                    self.editorCodeActionPanel = nil
                    self.editorHoverInfo = nil
                    self.editorReferencesPanel = nil
                    self.editorCallHierarchyPanel = nil
                    self.synchronizeEditorLanguageServiceDocument()
                    if self.inspectorMode == .structure || self.isSymbolJumpVisible {
                        self.refreshEditorLanguageServiceOutline()
                    }
                    NSApplication.shared.keyWindow?.isDocumentEdited = true
                }
            } catch {
                return
            }
        }
    }

    private func applyEditorWorkspaceEditChanges(
        _ changes: [EditorWorkspaceEditFileChange],
        resourceChanges: [EditorWorkspaceEditResourceChange] = [],
        currentFileURL: URL,
        currentText: String,
        rootURL: URL
    ) throws {
        guard !changes.isEmpty || !resourceChanges.isEmpty else {
            throw EditorWorkspaceEditApplicationError.noChanges
        }

        var appliedCount = 0
        var fileEvents: [(url: URL, type: LSPFileChangeType)] = []
        for change in resourceChanges {
            for fileURL in change.affectedFileURLs {
                guard EditorWorkspaceEditApplier.isSafeFileURL(fileURL, inside: rootURL) else {
                    throw EditorWorkspaceEditApplicationError.unsafeFile(fileURL)
                }
            }
            let events = try applyEditorWorkspaceResourceChange(change)
            if !events.isEmpty {
                appliedCount += 1
                fileEvents.append(contentsOf: events)
            }
        }

        for change in changes {
            let fileURL = change.fileURL.standardizedFileURL
            guard EditorWorkspaceEditApplier.isSafeFileURL(fileURL, inside: rootURL) else {
                throw EditorWorkspaceEditApplicationError.unsafeFile(fileURL)
            }

            if Self.sameFileURL(fileURL, currentFileURL) {
                guard let updated = EditorWorkspaceEditApplier.apply(fileChange: change, to: currentText) else {
                    throw EditorWorkspaceEditApplicationError.invalidEdit(fileURL)
                }
                guard updated != fileContent else { continue }
                fileContent = updated
                isEdited = true
                appliedCount += 1
                fileEvents.append((fileURL, .changed))
                continue
            }

            if let tabIndex = tabIndex(for: fileURL) {
                guard !tabs[tabIndex].isEdited else {
                    throw EditorWorkspaceEditApplicationError.unsavedOpenTab(fileURL)
                }
                let source = tabs[tabIndex].content
                guard let updated = EditorWorkspaceEditApplier.apply(fileChange: change, to: source) else {
                    throw EditorWorkspaceEditApplicationError.invalidEdit(fileURL)
                }
                guard updated != source else { continue }
                try updated.write(to: fileURL, atomically: true, encoding: .utf8)
                if tabs[tabIndex].content != updated {
                    tabs[tabIndex].contentRevision += 1
                }
                tabs[tabIndex].content = updated
                if tabs[tabIndex].savedContent != updated {
                    tabs[tabIndex].savedContentRevision += 1
                }
                tabs[tabIndex].savedContent = updated
                tabs[tabIndex].isEdited = false
                knownModificationDates[fileURL] = Self.modificationDate(at: fileURL)
                appliedCount += 1
                fileEvents.append((fileURL, .changed))
                continue
            }

            let data = try Self.readFileData(from: fileURL, allowLargeFile: true)
            let source = Self.decodeText(from: data)
            guard let updated = EditorWorkspaceEditApplier.apply(fileChange: change, to: source) else {
                throw EditorWorkspaceEditApplicationError.invalidEdit(fileURL)
            }
            guard updated != source else { continue }
            try updated.write(to: fileURL, atomically: true, encoding: .utf8)
            knownModificationDates[fileURL] = Self.modificationDate(at: fileURL)
            appliedCount += 1
            fileEvents.append((fileURL, .changed))
        }

        guard appliedCount > 0 else { throw EditorWorkspaceEditApplicationError.noChanges }

        for event in fileEvents {
            notifyEditorLanguageServiceWatchedFileChanged(url: event.url, type: event.type)
        }
        editorCompletionPanel = nil
        editorSignatureHelpPanel = nil
        editorCodeActionPanel = nil
        editorHoverInfo = nil
        editorReferencesPanel = nil
        editorCallHierarchyPanel = nil
        synchronizeEditorLanguageServiceDocument()
        if inspectorMode == .structure || isSymbolJumpVisible {
            refreshEditorLanguageServiceOutline()
        }
        refreshGitStatus()
        persistSession()
        NSApplication.shared.keyWindow?.isDocumentEdited = isEdited
    }

    private func applyEditorWorkspaceResourceChange(
        _ change: EditorWorkspaceEditResourceChange
    ) throws -> [(url: URL, type: LSPFileChangeType)] {
        switch change.operation.kind {
        case .create:
            guard let fileURL = change.fileURL else {
                throw EditorWorkspaceEditApplicationError.invalidEdit(URL(fileURLWithPath: "/"))
            }
            return try applyEditorWorkspaceCreateFile(fileURL, options: change.operation.options)
        case .rename:
            guard let oldURL = change.oldFileURL,
                  let newURL = change.newFileURL else {
                throw EditorWorkspaceEditApplicationError.invalidEdit(URL(fileURLWithPath: "/"))
            }
            return try applyEditorWorkspaceRenameFile(oldURL, to: newURL, options: change.operation.options)
        case .delete:
            guard let fileURL = change.fileURL else {
                throw EditorWorkspaceEditApplicationError.invalidEdit(URL(fileURLWithPath: "/"))
            }
            return try applyEditorWorkspaceDeleteFile(fileURL, options: change.operation.options)
        }
    }

    private func applyEditorWorkspaceCreateFile(
        _ fileURL: URL,
        options: LSPWorkspaceResourceOperationOptions?
    ) throws -> [(url: URL, type: LSPFileChangeType)] {
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: fileURL.path)
        if exists {
            if options?.ignoreIfExists == true { return [] }
            guard options?.overwrite == true else {
                throw EditorWorkspaceEditApplicationError.invalidEdit(fileURL)
            }
            if let tabIndex = tabIndex(for: fileURL), tabs[tabIndex].isEdited {
                throw EditorWorkspaceEditApplicationError.unsavedOpenTab(fileURL)
            }
            try fileManager.removeItem(at: fileURL)
        }

        var isDirectory: ObjCBool = false
        let parentURL = fileURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw EditorWorkspaceEditApplicationError.invalidEdit(fileURL)
        }

        try Data().write(to: fileURL, options: [.atomic])
        knownModificationDates[fileURL] = Self.modificationDate(at: fileURL)
        if let tabIndex = tabIndex(for: fileURL) {
            if tabs[tabIndex].content != "" {
                tabs[tabIndex].contentRevision += 1
            }
            tabs[tabIndex].content = ""
            if tabs[tabIndex].savedContent != "" {
                tabs[tabIndex].savedContentRevision += 1
            }
            tabs[tabIndex].savedContent = ""
            tabs[tabIndex].isEdited = false
            if tabs[tabIndex].id == activeTabID {
                fileContent = ""
                isEdited = false
                bumpEditorRenderRevision()
                bumpEditorHighlightRevision()
            }
        }
        return [(fileURL, .created)]
    }

    private func applyEditorWorkspaceRenameFile(
        _ oldURL: URL,
        to newURL: URL,
        options: LSPWorkspaceResourceOperationOptions?
    ) throws -> [(url: URL, type: LSPFileChangeType)] {
        let fileManager = FileManager.default
        guard !Self.sameFileURL(oldURL, newURL) else { return [] }
        let targetTabID = tabIndex(for: newURL).map { tabs[$0].id }
        guard fileManager.fileExists(atPath: oldURL.path) else {
            if options?.ignoreIfNotExists == true { return [] }
            throw EditorWorkspaceEditApplicationError.invalidEdit(oldURL)
        }
        if let oldTabIndex = tabIndex(for: oldURL), tabs[oldTabIndex].isEdited {
            throw EditorWorkspaceEditApplicationError.unsavedOpenTab(oldURL)
        }
        if let newTabIndex = tabIndex(for: newURL), tabs[newTabIndex].isEdited {
            throw EditorWorkspaceEditApplicationError.unsavedOpenTab(newURL)
        }

        if fileManager.fileExists(atPath: newURL.path) {
            if options?.ignoreIfExists == true { return [] }
            guard options?.overwrite == true else {
                throw EditorWorkspaceEditApplicationError.invalidEdit(newURL)
            }
            try fileManager.removeItem(at: newURL)
        }

        try fileManager.moveItem(at: oldURL, to: newURL)
        knownModificationDates.removeValue(forKey: oldURL)
        knownModificationDates[newURL] = Self.modificationDate(at: newURL)

        if let oldTabIndex = tabIndex(for: oldURL) {
            tabs[oldTabIndex].url = newURL
            tabs[oldTabIndex].isUntitled = false
            if tabs[oldTabIndex].id == activeTabID {
                suppressURLChangeProcessing = true
                openedFileURL = newURL
                selectedSidebarFileURL = newURL
                updateWindowTitle(url: newURL, isEdited: tabs[oldTabIndex].isEdited)
            }
        }
        if let targetTabID {
            closeTab(id: targetTabID)
        }
        return [(oldURL, .deleted), (newURL, .created)]
    }

    private func applyEditorWorkspaceDeleteFile(
        _ fileURL: URL,
        options: LSPWorkspaceResourceOperationOptions?
    ) throws -> [(url: URL, type: LSPFileChangeType)] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            if options?.ignoreIfNotExists == true { return [] }
            throw EditorWorkspaceEditApplicationError.invalidEdit(fileURL)
        }
        guard !isDirectory.boolValue || options?.recursive == true else {
            throw EditorWorkspaceEditApplicationError.invalidEdit(fileURL)
        }
        let affectedTabIndices = isDirectory.boolValue
            ? tabs.indices.filter { Self.isFileURL(tabs[$0].url, insideOrEqualTo: fileURL) }
            : tabs.indices.filter { Self.sameFileURL(tabs[$0].url, fileURL) }
        if let unsavedIndex = affectedTabIndices.first(where: { tabs[$0].isEdited }) {
            throw EditorWorkspaceEditApplicationError.unsavedOpenTab(tabs[unsavedIndex].url)
        }

        let tabIDs = affectedTabIndices.map { tabs[$0].id }
        try fileManager.removeItem(at: fileURL)
        knownModificationDates.removeValue(forKey: fileURL)
        for tabID in tabIDs {
            closeTab(id: tabID)
        }
        return [(fileURL, .deleted)]
    }

    private nonisolated static func isFileURL(_ url: URL, insideOrEqualTo directoryURL: URL) -> Bool {
        let directoryPath = directoryURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        return filePath == directoryPath || filePath.hasPrefix(directoryPath + "/")
    }

    private func editorRenameErrorMessage(_ error: EditorWorkspaceEditApplicationError) -> String {
        switch error {
        case .noChanges:
            return L10n.EditorRename.noChanges
        case .invalidEdit(let url):
            return L10n.EditorRename.failed(url.lastPathComponent)
        case .unsafeFile(let url):
            return L10n.EditorRename.unsafeFile(url.path)
        case .unsavedOpenTab(let url):
            return L10n.EditorRename.unsavedFile(url.path)
        }
    }

    private func editorCodeActionErrorMessage(_ error: EditorWorkspaceEditApplicationError) -> String {
        switch error {
        case .noChanges:
            return L10n.EditorCodeAction.noChanges
        case .invalidEdit(let url):
            return L10n.EditorCodeAction.failed(url.lastPathComponent)
        case .unsafeFile(let url):
            return L10n.EditorCodeAction.unsafeFile(url.path)
        case .unsavedOpenTab(let url):
            return L10n.EditorCodeAction.unsavedFile(url.path)
        }
    }

    private func applyEditorLanguageServiceWorkspaceEdit(_ params: LSPApplyWorkspaceEditParams) -> LSPApplyWorkspaceEditResponse {
        guard let fileURL = openedFileURL,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            return LSPApplyWorkspaceEditResponse(applied: false, failureReason: L10n.EditorCodeAction.unavailable)
        }
        let rootForSafety = EditorLanguageServiceRegistry.workspaceRoot(
            for: fileURL,
            language: effectiveLanguage,
            explicitRoot: rootDirectory
        )
        let changes = EditorWorkspaceEditApplier.fileChanges(from: params.edit)
        let resourceChanges = EditorWorkspaceEditApplier.resourceChanges(from: params.edit)

        do {
            try applyEditorWorkspaceEditChanges(
                changes,
                resourceChanges: resourceChanges,
                currentFileURL: fileURL,
                currentText: fileContent,
                rootURL: rootForSafety
            )
            return LSPApplyWorkspaceEditResponse(applied: true)
        } catch let error as EditorWorkspaceEditApplicationError {
            return LSPApplyWorkspaceEditResponse(applied: false, failureReason: editorCodeActionErrorMessage(error))
        } catch {
            return LSPApplyWorkspaceEditResponse(applied: false, failureReason: L10n.EditorCodeAction.failed(error.localizedDescription))
        }
    }

    private func lspRange(from range: NSRange, in text: String) -> LSPRange {
        let nsText = text as NSString
        let location = min(max(0, range.location), nsText.length)
        let end = min(max(location, NSMaxRange(range)), nsText.length)
        return LSPRange(
            start: LSPPosition(utf16Offset: location, in: text),
            end: LSPPosition(utf16Offset: end, in: text)
        )
    }

    private func lspDiagnostics(overlapping requestRange: NSRange, in text: String) -> [LSPDiagnostic] {
        editorLanguageServiceDiagnosticIssues
            .filter { issue in
                if requestRange.length == 0 {
                    return NSLocationInRange(requestRange.location, issue.range)
                        || NSLocationInRange(max(0, requestRange.location - 1), issue.range)
                }
                return NSIntersectionRange(issue.range, requestRange).length > 0
            }
            .map { issue in
                LSPDiagnostic(
                    range: lspRange(from: issue.range, in: text),
                    severity: issue.severity.rawValue,
                    code: nil,
                    source: issue.source,
                    message: issue.message
                )
            }
    }

    func showEditorHoverInfo(request: EditorHoverRequest) {
        guard let fileURL = openedFileURL,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            return
        }

        let language = effectiveLanguage
        let root = rootDirectory
        let text = fileContent
        editorHoverInfo = EditorHoverInfo(
            title: request.symbol,
            content: L10n.EditorHover.loading,
            isLoading: true
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let hover = try await self.editorLanguageServiceManager.hover(
                    fileURL: fileURL,
                    language: language,
                    rootDirectory: root,
                    text: text,
                    characterOffset: request.characterOffset
                )
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    self.editorHoverInfo = EditorHoverInfo(request: request, hover: hover)
                        ?? EditorHoverInfo(title: request.symbol, content: L10n.EditorHover.noInformation)
                }
            } catch {
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language else {
                        return
                    }
                    self.editorHoverInfo = EditorHoverInfo(
                        title: request.symbol,
                        content: L10n.EditorHover.unavailable
                    )
                }
            }
        }
    }

    var editorLanguageServiceOutlineIsAuthoritative: Bool {
        guard EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage),
              let uri = openedFileURL?.absoluteString else {
            return false
        }
        switch editorLanguageServiceOutlineStatus {
        case .available(let availableURI):
            return availableURI == uri
        case .unavailable, .loading, .failed:
            return false
        }
    }

    var editorLanguageServiceFoldingIsAuthoritative: Bool {
        guard EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage),
              let uri = openedFileURL?.absoluteString else {
            return false
        }
        switch editorLanguageServiceFoldingStatus {
        case .available(let availableURI):
            return availableURI == uri
        case .unavailable, .loading, .failed:
            return false
        }
    }

    func editorOutlineItems(fallback: () -> [EditorOutlineItem]) -> [EditorOutlineItem] {
        guard EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            return fallback()
        }
        return editorLanguageServiceOutlineIsAuthoritative ? editorLanguageServiceOutlineItems : fallback()
    }

    func editorWorkspaceSymbolSearchIsAuthoritative(query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            return false
        }
        switch editorWorkspaceSymbolSearchStatus {
        case .available(let availableQuery):
            return availableQuery == normalizedQuery
        case .unavailable, .loading, .failed:
            return false
        }
    }

    func refreshEditorWorkspaceSymbols(query: String) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty,
              let fileURL = openedFileURL,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            editorWorkspaceSymbolRevision += 1
            editorWorkspaceSymbolRequestKey = nil
            editorWorkspaceSymbolItems = []
            editorWorkspaceSymbolSearchStatus = .unavailable
            isEditorWorkspaceSymbolSearchLoading = false
            return
        }

        let language = effectiveLanguage
        let root = rootDirectory
        let text = fileContent
        let requestKey = "\(fileURL.absoluteString)#\(language?.rawValue ?? "")#\(normalizedQuery)#\(text.hashValue)"
        guard requestKey != editorWorkspaceSymbolRequestKey else { return }

        editorWorkspaceSymbolRevision += 1
        let revision = editorWorkspaceSymbolRevision
        editorWorkspaceSymbolRequestKey = requestKey
        editorWorkspaceSymbolSearchStatus = .loading(query: normalizedQuery)
        isEditorWorkspaceSymbolSearchLoading = true

        Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 160_000_000)
                let shouldContinue = await MainActor.run {
                    self.editorWorkspaceSymbolRevision == revision
                        && self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL
                        && self.effectiveLanguage == language
                        && self.symbolJumpQuery.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedQuery
                        && self.fileContent == text
                }
                guard shouldContinue else { return }

                let items = try await self.editorLanguageServiceManager.workspaceSymbols(
                    fileURL: fileURL,
                    language: language,
                    rootDirectory: root,
                    text: text,
                    query: normalizedQuery
                )
                await MainActor.run {
                    guard self.editorWorkspaceSymbolRevision == revision,
                          self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.symbolJumpQuery.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedQuery,
                          self.fileContent == text else {
                        return
                    }
                    self.editorWorkspaceSymbolItems = items
                    self.editorWorkspaceSymbolSearchStatus = .available(query: normalizedQuery)
                    self.isEditorWorkspaceSymbolSearchLoading = false
                }
            } catch {
                await MainActor.run {
                    guard self.editorWorkspaceSymbolRevision == revision,
                          self.openedFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
                          self.effectiveLanguage == language else {
                        return
                    }
                    self.editorWorkspaceSymbolItems = []
                    self.editorWorkspaceSymbolSearchStatus = .failed(query: normalizedQuery)
                    self.isEditorWorkspaceSymbolSearchLoading = false
                }
            }
        }
    }

    func synchronizeEditorLanguageServiceDocument() {
        installEditorLanguageServiceDiagnosticsHandlerIfNeeded()
        guard let url = openedFileURL else {
            cancelPendingEditorLanguageServiceSynchronization()
            clearEditorLanguageServiceStateForInactiveDocument()
            return
        }
        guard let language = effectiveLanguage else {
            cancelPendingEditorLanguageServiceSynchronization()
            clearEditorLanguageServiceStateForInactiveDocument()
            return
        }
        guard EditorLanguageServiceRegistry.isFirstStageIDELanguage(language) else {
            cancelPendingEditorLanguageServiceSynchronization()
            clearEditorLanguageServiceStateForInactiveDocument()
            return
        }
        if editorLanguageServiceDiagnosticsURI != url.absoluteString {
            editorLanguageServiceDiagnosticsURI = nil
            setEditorLanguageServiceValue(\.editorLanguageServiceDiagnosticIssues, to: [])
        }
        if editorLanguageServiceSemanticTokensURI != url.absoluteString {
            editorLanguageServiceSemanticTokensURI = nil
            setEditorLanguageServiceValue(\.editorSemanticTokenSpans, to: [])
        }
        if editorLanguageServiceInlayHintsURI != url.absoluteString {
            editorLanguageServiceInlayHintsURI = nil
            setEditorLanguageServiceValue(\.editorInlayHintSpans, to: [])
        }
        if editorLanguageServiceDocumentLinksURI != url.absoluteString {
            editorLanguageServiceDocumentLinksURI = nil
            setEditorLanguageServiceValue(\.editorDocumentLinkSpans, to: [])
        }
        if editorLanguageServiceFoldingURI != url.absoluteString {
            editorLanguageServiceFoldingURI = nil
            setEditorLanguageServiceValue(\.editorLanguageServiceFoldingGuides, to: [])
            setEditorLanguageServiceValue(\.editorLanguageServiceFoldingStatus, to: .unavailable)
        }
        if editorLanguageServiceDocumentHighlightsURI != url.absoluteString {
            editorLanguageServiceDocumentHighlightsURI = nil
            editorDocumentHighlightRequestKey = nil
            editorDocumentHighlightRevision += 1
            setEditorLanguageServiceValue(\.editorDocumentHighlightSpans, to: [])
        }
        let text = fileContent
        let root = rootDirectory
        editorLanguageServiceSynchronizationRevision += 1
        let revision = editorLanguageServiceSynchronizationRevision
        editorLanguageServiceSynchronizationTask?.cancel()
        editorLanguageServiceSynchronizationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            await MainActor.run {
                guard let self,
                      self.editorLanguageServiceSynchronizationRevision == revision,
                      self.openedFileURL?.standardizedFileURL == url.standardizedFileURL,
                      self.effectiveLanguage == language,
                      self.fileContent == text else {
                    return
                }
                self.performEditorLanguageServiceDocumentSynchronization(
                    url: url,
                    language: language,
                    root: root,
                    text: text
                )
            }
        }
    }

    private func performEditorLanguageServiceDocumentSynchronization(
        url: URL,
        language: Language,
        root: URL?,
        text: String
    ) {

        Task { [weak self] in
            guard let self else { return }
            do {
                let semanticSpans = try await self.editorLanguageServiceManager.semanticTokens(
                    fileURL: url,
                    language: language,
                    rootDirectory: root,
                    text: text
                )
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == url.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    self.editorLanguageServiceSemanticTokensURI = url.absoluteString
                    self.editorSemanticTokenSpans = semanticSpans
                }
            } catch {
                // Language servers are optional in this first-stage integration;
                // the regex highlighter/outline/definition fallback stays live.
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == url.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    self.editorLanguageServiceSemanticTokensURI = nil
                    self.editorSemanticTokenSpans = []
                }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            let uri = url.absoluteString
            await MainActor.run {
                guard self.openedFileURL?.standardizedFileURL == url.standardizedFileURL,
                      self.effectiveLanguage == language,
                      self.fileContent == text else {
                    return
                }
                self.editorLanguageServiceFoldingStatus = .loading(uri: uri)
            }
            do {
                let foldingGuides = try await self.editorLanguageServiceManager.foldingRanges(
                    fileURL: url,
                    language: language,
                    rootDirectory: root,
                    text: text
                )
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == url.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    self.editorLanguageServiceFoldingURI = uri
                    self.editorLanguageServiceFoldingGuides = foldingGuides
                    self.editorLanguageServiceFoldingStatus = .available(uri: uri)
                }
            } catch {
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == url.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    self.editorLanguageServiceFoldingURI = nil
                    self.editorLanguageServiceFoldingGuides = []
                    self.editorLanguageServiceFoldingStatus = .failed(uri: uri)
                }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let hints = try await self.editorLanguageServiceManager.inlayHints(
                    fileURL: url,
                    language: language,
                    rootDirectory: root,
                    text: text
                )
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == url.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    self.editorLanguageServiceInlayHintsURI = url.absoluteString
                    self.editorInlayHintSpans = hints
                }
            } catch {
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == url.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    self.editorLanguageServiceInlayHintsURI = nil
                    self.editorInlayHintSpans = []
                }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let links = try await self.editorLanguageServiceManager.documentLinks(
                    fileURL: url,
                    language: language,
                    rootDirectory: root,
                    text: text
                )
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == url.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    self.editorLanguageServiceDocumentLinksURI = url.absoluteString
                    self.editorDocumentLinkSpans = links
                }
            } catch {
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == url.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    self.editorLanguageServiceDocumentLinksURI = nil
                    self.editorDocumentLinkSpans = []
                }
            }
        }
    }

    private func cancelPendingEditorLanguageServiceSynchronization() {
        editorLanguageServiceSynchronizationRevision += 1
        editorLanguageServiceSynchronizationTask?.cancel()
        editorLanguageServiceSynchronizationTask = nil
    }

    private func clearEditorLanguageServiceStateForInactiveDocument() {
        editorWorkspaceSymbolRevision += 1
        editorWorkspaceSymbolRequestKey = nil
        setEditorLanguageServiceValue(\.editorWorkspaceSymbolItems, to: [])
        setEditorLanguageServiceValue(\.editorWorkspaceSymbolSearchStatus, to: .unavailable)
        setEditorLanguageServiceValue(\.isEditorWorkspaceSymbolSearchLoading, to: false)
        editorLanguageServiceDiagnosticsURI = nil
        setEditorLanguageServiceValue(\.editorLanguageServiceDiagnosticIssues, to: [])
        editorLanguageServiceSemanticTokensURI = nil
        setEditorLanguageServiceValue(\.editorSemanticTokenSpans, to: [])
        editorLanguageServiceInlayHintsURI = nil
        setEditorLanguageServiceValue(\.editorInlayHintSpans, to: [])
        editorLanguageServiceDocumentLinksURI = nil
        setEditorLanguageServiceValue(\.editorDocumentLinkSpans, to: [])
        editorLanguageServiceFoldingURI = nil
        setEditorLanguageServiceValue(\.editorLanguageServiceFoldingGuides, to: [])
        setEditorLanguageServiceValue(\.editorLanguageServiceFoldingStatus, to: .unavailable)
        editorLanguageServiceDocumentHighlightsURI = nil
        editorDocumentHighlightRequestKey = nil
        editorDocumentHighlightRevision += 1
        setEditorLanguageServiceValue(\.editorDocumentHighlightSpans, to: [])
        setEditorLanguageServiceValue(\.editorHoverInfo, to: nil)
        setEditorLanguageServiceValue(\.editorCompletionPanel, to: nil)
        setEditorLanguageServiceValue(\.editorSignatureHelpPanel, to: nil)
        setEditorLanguageServiceValue(\.editorCodeActionPanel, to: nil)
        setEditorLanguageServiceValue(\.editorReferencesPanel, to: nil)
        setEditorLanguageServiceValue(\.editorCallHierarchyPanel, to: nil)
    }

    private func setEditorLanguageServiceValue<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<AppState, Value>,
        to value: Value
    ) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    func notifyEditorLanguageServiceDocumentSaved(url: URL, text: String) {
        installEditorLanguageServiceDiagnosticsHandlerIfNeeded()
        let language = effectiveLanguage
        guard EditorLanguageServiceRegistry.isFirstStageIDELanguage(language) else { return }
        let root = rootDirectory
        let savedURL = url.standardizedFileURL
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.editorLanguageServiceManager.saveDocument(
                    fileURL: savedURL,
                    language: language,
                    rootDirectory: root,
                    text: text
                )
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == savedURL,
                          self.effectiveLanguage == language else {
                        return
                    }
                    self.refreshEditorLanguageServiceOutline()
                    self.synchronizeEditorLanguageServiceDocument()
                }
            } catch {
                // File save already succeeded; LSP save notification failure must not roll it back.
            }
        }
    }

    func notifyEditorLanguageServiceWatchedFileChanged(
        url: URL,
        type: LSPFileChangeType,
        language explicitLanguage: Language? = nil
    ) {
        installEditorLanguageServiceDiagnosticsHandlerIfNeeded()
        let detectedLanguage = explicitLanguage ?? Language.fromURL(url)
        let language = EditorLanguageServiceRegistry.isFirstStageIDELanguage(detectedLanguage) ? detectedLanguage : nil
        let root = rootDirectory

        Task { [weak self] in
            guard let self else { return }
            try? await self.editorLanguageServiceManager.didChangeWatchedFiles(
                fileURL: url.standardizedFileURL,
                language: language,
                rootDirectory: root,
                type: type
            )
        }
    }

    func applyEditorLanguageServiceDiagnostics(uri: String, diagnostics: [LSPDiagnostic]) {
        guard let currentURL = openedFileURL,
              currentURL.absoluteString == uri,
              EditorLanguageServiceRegistry.isFirstStageIDELanguage(effectiveLanguage) else {
            return
        }

        let text = fileContent
        editorLanguageServiceDiagnosticsURI = uri
        editorLanguageServiceDiagnosticIssues = diagnostics.compactMap { diagnostic in
            EditorDiagnosticIssue(diagnostic: diagnostic, in: text)
        }.sorted { lhs, rhs in
            if lhs.range.location == rhs.range.location {
                return lhs.severity.rawValue < rhs.severity.rawValue
            }
            return lhs.range.location < rhs.range.location
        }
    }

    func refreshEditorLanguageServiceOutline() {
        installEditorLanguageServiceDiagnosticsHandlerIfNeeded()
        guard let url = openedFileURL else {
            editorLanguageServiceOutlineItems = []
            editorLanguageServiceOutlineStatus = .unavailable
            return
        }
        let language = effectiveLanguage
        guard EditorLanguageServiceRegistry.isFirstStageIDELanguage(language) else {
            editorLanguageServiceOutlineItems = []
            editorLanguageServiceOutlineStatus = .unavailable
            return
        }

        let text = fileContent
        let root = rootDirectory
        let uri = url.absoluteString
        editorLanguageServiceOutlineStatus = .loading(uri: uri)

        Task { [weak self] in
            guard let self else { return }
            do {
                let symbols = try await self.editorLanguageServiceManager.documentSymbols(
                    fileURL: url,
                    language: language,
                    rootDirectory: root,
                    text: text
                )
                let outline = EditorOutlineExtractor.outline(from: symbols)
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == url.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    self.editorLanguageServiceOutlineItems = outline
                    self.editorLanguageServiceOutlineStatus = .available(uri: uri)
                }
            } catch {
                await MainActor.run {
                    guard self.openedFileURL?.standardizedFileURL == url.standardizedFileURL,
                          self.effectiveLanguage == language,
                          self.fileContent == text else {
                        return
                    }
                    self.editorLanguageServiceOutlineItems = []
                    self.editorLanguageServiceOutlineStatus = .failed(uri: uri)
                }
            }
        }
    }

    private func installEditorLanguageServiceDiagnosticsHandlerIfNeeded() {
        guard !editorLanguageServiceDiagnosticsHandlerInstalled else { return }
        editorLanguageServiceDiagnosticsHandlerInstalled = true

        Task { [weak self] in
            guard let self else { return }
            await self.editorLanguageServiceManager.setDiagnosticsHandler { [weak self] uri, diagnostics in
                Task { @MainActor [weak self] in
                    self?.applyEditorLanguageServiceDiagnostics(uri: uri, diagnostics: diagnostics)
                }
            }
            await self.editorLanguageServiceManager.setApplyEditHandler { [weak self] params in
                guard let self else {
                    let unavailable = await MainActor.run { L10n.EditorCodeAction.unavailable }
                    return LSPApplyWorkspaceEditResponse(applied: false, failureReason: unavailable)
                }
                return await MainActor.run {
                    self.applyEditorLanguageServiceWorkspaceEdit(params)
                }
            }
        }
    }

    func navigateToLanguageServerLocation(_ location: LSPLocation) async -> Bool {
        guard let url = URL(string: location.uri), url.isFileURL else {
            return false
        }

        let line = location.range.start.line + 1
        await MainActor.run {
            navigateToDefinitionLocation(EditorDefinitionLocation(
                url: url.standardizedFileURL,
                line: line,
                title: url.lastPathComponent
            ))
        }
        return true
    }

    private func previewLine(for location: LSPLocation, currentURL: URL, currentText: String) -> String? {
        guard let url = URL(string: location.uri), url.isFileURL else { return nil }
        let text: String
        if url.standardizedFileURL == currentURL.standardizedFileURL {
            text = currentText
        } else {
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        guard !text.isEmpty else { return nil }
        let lines = text.components(separatedBy: .newlines)
        let index = location.range.start.line
        guard index >= 0, index < lines.count else { return nil }
        return lines[index]
    }

    private func previewLine(for item: LSPCallHierarchyItem, currentURL: URL, currentText: String) -> String? {
        previewLine(
            for: LSPLocation(uri: item.uri, range: item.selectionRange),
            currentURL: currentURL,
            currentText: currentText
        )
    }

    private static func sortCallHierarchyEntries(_ lhs: EditorCallHierarchyEntry, _ rhs: EditorCallHierarchyEntry) -> Bool {
        if lhs.fileURL.path == rhs.fileURL.path {
            if lhs.line == rhs.line {
                return lhs.column < rhs.column
            }
            return lhs.line < rhs.line
        }
        return lhs.fileURL.path.localizedCaseInsensitiveCompare(rhs.fileURL.path) == .orderedAscending
    }
}
