//
//  AgentComposerFileAttachmentViews.swift
//  WillDeep
//
//  Parse-status chip and local extraction preview for document attachments.
//

import SwiftUI

struct AgentDocumentContextControls: View {
    let mode: AgentDocumentTaskMode
    let redactsSensitiveContent: Bool
    let makePreview: () -> AgentDocumentSendPreview?
    let onSetMode: (AgentDocumentTaskMode) -> Void
    let onSetRedaction: (Bool) -> Void

    @State private var preview: AgentDocumentSendPreview?

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(AgentDocumentTaskMode.allCases, id: \.rawValue) { candidate in
                    Button {
                        onSetMode(candidate)
                    } label: {
                        if candidate == mode {
                            Label(modeTitle(candidate), systemImage: "checkmark")
                        } else {
                            Text(modeTitle(candidate))
                        }
                    }
                }
            } label: {
                Label(modeTitle(mode), systemImage: "wand.and.stars")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Toggle(isOn: Binding(
                get: { redactsSensitiveContent },
                set: onSetRedaction
            )) {
                Label(L10n.Composer.documentRedactSensitive, systemImage: "hand.raised.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .fixedSize()

            Button {
                preview = makePreview()
            } label: {
                Label(L10n.Composer.documentSendPreview, systemImage: "eye")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .focusable(false)
            // `.sheet(item:)` presents only once `preview` is non-nil and hands
            // the unwrapped value straight to the body — no separate bool that
            // can flip true before the value lands (which left the modal empty).
            .sheet(item: $preview) { preview in
                AgentDocumentSendPreviewSheet(preview: preview)
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }

    private func modeTitle(_ mode: AgentDocumentTaskMode) -> String {
        switch mode {
        case .automatic: return L10n.Composer.documentModeAutomatic
        case .summarize: return L10n.Composer.documentModeSummarize
        case .compare: return L10n.Composer.documentModeCompare
        case .spreadsheetAnalysis: return L10n.Composer.documentModeSpreadsheet
        case .codeReview: return L10n.Composer.documentModeCodeReview
        case .evidenceExtraction: return L10n.Composer.documentModeEvidence
        }
    }
}

private struct AgentDocumentSendPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let preview: AgentDocumentSendPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(L10n.Composer.documentSendPreviewTitle)
                    .font(.headline)
                Spacer(minLength: 0)
                Button {
                    dismiss()
                } label: {
                    Label(L10n.Composer.documentSendPreviewClose, systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(L10n.Composer.documentSendPreviewClose)
                .focusable(false)
            }
            if !preview.findings.isEmpty {
                Label(
                    L10n.Composer.documentSensitiveFindings(
                        preview.findings.reduce(0) { $0 + $1.count }
                    ),
                    systemImage: "hand.raised.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            ScrollView {
                Text(preview.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable(false)
        }
        .padding(16)
        .frame(width: 620, height: 480)
        .focusable(false)
    }
}

struct AgentKnowledgeFolderStrip: View {
    let folders: [AgentKnowledgeFolder]
    let onToggleEnabled: (String) -> Void
    let onRemove: (String) -> Void
    let onUpdateExclusions: (String, String) -> Void
    let onStartIndexing: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill.badge.gearshape")
                    .font(.system(size: 10, weight: .semibold))
                Text(L10n.Composer.knowledgeFolders(folders.count))
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(folders) { folder in
                        AgentKnowledgeFolderChip(
                            folder: folder,
                            onToggleEnabled: { onToggleEnabled(folder.id) },
                            onRemove: { onRemove(folder.id) },
                            onUpdateExclusions: { onUpdateExclusions(folder.id, $0) },
                            onStartIndexing: { onStartIndexing(folder.id) }
                        )
                    }
                }
            }
        }
    }
}

private struct AgentKnowledgeFolderChip: View {
    let folder: AgentKnowledgeFolder
    let onToggleEnabled: () -> Void
    let onRemove: () -> Void
    let onUpdateExclusions: (String) -> Void
    let onStartIndexing: () -> Void

