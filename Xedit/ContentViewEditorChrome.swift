//
//  ContentViewEditorChrome.swift
//  WillDeep
//
//  Editor chrome and panel leaf views split from ContentView.swift so the
//  main window shell can stay focused on high-level layout and file routing.
//

import AppKit
import SwiftUI

struct GoToLinePanel: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var lineFieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.10)
                .ignoresSafeArea()
                .onTapGesture {
                    appState.hideGoToLine()
                }

            HStack(spacing: 10) {
                Image(systemName: "arrow.down.to.line")
                    .foregroundColor(.secondary)

                TextField(L10n.GoToLine.placeholder, text: $appState.goToLineText)
                    .textFieldStyle(.plain)
                    .focused($lineFieldFocused)
                    .onSubmit {
                        submit()
                    }

                Button {
                    submit()
                } label: {
                    Image(systemName: "return")
                }
                .buttonStyle(.borderless)
                .disabled(Int(appState.goToLineText) == nil)
            }
            .padding(12)
            .frame(width: 260)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 16, y: 8)
        }
        .onAppear {
            lineFieldFocused = true
        }
        .background {
            FloatingPanelEscapeKeyHandler {
                appState.hideGoToLine()
            }
        }
    }

    private func submit() {
        guard let line = Int(appState.goToLineText), line > 0 else { return }
        appState.navigateEditor(toLine: line)
        appState.hideGoToLine()
    }
}

struct EditorStatusBar: View {
    @EnvironmentObject var appState: AppState
    let language: Language?

