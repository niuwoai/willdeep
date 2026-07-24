//
//  RoundtableDocumentExporter.swift
//  WillDeep
//
//  把圆桌终稿文档导出为 .md。照 AgentDocumentExportService 的 NSSavePanel
//  样板,但专用于圆桌(无附件依赖),直接写 markdown。无模型/网络调用。
//

import AppKit
import UniformTypeIdentifiers

@MainActor
enum RoundtableDocumentExporter {
    static func export(title: String, markdown: String) {
        let panel = NSSavePanel()
        panel.title = L10n.Roundtable.exportAction
        panel.nameFieldStringValue = suggestedFilename(title: title)
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            .plainText,
        ]
        panel.canCreateDirectories = true

        let body = "# \(title)\n\n\(markdown)\n"
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try body.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                presentError(error)
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private static func suggestedFilename(title: String) -> String {
        let base = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = base.isEmpty ? "roundtable" : base
        // 去掉路径分隔符等非法字符。
        let cleaned = sanitized.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
        return "\(String(cleaned.prefix(60))).md"
    }

    private static func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