    @State private var isPresented = false
    @State private var exclusionDraft = ""

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggleEnabled) {
                Image(systemName: folder.isEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(folder.isEnabled ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)

            Button {
                exclusionDraft = folder.excludedPatterns.joined(separator: ", ")
                isPresented.toggle()
            } label: {
                HStack(spacing: 4) {
                    statusIcon
                    Text(folder.url.lastPathComponent)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    Text("\(folder.documents.filter { $0.parseStatus == .ready }.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .focusable(false)
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                folderPopover
            }

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(Color.teal.opacity(folder.isEnabled ? 0.10 : 0.04)))
        .overlay(Capsule(style: .continuous).stroke(Color.teal.opacity(folder.isEnabled ? 0.34 : 0.14), lineWidth: 1))
        .help(folder.url.path)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch folder.status {
        case .pending:
            Image(systemName: "pause.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        case .indexing:
            ProgressView().controlSize(.mini).frame(width: 10, height: 10)
        case .ready:
            Image(systemName: "folder.fill").font(.system(size: 10)).foregroundStyle(.teal)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.red)
        }
    }

    private var folderPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(folder.url.lastPathComponent)
                .font(.headline)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if folder.status != .indexing {
                Button(indexActionTitle, action: onStartIndexing)
                    .buttonStyle(.borderedProminent)
            }

            TextField(L10n.Composer.knowledgeFolderExclusionsPlaceholder, text: $exclusionDraft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text(L10n.Composer.knowledgeFolderExclusionsHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.Composer.knowledgeFolderApplyExclusions) {
                    onUpdateExclusions(exclusionDraft)
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(folder.documents) { document in
                        HStack(spacing: 6) {
                            Image(systemName: document.parseStatus == .ready ? "doc.text" : "exclamationmark.triangle")
                                .foregroundStyle(document.parseStatus == .ready ? Color.secondary : .orange)
                            Text(document.relativePath)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(14)
        .frame(width: 440)
        .focusable(false)
    }

    private var statusText: String {
        switch folder.status {
        case .pending:
            return L10n.Composer.knowledgeFolderPending
        case .indexing:
            return L10n.Composer.knowledgeFolderIndexing
        case .failed:
            return L10n.Composer.knowledgeFolderFailed
        case .ready:
            return L10n.Composer.knowledgeFolderReady(
                folder.documents.filter { $0.parseStatus == .ready }.count,
                folder.skippedFileCount
            )
        }
    }

    private var indexActionTitle: String {
        switch folder.status {
        case .pending:
            return L10n.Composer.knowledgeFolderStartIndexing
        case .failed:
            return L10n.Composer.knowledgeFolderRetryIndexing
        case .ready:
            return L10n.Composer.knowledgeFolderReindex
        case .indexing:
            return L10n.Composer.knowledgeFolderIndexing
        }
    }
}

struct AgentSessionDocumentLibraryStrip: View {
    let files: [AgentFileAttachment]
    let onToggleEnabled: (String) -> Void
    let onRemove: (String) -> Void
    let onToggleSection: (String, String) -> Void
    let onSetAllSections: (String, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 10, weight: .semibold))
                Text(L10n.Composer.sessionDocuments(files.count))
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(files) { file in
                        AgentSessionDocumentChip(
                            file: file,
                            onToggleEnabled: { onToggleEnabled(file.id) },
                            onRemove: { onRemove(file.id) },
                            onToggleSection: { onToggleSection(file.id, $0) },
                            onSetAllSections: { onSetAllSections(file.id, $0) }
                        )
                    }
                }
            }
        }
    }
}

private struct AgentSessionDocumentChip: View {
    let file: AgentFileAttachment
    let onToggleEnabled: () -> Void
    let onRemove: () -> Void
    let onToggleSection: (String) -> Void
    let onSetAllSections: (Bool) -> Void

    @State private var isPreviewPresented = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggleEnabled) {
                Image(systemName: file.isEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(file.isEnabled ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(file.isEnabled ? L10n.Composer.disableSessionDocument : L10n.Composer.enableSessionDocument)

            Button {
                isPreviewPresented.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: file.analysis?.didUseOCR == true ? "text.viewfinder" : "doc.text")
                        .font(.system(size: 10))
                    Text(file.relativePath)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(file.isEnabled ? Color.primary : .secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.Composer.attachmentPreviewHelp)
            .popover(isPresented: $isPreviewPresented, arrowEdge: .top) {
                AgentAttachmentPreviewPopover(
                    file: file,
                    onToggleSection: onToggleSection,
                    onSetAllSections: onSetAllSections
                )
            }

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.Composer.removeSessionDocument)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(Color.indigo.opacity(file.isEnabled ? 0.10 : 0.04)))
        .overlay(Capsule(style: .continuous).stroke(Color.indigo.opacity(file.isEnabled ? 0.32 : 0.14), lineWidth: 1))
        .help(file.url.path)
        .focusable(false)
    }
}

