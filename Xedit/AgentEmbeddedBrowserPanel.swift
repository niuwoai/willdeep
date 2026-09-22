//
//  AgentEmbeddedBrowserPanel.swift
//  WillDeep
//
//  SwiftUI side-panel chrome around the embedded browser's WKWebView, plus
//  the AppKit host that hands the single web view between panels. Split out
//  of AgentEmbeddedBrowser.swift, which had grown past 2,000 lines.
//

import AppKit
import SwiftUI
import WebKit

struct AgentEmbeddedBrowserPanel: View {
    @ObservedObject private var controller: AgentEmbeddedBrowserController
    @State private var screenshotError: String?
    @State private var isChromeImportPresented = false
    let width: CGFloat

    private let runtimeID: UUID?
    private let tabID: UUID?

    init(runtimeID: UUID? = nil, tabID: UUID? = nil, width: CGFloat) {
        self.width = width
        self.runtimeID = runtimeID
        self.tabID = tabID
        _controller = ObservedObject(
            wrappedValue: AgentEmbeddedBrowserController.controller(for: runtimeID, tabID: tabID)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            AgentEmbeddedBrowserWebView(controller: controller, webViewGeneration: controller.webViewGeneration)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: width)
        .focusable(false)
        .onAppear {
            if let runtimeID, let tabID {
                AgentEmbeddedBrowserController.activate(tabID: tabID, for: runtimeID)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button {
                controller.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(!controller.canGoBack)
            .help(L10n.AgentEmbeddedBrowser.back)

            Button {
                controller.goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(!controller.canGoForward)
            .help(L10n.AgentEmbeddedBrowser.forward)

            Button {
                controller.reload()
            } label: {
                Image(systemName: controller.isLoading ? "xmark" : "arrow.clockwise")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.AgentEmbeddedBrowser.reload)

            TextField(L10n.AgentEmbeddedBrowser.addressPlaceholder, text: $controller.address)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit {
                    loadAddress()
                }

            Button {
                loadAddress()
            } label: {
                Image(systemName: "arrow.forward")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.AgentEmbeddedBrowser.go)

            Button {
                controller.switchProfile(to: isIsolated ? .personal : .isolated, runtimeID: runtimeID)
            } label: {
                Image(systemName: isIsolated ? "person.crop.circle.badge.xmark" : "person.crop.circle")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(isIsolated ? L10n.AgentEmbeddedBrowser.profileIsolated : L10n.AgentEmbeddedBrowser.profilePersonal)
            
            Button {
                isChromeImportPresented = true
            } label: {
                Image(systemName: "person.crop.circle.badge.plus")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .focusable(false)
            // Importing sign-ins into the isolated store would defeat its point.
            .disabled(isIsolated)
            .help(isIsolated ? L10n.AgentEmbeddedBrowser.importChromeIsolated : L10n.AgentEmbeddedBrowser.importChrome)

            Button {
                captureScreenshot()
            } label: {
                Image(systemName: "camera")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help(L10n.AgentEmbeddedBrowser.capture)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .sheet(isPresented: $isChromeImportPresented) {
            ChromeCookieImportSheet(controller: controller)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isIsolated {
                    Text(L10n.AgentEmbeddedBrowser.profileIsolatedBadge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
                }
                Text(controller.title.isEmpty ? L10n.AgentEmbeddedBrowser.untitled : controller.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(footerDetail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var isIsolated: Bool { controller.profile == .isolated }

    private var footerDetail: String {
        if let screenshotError {
            return screenshotError
        }
        if let path = controller.lastScreenshotPath {
            return L10n.AgentEmbeddedBrowser.lastScreenshot(path)
        }
        if let lastError = controller.lastError {
            return lastError
        }
        return controller.currentURL.isEmpty ? L10n.AgentEmbeddedBrowser.ready : controller.currentURL
    }

    private func loadAddress() {
        screenshotError = nil
        do {
            try controller.navigate(to: controller.address)
        } catch {
            screenshotError = error.localizedDescription
        }
    }

    private func captureScreenshot() {
        screenshotError = nil
        Task {
            do {
                _ = try await controller.captureScreenshot()
            } catch {
                screenshotError = error.localizedDescription
            }
        }
    }
}

private struct AgentEmbeddedBrowserWebView: NSViewRepresentable {
    let controller: AgentEmbeddedBrowserController
    /// Only read so SwiftUI sees a changed field and calls `updateNSView`
    /// after the controller rebuilds its web view.
    let webViewGeneration: Int

    func makeNSView(context: Context) -> AgentEmbeddedBrowserHostView {
        let host = AgentEmbeddedBrowserHostView()
        host.attach(controller.ensureWebView())
        return host
    }

    func updateNSView(_ host: AgentEmbeddedBrowserHostView, context: Context) {
        host.attach(controller.ensureWebView())
    }

    static func dismantleNSView(_ host: AgentEmbeddedBrowserHostView, coordinator: ()) {
        host.detach()
    }
}

/// Hosts the controller's single `WKWebView`. There is exactly one per
/// controller, so hosts hand it between themselves rather than each owning
/// one — and the handover is what makes teardown order matter.
final class AgentEmbeddedBrowserHostView: NSView {
    private weak var hostedWebView: WKWebView?

    func attach(_ webView: WKWebView) {
        guard hostedWebView !== webView || webView.superview !== self else { return }
        hostedWebView?.removeFromSuperview()
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
        hostedWebView = webView
    }

    /// Give up the web view only if it is still ours.
    ///
    /// Detaching a panel into its own window tears the sidebar host down
    /// *after* the window's host has already taken the web view: SwiftUI
    /// clears the sidebar's `kind` and opens the window, but the dismantle
    /// arrives later. An unconditional `removeFromSuperview()` here then
    /// reached into the new window and pulled the web view back out of it,
    /// leaving the detached panel blank — and since the view was no longer in
    /// any hierarchy, typing an address still navigated, just nowhere visible.
    func detach() {
        if hostedWebView?.superview === self {
            hostedWebView?.removeFromSuperview()
        }
        hostedWebView = nil
    }
}
