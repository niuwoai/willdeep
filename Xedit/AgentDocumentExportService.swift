//
//  AgentDocumentExportService.swift
//  WillDeep
//
//  Local export for selected document evidence. No model or network call.
//

import AppKit
import CoreText
import UniformTypeIdentifiers

@MainActor
enum AgentDocumentExportService {
    static func presentExport(file: AgentFileAttachment, section: AgentAttachmentSection) {
        let panel = NSSavePanel()
        panel.title = L10n.AttachmentCitation.exportTitle
        panel.nameFieldStringValue = suggestedFilename(file: file, section: section)
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            .plainText,
            .pdf,
            UTType(filenameExtension: "docx") ?? .data,
        ]
        panel.canCreateDirectories = true

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    try await export(file: file, section: section, to: url)
                } catch {
                    presentError(error)
                }
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    static func export(
        file: AgentFileAttachment,
        section: AgentAttachmentSection,
        to url: URL
    ) async throws {
        let markdown = """
        # \(file.relativePath)

        **Source:** `\(section.sourceReference)`

        \(section.text)
        """
        switch url.pathExtension.lowercased() {
        case "pdf":
            try writePDF(markdown, to: url)
        case "docx":
            try await writeDOCX(markdown, to: url)
        case "txt":
            try section.text.write(to: url, atomically: true, encoding: .utf8)
        default:
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func writePDF(_ text: String, to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var location = 0
        while location < attributed.length {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: mediaBox.height)
            context.scaleBy(x: 1, y: -1)
            let path = CGPath(rect: mediaBox.insetBy(dx: 48, dy: 52), transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.restoreGState()
            context.endPDFPage()
            guard visible.length > 0 else { break }
            location += visible.length
        }
        context.closePDF()
    }

    private static func writeDOCX(_ text: String, to url: URL) async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_export_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let rtfURL = temporaryDirectory.appendingPathComponent("source.rtf")
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        )
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        try data.write(to: rtfURL, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "docx", "-output", url.path, rtfURL.path]
        let output = try await AgentSubprocess.run(
            process,
            timeout: 60,
            stdoutLimit: 64 * 1_024,
            stderrLimit: 64 * 1_024
        )
        guard output.exitStatus == 0, !output.timedOut else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func suggestedFilename(
        file: AgentFileAttachment,
        section: AgentAttachmentSection
    ) -> String {
        let base = file.url.deletingPathExtension().lastPathComponent
        let locator = section.sourceReference
            .replacingOccurrences(of: "=", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return "\(base)-\(locator).md"
    }

    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.AttachmentCitation.exportFailed
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
