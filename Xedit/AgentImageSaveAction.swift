//
//  AgentImageSaveAction.swift
//  WillDeep
//
//  "Save As…" for images the transcript shows: the preview window's toolbar
//  button and the transcript's "Save Image…" context-menu item. The file is
//  copied byte-for-byte (no re-encode), under its original name by default.
//

import AppKit
import Foundation
import OSLog
import UniformTypeIdentifiers

/// What is being saved: a message image (file-backed or inline bytes), or a
/// local file a Markdown `![](path)` line pointed at.
final class AgentImageSaveSource: NSObject {
    enum Content {
        case attachment(AgentImageAttachment)
        case file(URL)
    }

    let content: Content

    init(_ content: Content) {
        self.content = content
    }

    var suggestedFileName: String {
        switch content {
        case .file(let url):
            return url.lastPathComponent
        case .attachment(let image):
            if let fileURL = image.fileURL, !fileURL.lastPathComponent.isEmpty {
                return fileURL.lastPathComponent
            }
            let ext = UTType(mimeType: image.mimeType)?.preferredFilenameExtension
                ?? AgentImageSaveAction.fallbackExtension
            return "\(AgentImageSaveAction.fallbackBaseName).\(ext)"
        }
    }
}

enum AgentImageSaveError: LocalizedError {
    case noImageData

    var errorDescription: String? {
        switch self {
        case .noImageData: return L10n.ImageSave.noImageData
        }
    }
}

@MainActor
enum AgentImageSaveAction {
    static let fallbackBaseName = "image"
    static let fallbackExtension = "png"
    private static let logger = Logger(subsystem: "com.willdeep.app", category: "image-save")

    /// Presents the save panel (as a sheet when there is a window) and writes
    /// the image to the chosen location. Failures surface as an alert.
    static func presentSavePanel(for source: AgentImageSaveSource, in window: NSWindow?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.suggestedFileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let window {
            panel.beginSheetModal(for: window) { response in
                finishSave(response: response, panel: panel, source: source, window: window)
            }
        } else {
            finishSave(response: panel.runModal(), panel: panel, source: source, window: nil)
        }
    }

    private static func finishSave(
        response: NSApplication.ModalResponse,
        panel: NSSavePanel,
        source: AgentImageSaveSource,
        window: NSWindow?
    ) {
        guard response == .OK, let destination = panel.url else { return }
        do {
            try write(source, to: destination)
        } catch {
            logger.error("Saving an image failed: \(error.localizedDescription, privacy: .public)")
            presentFailure(error, in: window)
        }
    }

    /// Copies the image to `destination`, replacing what is there — the save
    /// panel has already asked the user about overwriting.
    static func write(_ source: AgentImageSaveSource, to destination: URL) throws {
        let fileManager = FileManager.default
        let fileURL: URL?
        let data: Data?
        switch source.content {
        case .file(let url):
            fileURL = url
            data = nil
        case .attachment(let image):
            if let url = image.fileURL, fileManager.fileExists(atPath: url.path) {
                fileURL = url
                data = nil
            } else {
                fileURL = nil
                data = image.inlineImageData
            }
        }
        if let fileURL, fileURL.standardizedFileURL == destination.standardizedFileURL {
            return
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        if let fileURL {
            try fileManager.copyItem(at: fileURL, to: destination)
        } else if let data, !data.isEmpty {
            try data.write(to: destination, options: .atomic)
        } else {
            throw AgentImageSaveError.noImageData
        }
    }

    private static func presentFailure(_ error: Error, in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.ImageSave.failedTitle
        alert.informativeText = error.localizedDescription
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: Transcript context menu

    /// "Save Image…" for the image under `point` in a transcript text view:
    /// a message image (looked up by its id) or a Markdown image file.
    static func menuItem(
        in textView: NSTextView,
        at point: NSPoint,
        action: Selector,
        imageLookup: (UUID) -> AgentImageAttachment?
    ) -> NSMenuItem? {
        guard let source = saveSource(in: textView, at: point, imageLookup: imageLookup) else { return nil }
        let item = NSMenuItem(title: L10n.ImageSave.saveImageAction, action: action, keyEquivalent: "")
        item.target = textView
        item.representedObject = source
        return item
    }

    static func saveSource(
        in textView: NSTextView,
        at point: NSPoint,
        imageLookup: (UUID) -> AgentImageAttachment?
    ) -> AgentImageSaveSource? {
        guard let storage = textView.textStorage,
              let characterIndex = attachmentCharacterIndex(in: textView, at: point) else {
            return nil
        }
        if let rawID = storage.attribute(.agentChatHistoryImageID, at: characterIndex, effectiveRange: nil) as? String,
           let id = UUID(uuidString: rawID),
           let image = imageLookup(id) {
            return AgentImageSaveSource(.attachment(image))
        }
        // Markdown `![](path)` pictures carry their file URL as the link.
        if let url = storage.attribute(.link, at: characterIndex, effectiveRange: nil) as? URL,
           url.isFileURL,
           storage.attribute(.attachment, at: characterIndex, effectiveRange: nil) != nil,
           let type = UTType(filenameExtension: url.pathExtension),
           type.conforms(to: .image) {
            return AgentImageSaveSource(.file(url))
        }
        return nil
    }

    /// Character under `point` if it is an attachment whose glyph actually
    /// contains the point (not merely the nearest glyph on the line).
    private static func attachmentCharacterIndex(in textView: NSTextView, at point: NSPoint) -> Int? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let storage = textView.textStorage,
              storage.length > 0 else {
            return nil
        }
        let origin = textView.textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        layoutManager.ensureLayout(for: textContainer)
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        guard glyphRect.contains(containerPoint) else { return nil }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < storage.length,
              storage.attribute(.attachment, at: characterIndex, effectiveRange: nil) != nil else {
            return nil
        }
        return characterIndex
    }
}

extension AgentChatHistoryNSTextView {
    @objc func saveTranscriptImageFromMenu(_ sender: NSMenuItem) {
        guard let source = sender.representedObject as? AgentImageSaveSource else { return }
        AgentImageSaveAction.presentSavePanel(for: source, in: window)
    }
}
