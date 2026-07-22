//
//  AgentArtifactFileActions.swift
//  WillDeep
//
//  Shared file actions for generated artifacts shown in Agent side panels.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentArtifactOpenWithApplication: Identifiable, Hashable {
    let url: URL

    var id: String { url.path }

    var displayName: String {
        Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}

enum AgentArtifactFileActions {
    private static let textFileExtensions: Set<String> = [
        "bash", "c", "cc", "conf", "cpp", "css", "csv", "env", "go",
        "h", "hpp", "htm", "html", "ini", "java", "js", "json", "jsonl",
        "jsx", "log", "m", "md", "markdown", "mm", "plist", "rb", "rs",
        "sh", "sql", "swift", "toml", "ts", "tsx", "txt", "xml", "yaml",
        "yml", "zsh"
    ]

    static func openDefault(_ fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(fileURL)
    }

    static func openInFinder(_ fileURL: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            NSSound.beep()
            return
        }
        if isDirectory.boolValue {
            NSWorkspace.shared.open(fileURL)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    static func revealInFinder(_ fileURL: URL) {
        openInFinder(fileURL)
    }

    static func open(_ fileURL: URL, with applicationURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            NSSound.beep()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([fileURL], withApplicationAt: applicationURL, configuration: configuration) { _, error in
            if error != nil {
                NSSound.beep()
            }
        }
    }

    static func chooseApplicationAndOpen(_ fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            NSSound.beep()
            return
        }
        let panel = NSOpenPanel()
        panel.title = "选择用于打开产物的 App"
        panel.message = fileURL.lastPathComponent
        panel.prompt = "打开"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let applicationURL = panel.url else { return }
            open(fileURL, with: applicationURL)
        }
    }

    static func openWithApplications(for fileURL: URL) -> [AgentArtifactOpenWithApplication] {
        NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
            .map(AgentArtifactOpenWithApplication.init(url:))
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    static func isTextFile(_ fileURL: URL) -> Bool {
        let pathExtension = fileURL.pathExtension.lowercased()
        if textFileExtensions.contains(pathExtension) {
            return true
        }
        if let type = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .text) ||
                type.conforms(to: .utf8PlainText) ||
                type.conforms(to: .sourceCode) ||
                type.conforms(to: .json) ||
                type.conforms(to: .xml)
        }
        return false
    }

    static func isSidePanelPreviewCandidate(_ fileURL: URL) -> Bool {
        isTextFile(fileURL)
    }
}

struct AgentArtifactFileContextMenu: View {
    @EnvironmentObject private var appState: AppState
    let fileURL: URL

    var body: some View {
        Button {
            AgentArtifactFileActions.openDefault(fileURL)
        } label: {
            Label("用默认 App 打开", systemImage: "arrow.up.right.square")
        }

        if AgentArtifactFileActions.isTextFile(fileURL) {
            Button {
                appState.openAgentReferencedFile(fileURL.path)
            } label: {
                Label("用内置编辑器打开", systemImage: "doc.text")
            }
        }

        if AgentArtifactFileActions.isSidePanelPreviewCandidate(fileURL) {
            Button {
                appState.previewAgentArtifactFileInSidePanel(fileURL)
            } label: {
                Label("在侧边栏预览", systemImage: "sidebar.right")
            }
        }

        Menu {
            ForEach(AgentArtifactFileActions.openWithApplications(for: fileURL)) { application in
                Button {
                    AgentArtifactFileActions.open(fileURL, with: application.url)
                } label: {
                    Label {
                        Text(application.displayName)
                    } icon: {
                        Image(nsImage: application.icon)
                    }
                }
            }

            Divider()

            Button {
                AgentArtifactFileActions.chooseApplicationAndOpen(fileURL)
            } label: {
                Label("其他 App…", systemImage: "ellipsis.circle")
            }
        } label: {
            Label("打开方式", systemImage: "square.grid.2x2")
        }

        Divider()

        Button {
            AgentArtifactFileActions.revealInFinder(fileURL)
        } label: {
            Label("在 Finder 中显示", systemImage: "finder")
        }
    }
}
