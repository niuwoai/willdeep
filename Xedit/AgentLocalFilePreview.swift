import AppKit
import SwiftUI
import WebKit

nonisolated enum AgentLocalFilePreview {
    static let maximumHTMLBytes = 1024 * 1024

    static func supportsHTML(_ url: URL) -> Bool {
        ["html", "htm"].contains(url.pathExtension.lowercased())
    }

    static func fileURL(path: String, repositoryRoot: URL) -> URL? {
        let root = repositoryRoot.standardizedFileURL
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        return file
    }

    enum Result: Equatable {
        case html(String)
        case unavailable(String)
    }

    static func loadHTML(at url: URL) -> Result {
        guard supportsHTML(url) else { return .unavailable(L10n.AgentSidePanel.previewUnsupported) }
        let file = URL(fileURLWithPath: url.path)
        do {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                return .unavailable(L10n.FilePreview.unreadable)
            }
            guard let size = values.fileSize, size <= maximumHTMLBytes else {
                return .unavailable(L10n.FilePreview.htmlTooLarge)
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumHTMLBytes + 1) ?? Data()
            guard data.count <= maximumHTMLBytes else { return .unavailable(L10n.FilePreview.htmlTooLarge) }
            guard !data.contains(0), let html = String(data: data, encoding: .utf8) else {
                return .unavailable(L10n.FilePreview.invalidText)
            }
            return .html(html)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// Keep the document's own layout and inline scripts, with no host bridge or network access.
    static func sandboxedHTML(_ html: String) -> String {
        let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline' file:; style-src 'unsafe-inline' file:; img-src data: blob: file:; font-src data: file:; media-src data: blob: file:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'\">"
        // A known doctype keeps standards mode. Prefixing the policy makes it
        // effective even when the source contains a commented-out <head>.
        return "<!doctype html>" + policy + html
    }
}

struct AgentFilePreviewUnavailableView: View {
    let fileURL: URL
    let reason: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 52, height: 52)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fileURL.lastPathComponent)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text(L10n.FilePreview.unavailable)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.FilePreview.location)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(fileURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actions }
                    VStack(alignment: .leading, spacing: 10) { actions }
                }
            }
            .padding(22)
            .frame(maxWidth: 460, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var actions: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } label: {
            Label(L10n.Plugins.openInFinder, systemImage: "folder")
        }
        .buttonStyle(.borderedProminent)
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fileURL.path, forType: .string)
        } label: {
            Label(L10n.ComposerWorkspace.copyPath, systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
    }
}

struct AgentHTMLFilePreviewView: View {
    let fileURL: URL
    var revision: String = ""
    @State private var result: AgentLocalFilePreview.Result?
    @State private var renderingError: String?

    var body: some View {
        Group {
            if let renderingError {
                AgentFilePreviewUnavailableView(fileURL: fileURL, reason: renderingError)
            } else if let result {
                switch result {
                case .html(let html):
                    AgentLocalHTMLWebView(html: html, fileURL: fileURL) { renderingError = $0 }
                case .unavailable(let reason):
                    AgentFilePreviewUnavailableView(fileURL: fileURL, reason: reason)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: fileURL.path + "|" + revision) {
            result = nil
            renderingError = nil
            let loaded = await Task.detached(priority: .userInitiated) {
                AgentLocalFilePreview.loadHTML(at: fileURL)
            }.value
            guard !Task.isCancelled else { return }
            result = loaded
        }
    }
}

private struct AgentLocalHTMLWebView: NSViewRepresentable {
    let html: String
    let fileURL: URL
    let onFailure: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onFailure = onFailure
        guard context.coordinator.fileURL != fileURL || context.coordinator.html != html else { return }
        context.coordinator.fileURL = fileURL
        context.coordinator.html = html
        view.loadHTMLString(AgentLocalFilePreview.sandboxedHTML(html), baseURL: fileURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var fileURL: URL?
        var html: String?
        var onFailure: (String) -> Void
        init(onFailure: @escaping (String) -> Void) { self.onFailure = onFailure }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            let isDocument = url?.scheme == "about"
                || (url?.isFileURL == true && url?.standardizedFileURL.path == fileURL?.standardizedFileURL.path)
            decisionHandler(isDocument ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onFailure(L10n.FilePreview.renderFailed)
        }

        private func report(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            onFailure(error.localizedDescription)
        }
    }
}