    private var fileSizeText: String {
        guard let url = appState.openedFileURL,
              let size = AppState.fileSize(at: url) else {
            return "--"
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var body: some View {
        HStack(spacing: 14) {
            if appState.hasExternalFileChanges {
                Text(L10n.EditorStatusBar.externalChanges)
                    .foregroundColor(.orange)
                Button(L10n.EditorStatusBar.reloadButton) {
                    appState.reloadCurrentFileFromDisk()
                }
                .buttonStyle(.borderless)
            }
            Text(appState.isEdited ? L10n.EditorStatusBar.modified : L10n.EditorStatusBar.saved)
                .foregroundColor(appState.isEdited ? .orange : .secondary)
            if appState.editorDiagnosticSummary.total > 0 {
                Button {
                    appState.navigateToFirstDiagnostic()
                } label: {
                    HStack(spacing: 5) {
                        if appState.editorDiagnosticSummary.errors > 0 {
                            Label(
                                String(appState.editorDiagnosticSummary.errors),
                                systemImage: "xmark.octagon.fill"
                            )
                            .foregroundColor(.red)
                        }
                        if appState.editorDiagnosticSummary.warnings > 0 {
                            Label(
                                String(appState.editorDiagnosticSummary.warnings),
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundColor(.orange)
                        }
                    }
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .help(L10n.EditorStatusBar.diagnosticsHelp)
            }
            Text(L10n.EditorStatusBar.cursorPosition(String(appState.cursorLine), String(appState.cursorColumn)))
            if appState.selectedCharacterCount > 0 {
                Text("\(L10n.EditorStatusBar.selection(String(appState.selectedCharacterCount))), \(L10n.EditorStatusBar.selectionLines(String(appState.selectedLineCount)))")
            }
            Spacer(minLength: 0)
            if let branchName = appState.gitStatus.branchName {
                Text(L10n.EditorStatusBar.gitBranch(branchName))
            }
            Button {
                appState.toggleEditorTerminal(appState.openedFileURL ?? appState.rootDirectory)
            } label: {
                Image(systemName: appState.isEditorTerminalVisible ? "terminal.fill" : "terminal")
                    .font(.system(size: 11, weight: appState.isEditorTerminalVisible ? .semibold : .regular))
                    .foregroundStyle(appState.isEditorTerminalVisible ? Color.accentColor : Color.secondary)
                    .frame(width: 22, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(appState.isEditorTerminalVisible ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
            }
            .buttonStyle(.borderless)
            .disabled(appState.rootDirectory == nil && appState.openedFileURL == nil)
            .help(L10n.EditorStatusBar.toggleTerminalHelp)
            Text(language?.displayName ?? L10n.EditorStatusBar.plainText)
            Text(fileSizeText)
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

struct EditorHoverInfoPanel: View {
    let info: EditorHoverInfo
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(Color.accentColor)
                Text(info.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if info.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(L10n.EditorHover.close)
            }

            ScrollView {
                Text(info.content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
        .padding(12)
        .frame(width: 420, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 18, y: 8)
        .padding(.top, 54)
        .padding(.trailing, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .background(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
        }
        .background {
            FloatingPanelEscapeKeyHandler {
                onClose()
            }
        }
    }
}

struct EditorCompletionPanel: View {
    let state: EditorCompletionPanelState
    let onSelect: (EditorCompletionItem) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "text.cursor")
                    .foregroundStyle(Color.accentColor)
                Text(state.request.prefix.isEmpty ? L10n.EditorCompletion.title : state.request.prefix)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(L10n.EditorCompletion.close)
            }

            if let message = state.message, state.items.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(state.items.prefix(40)) { item in
                            Button {
                                onSelect(item)
                            } label: {
                                EditorCompletionRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(10)
        .frame(width: 430, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 18, y: 8)
        .padding(.top, 54)
        .padding(.trailing, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .background(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
        }
        .background {
            FloatingPanelEscapeKeyHandler {
                onClose()
            }
        }
    }
}

private struct EditorCompletionRow: View {
    let item: EditorCompletionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(item.label)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if let documentation = item.documentation, !documentation.isEmpty {
                Text(documentation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private var iconName: String {
        switch item.kind {
        case 2:
            return "cube"
        case 3:
            return "function"
        case 5, 6, 7:
            return "number"
        case 9:
            return "cube.box"
        case 10:
            return "shippingbox"
        case 14:
            return "puzzlepiece"
        default:
            return "sparkle.magnifyingglass"
        }
    }
}

struct EditorSignatureHelpPanel: View {
    let state: EditorSignatureHelpPanelState
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "function")
                    .foregroundStyle(Color.accentColor)
                Text(L10n.EditorSignatureHelp.title)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(L10n.EditorSignatureHelp.close)
            }

            if let message = state.message, state.signatureLabel.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                Text(state.signatureLabel)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let documentation = state.documentation, !documentation.isEmpty {
                    Text(documentation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }

                if !state.parameters.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(state.parameters) { parameter in
                            EditorSignatureParameterRow(parameter: parameter)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(10)
        .frame(width: 430, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 18, y: 8)
        .padding(.top, 54)
        .padding(.trailing, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .background(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
        }
        .background {
            FloatingPanelEscapeKeyHandler {
                onClose()
            }
        }
    }
}

private struct EditorSignatureParameterRow: View {
    let parameter: EditorSignatureParameter

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(parameter.label)
                .font(.system(.caption2, design: .monospaced).weight(parameter.isActive ? .semibold : .regular))
                .foregroundStyle(parameter.isActive ? Color.accentColor : Color.primary)
                .lineLimit(1)
            if let documentation = parameter.documentation, !documentation.isEmpty {
                Text(documentation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(parameter.isActive ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        )
    }
}

struct EditorCodeActionPanel: View {
    let state: EditorCodeActionPanelState
    let onSelect: (EditorCodeActionItem) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(Color.accentColor)
                Text(L10n.EditorCodeAction.title)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(L10n.EditorCodeAction.close)
            }

            if let message = state.message, state.items.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(state.items.prefix(60)) { item in
                            Button {
                                onSelect(item)
                            } label: {
                                EditorCodeActionRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(10)
        .frame(width: 430, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 18, y: 8)
        .padding(.top, 54)
        .padding(.trailing, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .background(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
        }
        .background {
            FloatingPanelEscapeKeyHandler {
                onClose()
            }
        }
    }
}

private struct EditorCodeActionRow: View {
    let item: EditorCodeActionItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.edit == nil ? "terminal" : "wand.and.stars")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    if item.isPreferred {
                        Text(L10n.EditorCodeAction.preferred)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                if let kind = item.kind, !kind.isEmpty {
                    Text(kind)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(item.isPreferred ? Color.accentColor.opacity(0.11) : Color.primary.opacity(0.04))
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct EditorReferencesPanel: View {
    let state: EditorReferencesPanelState
    let onSelect: (EditorReferenceItem) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(Color.accentColor)
                Text(state.request.symbol.isEmpty ? L10n.EditorReferences.title : state.request.symbol)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(L10n.EditorReferences.close)
            }

            if let message = state.message, state.items.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(state.items.prefix(80))) { item in
                            Button {
                                onSelect(item)
                            } label: {
                                EditorReferenceRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(10)
        .frame(width: 460, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 18, y: 8)
        .padding(.top, 54)
        .padding(.trailing, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .background(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
        }
        .background {
            FloatingPanelEscapeKeyHandler {
                onClose()
            }
        }
    }
}

private struct EditorReferenceRow: View {
    let item: EditorReferenceItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(item.fileName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.line):\(item.column)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if !item.preview.isEmpty {
                Text(item.preview)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct EditorCallHierarchyPanel: View {
    let state: EditorCallHierarchyPanelState
    let onSelect: (EditorCallHierarchyEntry) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(Color.accentColor)
                Text(state.request.symbol.isEmpty ? L10n.EditorCallHierarchy.title : state.request.symbol)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(L10n.EditorCallHierarchy.close)
            }

            if let message = state.message, state.incoming.isEmpty, state.outgoing.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        EditorCallHierarchySection(
                            title: L10n.EditorCallHierarchy.incoming,
                            entries: state.incoming,
                            onSelect: onSelect
                        )
                        EditorCallHierarchySection(
                            title: L10n.EditorCallHierarchy.outgoing,
                            entries: state.outgoing,
                            onSelect: onSelect
                        )
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(10)
        .frame(width: 500, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 18, y: 8)
        .padding(.top, 54)
        .padding(.trailing, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .background(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
        }
        .background {
            FloatingPanelEscapeKeyHandler {
                onClose()
            }
        }
    }
}

private struct EditorCallHierarchySection: View {
    let title: String
    let entries: [EditorCallHierarchyEntry]
    let onSelect: (EditorCallHierarchyEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(entries.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }

            if entries.isEmpty {
                Text(L10n.EditorCallHierarchy.emptySection)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(entries.prefix(60))) { entry in
                    Button {
                        onSelect(entry)
                    } label: {
                        EditorCallHierarchyRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct EditorCallHierarchyRow: View {
    let entry: EditorCallHierarchyEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: entry.direction == .incoming ? "arrow.down.left" : "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(entry.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.fileName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(entry.line):\(entry.column)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if let detail = entry.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 24)
            }
            if !entry.preview.isEmpty {
                Text(entry.preview)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct SplitEditorPane: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let splitLanguage = appState.splitFileURL.map(Language.fromURL) ?? nil

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.split.2x1")
                    .foregroundColor(.secondary)
                Text(appState.splitFileURL?.lastPathComponent ?? L10n.SplitEditor.defaultTitle)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    appState.closeSplitEditor()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            EditorView(
                text: $appState.splitFileContent,
                language: splitLanguage,
                settings: appState.editorSettings,
                highlightRevision: appState.editorHighlightRevision,
                searchRanges: [],
                activeSearchRange: nil
            )
        }
        .overlay(alignment: .leading) {
            Divider()
        }
    }
}

struct PreviewPane: View {
    let text: String
    let language: Language?
    let onClose: () -> Void

    private var blocks: [MarkdownPreviewBlock] {
        switch language {
        case .html:
            return HTMLPreviewParser.blocks(from: text)
        default:
            return MarkdownPreviewParser.blocks(from: text)
        }
    }

    static func supports(_ language: Language?) -> Bool {
        language == .markdown || language == .html
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext")
                    .foregroundColor(.secondary)
                Text(L10n.PreviewPane.title)
                    .font(.caption)
                Spacer(minLength: 0)
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        MarkdownPreviewBlockView(block: block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .overlay(alignment: .leading) {
            Divider()
        }
    }
}

struct InspectorCollapsedRail: View {
    let onOpen: () -> Void

    var body: some View {
        Button {
            onOpen()
        } label: {
            VStack {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(90))
            }
            .frame(width: 14)
            .frame(maxHeight: .infinity)
            .foregroundColor(Color(nsColor: .secondaryLabelColor))
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.Inspector.showButton)
        .overlay(alignment: .leading) {
            Divider()
        }
    }
}

struct EditorInspectorSidebar: View {
    let text: String
    let language: Language?
    let ideOutlineItems: [EditorOutlineItem]
    @Binding var mode: EditorInspectorMode
    let orderedModes: [EditorInspectorMode]
    let onNavigateToLine: (Int) -> Void
    let onRefreshIDEOutline: () -> Void
    let onClose: () -> Void

    @State private var outline: [EditorOutlineItem] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Inspector", selection: $mode) {
                    ForEach(orderedModes) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .help(L10n.Inspector.hideButton)
            }
            .padding(8)

            Divider()

            switch mode {
            case .minimap:
                EditorMinimapView(text: text, onNavigateToLine: onNavigateToLine)
            case .structure:
                EditorStructureView(
                    items: ideOutlineItems.isEmpty ? outline : ideOutlineItems,
                    onNavigateToLine: onNavigateToLine
                )
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .leading) {
            Divider()
        }
        .task(id: TextLanguageKey(text: text, language: language, mode: mode)) {
            guard mode == .structure else { return }
            onRefreshIDEOutline()
            let source = text
            let lang = language
            let extracted = await Task.detached(priority: .userInitiated) {
                EditorOutlineExtractor.outline(for: source, language: lang)
            }.value
            guard !Task.isCancelled else { return }
            outline = extracted
        }
    }
}

private struct TextLanguageKey: Equatable {
    let text: String
    let language: Language?
    let mode: EditorInspectorMode
}

private struct EditorMinimapView: View {
    let text: String
    let onNavigateToLine: (Int) -> Void

    @State private var lines: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Button {
                        onNavigateToLine(index + 1)
                    } label: {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(line.trimmingCharacters(in: .whitespaces).isEmpty
                                  ? Color(nsColor: .separatorColor).opacity(0.28)
                                  : Color(nsColor: .secondaryLabelColor).opacity(0.38))
                            .frame(width: minimapWidth(for: line), height: 2)
                            .frame(maxWidth: .infinity, minHeight: 6, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .task(id: text) {
            let source = text
            let computed = await Task.detached(priority: .userInitiated) {
                Array(source.components(separatedBy: .newlines).prefix(600))
            }.value
            guard !Task.isCancelled else { return }
            lines = computed
        }
    }

    private func minimapWidth(for line: String) -> CGFloat {
        let count = line.trimmingCharacters(in: .whitespaces).count
        return min(180, max(12, CGFloat(count) * 1.8))
    }
}

private struct EditorStructureView: View {
    let items: [EditorOutlineItem]
    let onNavigateToLine: (Int) -> Void

    var body: some View {
        if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 22))
                Text(L10n.EditorStructure.noStructure)
                    .font(.caption)
            }
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(items) { item in
                Button {
                    onNavigateToLine(item.line)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: iconName(for: item.kind))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(item.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text("\(item.line)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.leading, CGFloat(item.level) * 10)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 22)
        }
    }

    private func iconName(for kind: EditorOutlineItem.Kind) -> String {
        switch kind {
        case .type:
            return "cube"
        case .function:
            return "function"
        case .property:
            return "number"
        case .section:
            return "text.alignleft"
        case .key:
            return "key"
        }
    }
}

struct FindReplaceBar: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var findFieldFocused: Bool

    private var matchText: String {
        let matches = appState.findMatchRanges
        guard !appState.findQuery.isEmpty else { return "" }
        guard !matches.isEmpty else { return L10n.FindReplaceBar.noMatches }
        return L10n.FindReplaceBar.matchCount(String(min(appState.activeFindIndex + 1, matches.count)), String(matches.count))
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField(L10n.FindReplaceBar.findPlaceholder, text: $appState.findQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .focused($findFieldFocused)

            Button {
                appState.findPrevious()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(appState.findMatchRanges.isEmpty)
            .help(L10n.FindReplaceBar.previousMatchButton)

            Button {
                appState.findNext()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(appState.findMatchRanges.isEmpty)
            .help(L10n.FindReplaceBar.nextMatchButton)

            Text(matchText)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 82, alignment: .leading)

            Divider()
                .frame(height: 18)

            TextField(L10n.FindReplaceBar.replacePlaceholder, text: $appState.replaceText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)

            Picker("Scope", selection: $appState.findReplaceScope) {
                ForEach(FindReplaceScope.allCases) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            .disabled(appState.findReplaceScope == .selectedFolder && appState.selectedFolderURL == nil)

            Button(L10n.FindReplaceBar.replaceButton) {
                appState.replaceCurrentFindMatch()
            }
            .disabled(appState.findMatchRanges.isEmpty)

            Button(L10n.FindReplaceBar.replaceAllButton) {
                appState.replaceAllFindMatches()
            }
            .disabled(appState.findMatchRanges.isEmpty)

            Spacer(minLength: 0)

            Button {
                appState.hideFindBar()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(L10n.FindReplaceBar.closeButton)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .onAppear {
            findFieldFocused = true
        }
    }
}

struct EditorTabBar: View {
    let tabs: [EditorTab]
    let activeTabID: EditorTab.ID?
    let leadingReserve: CGFloat
    var trailingReserve: CGFloat = 0
    let onSelect: (EditorTab.ID) -> Void
    let onClose: (EditorTab.ID) -> Void
    let onDoubleClick: (EditorTab.ID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    HStack(spacing: 6) {
                        Text(tab.isEdited ? "\(tab.title) *" : tab.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.system(size: 12, weight: tab.id == activeTabID ? .semibold : .regular))

                        Button {
                            onClose(tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .accessibilityLabel(L10n.EditorTabBar.closeTab(tab.title))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minWidth: 96, maxWidth: 220)
                    .background(tab.id == activeTabID ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture(count: 2) {
                        onDoubleClick(tab.id)
                    }
                    .onTapGesture {
                        onSelect(tab.id)
                    }
                    .help(tab.url.path)
                }
            }
            .padding(.leading, 8 + leadingReserve)
            .padding(.trailing, 8 + trailingReserve)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct EnterAgentModeButton: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            // 1.80.0-rc1：Agent 是独立 singleton 窗口。openWindow(id:)
            // 对单例 Window scene 幂等 —— 已经存在则抬起，不存在则
            // 创建。窗口本身通过 EditorAppStateRegistry 自动跟随当前
            // 聚焦的 editor 窗口（即 self.appState 所在窗口）。
            openWindow(id: AgentWindowID.value)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                Text(L10n.EnterAgentModeButton.label)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(Color.white)
            .background(Capsule(style: .continuous).fill(Color.accentColor))
        }
        .buttonStyle(.plain)
        .help(L10n.EnterAgentModeButton.help)
    }
}
