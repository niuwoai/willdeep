//
//  AgentAttachmentCitation.swift
//  WillDeep
//
//  Clickable, precise citations from assistant answers back to locally parsed
//  conversation documents.
//

import AppKit
import SwiftUI

nonisolated final class AgentAttachmentCitationPayload: NSObject {
    let relativePath: String
    let sourceReference: String

    init(relativePath: String, sourceReference: String) {
        self.relativePath = relativePath
        self.sourceReference = sourceReference
    }

    var identity: String {
        relativePath + "\u{1f}" + sourceReference
    }
}

nonisolated enum AgentAttachmentCitationResolver {
    static func matchingFile(
        relativePath: String,
        in documents: [AgentFileAttachment]
    ) -> AgentFileAttachment? {
        documents.first(where: {
            $0.relativePath == relativePath
                || $0.url.path == relativePath
                || $0.url.lastPathComponent == relativePath
        })
    }

    static func matchingSection(
        sourceReference: String,
        in file: AgentFileAttachment
    ) -> AgentAttachmentSection? {
        guard let sections = file.analysis?.loadedSections() else { return nil }
        if let exact = sections.first(where: { $0.sourceReference == sourceReference }) {
            return exact
        }
        guard let requestedRange = lineRange(from: sourceReference) else { return nil }

        for section in sections {
            guard let sectionRange = lineRange(from: section.sourceReference),
                  sectionRange.lowerBound <= requestedRange.lowerBound,
                  sectionRange.upperBound >= requestedRange.upperBound else {
                continue
            }
            let lines = section.text.components(separatedBy: .newlines)
            let start = requestedRange.lowerBound - sectionRange.lowerBound
            let end = requestedRange.upperBound - sectionRange.lowerBound
            guard start >= 0, end >= start, end < lines.count else { continue }
            return AgentAttachmentSection(
                id: "\(section.id)-citation-\(requestedRange.lowerBound)-\(requestedRange.upperBound)",
                kind: section.kind,
                ordinal: section.ordinal,
                title: section.title,
                sourceReference: sourceReference,
                text: lines[start...end].joined(separator: "\n"),
                wasRecognizedByOCR: section.wasRecognizedByOCR
            )
        }
        return nil
    }

    private static func lineRange(from sourceReference: String) -> ClosedRange<Int>? {
        guard sourceReference.hasPrefix("lines=") else { return nil }
        let values = sourceReference.dropFirst("lines=".count).split(separator: "-", maxSplits: 1)
        guard values.count == 2,
              let lower = Int(values[0]),
              let upper = Int(values[1]),
              lower > 0,
              upper >= lower else {
            return nil
        }
        return lower...upper
    }
}

@MainActor
final class AgentAttachmentCitationWindowRegistry {
    static let shared = AgentAttachmentCitationWindowRegistry()

    private var windows: [String: NSWindowController] = [:]
    private var closeObservers: [String: NSObjectProtocol] = [:]

    func open(file: AgentFileAttachment, section: AgentAttachmentSection) {
        let key = file.id + "\u{1f}" + section.sourceReference
        if let existing = windows[key] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let content = AgentAttachmentCitationReaderView(file: file, section: section)
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.AttachmentCitation.windowTitle
        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        windows[key] = controller
        // Keep the token: block-based observers are retained by
        // NotificationCenter until removeObserver, so dropping it leaks
        // one registration per opened reader window.
        closeObservers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard window != nil else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.windows.removeValue(forKey: key)
                if let token = self.closeObservers.removeValue(forKey: key) {
                    NotificationCenter.default.removeObserver(token)
                }
            }
        }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct AgentAttachmentCitationReaderView: View {
    let file: AgentFileAttachment
    let section: AgentAttachmentSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(file.relativePath)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Label(section.sourceReference, systemImage: sourceSymbol)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())

                    if section.wasRecognizedByOCR {
                        Label(L10n.Composer.attachmentOCRUsed, systemImage: "text.viewfinder")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }

                    Spacer()

                    Button(L10n.AttachmentCitation.exportAction) {
                        AgentDocumentExportService.presentExport(file: file, section: section)
                    }

                    Button(L10n.AttachmentCitation.openOriginal) {
                        NSWorkspace.shared.open(file.url)
                    }

                    Button(L10n.AttachmentCitation.showInFinder) {
                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    }
                }
            }
            .padding(16)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.AttachmentCitation.highlightedSource)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(section.text)
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.yellow.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.yellow.opacity(0.42), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .padding(16)
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    private var sourceSymbol: String {
        switch section.kind {
        case .page: return "doc.richtext"
        case .sheet: return "tablecells"
        case .heading: return "textformat"
        case .chunk: return "text.alignleft"
        }
    }
}

extension AppState {
    func openAgentAttachmentCitation(_ payload: AgentAttachmentCitationPayload) {
        let documents = agentPendingFiles
            + agentSessionDocuments
            + agentKnowledgeFolders.flatMap(\.documents)
        guard let file = AgentAttachmentCitationResolver.matchingFile(
            relativePath: payload.relativePath,
            in: documents
        ) else {
            revealAgentReferencedPath(payload.relativePath)
            return
        }
        guard let section = AgentAttachmentCitationResolver.matchingSection(
            sourceReference: payload.sourceReference,
            in: file
        ) else {
            revealInFinder(file.url)
            return
        }
        AgentAttachmentCitationWindowRegistry.shared.open(file: file, section: section)
    }
}