struct AgentComposerFileAttachmentChip: View {
    let file: AgentFileAttachment
    let onRemove: () -> Void
    let onToggleSection: (String) -> Void
    let onSetAllSections: (Bool) -> Void

    @State private var isPreviewPresented = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                isPreviewPresented.toggle()
            } label: {
                HStack(spacing: 4) {
                    statusIcon
                    Text("@\(file.relativePath)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.Composer.attachmentPreviewHelp)
            .popover(isPresented: $isPreviewPresented, arrowEdge: .top) {
                AgentAttachmentPreviewPopover(
                    file: file,
                    onToggleSection: onToggleSection,
                    onSetAllSections: onSetAllSections
                )
            }

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.Composer.removeAttachmentHelp)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(Color.purple.opacity(0.10)))
        .overlay(Capsule(style: .continuous).stroke(statusColor.opacity(0.35), lineWidth: 1))
        .help(file.url.path)
        .focusable(false)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch file.parseStatus {
        case .parsing:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 10, height: 10)
        case .ready:
            Image(systemName: file.analysis?.didUseOCR == true ? "text.viewfinder" : "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(statusColor)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(statusColor)
        }
    }

    private var statusColor: Color {
        switch file.parseStatus {
        case .parsing: return .orange
        case .ready: return .purple
        case .failed: return .red
        }
    }
}

struct AgentAttachmentPreviewPopover: View {
    let file: AgentFileAttachment
    let onToggleSection: (String) -> Void
    let onSetAllSections: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(file.relativePath)
                    .font(.headline)
                    .lineLimit(2)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let analysis = file.analysis {
                HStack(spacing: 8) {
                    if analysis.didUseOCR {
                        Label(L10n.Composer.attachmentOCRUsed, systemImage: "text.viewfinder")
                            .foregroundStyle(.blue)
                    }
                    if analysis.containsPotentialPromptInjection {
                        Label(L10n.Composer.attachmentInjectionWarning, systemImage: "shield.lefthalf.filled.badge.checkmark")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)

                HStack {
                    Button(L10n.Composer.selectAllAttachmentSections) {
                        onSetAllSections(true)
                    }
                    .focusable(false)

                    Button(L10n.Composer.selectNoAttachmentSections) {
                        onSetAllSections(false)
                    }
                    .focusable(false)

                    Spacer()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .focusable(false)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(analysis.sectionSummaries) { section in
                            sectionRow(section)
                        }
                    }
                }
                .frame(maxHeight: 360)
                .focusable(false)
            } else if file.parseStatus == .failed {
                Label(
                    L10n.Composer.attachmentParseFailed,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.red)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.Composer.attachmentParsing)
                        .font(.callout)
                }
            }
        }
        .padding(14)
        .frame(width: 440)
        .focusable(false)
    }

    private func sectionRow(_ section: AgentAttachmentSectionSummary) -> some View {
        let isIncluded = !file.excludedSectionIDs.contains(section.id)
        return Button {
            onToggleSection(section.id)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isIncluded ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isIncluded ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(displayTitle(for: section))
                            .font(.system(size: 12, weight: .semibold))
                        if section.wasRecognizedByOCR {
                            Image(systemName: "text.viewfinder")
                                .font(.system(size: 10))
                                .foregroundStyle(.blue)
                        }
                    }
                    Text(section.preview)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private var statusText: String {
        switch file.parseStatus {
        case .parsing:
            return L10n.Composer.attachmentParsing
        case .failed:
            return L10n.Composer.attachmentParseFailed
        case .ready:
            guard let analysis = file.analysis else { return L10n.Composer.attachmentParseFailed }
            return L10n.Composer.attachmentReady(
                analysis.sectionSummaries.count,
                analysis.extractedCharacterCount
            )
        }
    }

    private func displayTitle(for section: AgentAttachmentSectionSummary) -> String {
        switch section.kind {
        case .page:
            return L10n.Composer.attachmentPage(section.ordinal)
        case .sheet:
            return L10n.Composer.attachmentSheet(section.title)
        case .heading:
            return section.title
        case .chunk:
            return L10n.Composer.attachmentChunk(section.ordinal)
        }
    }
}
