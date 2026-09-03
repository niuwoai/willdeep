import AppKit
import Combine
import SwiftUI

/// Moving a retained hosting view preserves SwiftUI state and native views.
@MainActor
final class AgentDetachedPanelRegistry: ObservableObject {
    static let shared = AgentDetachedPanelRegistry()
    @Published private(set) var windows: [AgentPanelTabID: AgentPanelWindowController] = [:]
    private var surfaces: [AgentPanelTabID: NSHostingView<AgentPanelTabContent>] = [:]

    func isDetached(_ kind: AgentSidePanelKind) -> Bool { windows.values.contains { $0.kind == kind } }
    func isDetached(_ id: AgentPanelTabID, kind: AgentSidePanelKind) -> Bool { window(for: id, kind: kind) != nil }
    func hasWindow(sessionID: UUID) -> Bool { windows.keys.contains { $0.sessionID == sessionID } }

    private func window(for id: AgentPanelTabID, kind: AgentSidePanelKind) -> AgentPanelWindowController? {
        windows[id]
    }

    @discardableResult
    func focus(_ id: AgentPanelTabID, kind: AgentSidePanelKind) -> Bool {
        guard let controller = window(for: id, kind: kind) else { return false }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func surface(for id: AgentPanelTabID, appState: AppState, runtime: AgentRuntime,
                 kind: AgentSidePanelKind) -> NSView {
        let root = AgentPanelTabContent(appState: appState, runtime: runtime, tabID: id.tabID)
        if let view = surfaces[id] { return view }
        let view = NSHostingView(rootView: root)
        surfaces[id] = view
        return view
    }

    func detach(_ id: AgentPanelTabID, appState: AppState) {
        guard let runtime = appState.loadedRuntime(for: id.sessionID),
              let tab = runtime.sidePanelState.openTabs.first(where: { $0.id == id.tabID }) else { return }
        if focus(id, kind: tab.kind) { return }
        let content = surface(for: id, appState: appState, runtime: runtime, kind: tab.kind)
        content.removeFromSuperview()
        let controller = AgentPanelWindowController(id: id, tab: tab, appState: appState,
                                                    runtime: runtime, content: content, registry: self)
        windows[id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func reattach(_ id: AgentPanelTabID, appState: AppState, reveal: Bool = true) {
        guard let controller = windows.removeValue(forKey: id) else { return }
        controller.panelContent.removeFromSuperview()
        controller.close()
        guard let runtime = appState.loadedRuntime(for: id.sessionID) else { return }
        appState.updatePanelTabs(runtime: runtime) { $0.selectTab(id.tabID) }
        if reveal { _ = appState.selectAndRevealAgentSessionInSidebar(id: id.sessionID) }
    }

    func reattachAll(sessionID: UUID, appState: AppState) {
        for id in Array(windows.keys).filter({ $0.sessionID == sessionID }) {
            reattach(id, appState: appState, reveal: false)
        }
    }

    func windowClosed(_ id: AgentPanelTabID) {
        // Closing the native window returns its tab. Stopping a process is
        // still an explicit action inside the terminal or task manager.
        windows[id]?.panelContent.removeFromSuperview()
        windows.removeValue(forKey: id)
    }

    func closeTab(_ id: AgentPanelTabID) {
        if let controller = windows.removeValue(forKey: id) {
            controller.panelContent.removeFromSuperview()
            controller.close()
        }
        surfaces.removeValue(forKey: id)?.removeFromSuperview()
    }

    func releaseSession(_ sessionID: UUID) {
        let ids = Set(surfaces.keys.filter { $0.sessionID == sessionID })
            .union(windows.keys.filter { $0.sessionID == sessionID })
        for id in ids { closeTab(id) }
    }
}

@MainActor
final class AgentPanelWindowController: NSWindowController, NSWindowDelegate {
    let id: AgentPanelTabID
    let kind: AgentSidePanelKind
    let panelContent: NSView
    private weak var registry: AgentDetachedPanelRegistry?

    init(id: AgentPanelTabID, tab: AgentPanelTab, appState: AppState, runtime: AgentRuntime,
         content: NSView, registry: AgentDetachedPanelRegistry) {
        self.id = id
        kind = tab.kind
        panelContent = content
        self.registry = registry
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 320)
        window.title = [tab.title, runtime.workspaceRootPath.map { URL(fileURLWithPath: $0).lastPathComponent }]
            .compactMap { $0 }.joined(separator: " · ")
        window.identifier = NSUserInterfaceItemIdentifier("agent-panel-\(id.tabID)")
        window.delegate = self
        let root = NSView()
        let header = NSHostingView(rootView: AgentPanelWindowHeader(appState: appState, runtime: runtime, id: id))
        window.contentView = root
        for child in [header, content] { child.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(child) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor), header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor), header.heightAnchor.constraint(equalToConstant: 44),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: header.bottomAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        window.center()
    }

    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { registry?.windowClosed(id) }
}

private struct AgentPanelWindowHeader: View {
    @ObservedObject var appState: AppState
    @ObservedObject var runtime: AgentRuntime
    let id: AgentPanelTabID

    var body: some View {
        HStack(spacing: 8) {
            if let tab = runtime.sidePanelState.openTabs.first(where: { $0.id == id.tabID }) {
                Label(tab.title, systemImage: tab.systemImage)
                    .lineLimit(1)
                    .overlay { AgentPanelTabDragHandle(id: id, title: tab.title, onClick: {}, onDetach: {}) }
            }
            Spacer(minLength: 8)
            Button(L10n.PanelTabs.returnToDock) { AgentDetachedPanelRegistry.shared.reattach(id, appState: appState) }
                .controlSize(.small).focusable(false)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appState.editorSettings.interfaceSkin.palette.panelFill)
    }
}

struct AgentPanelDockSurface: NSViewRepresentable {
    let id: AgentPanelTabID
    let kind: AgentSidePanelKind
    let appState: AppState
    let runtime: AgentRuntime

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ container: NSView, context: Context) {
        let registry = AgentDetachedPanelRegistry.shared
        guard !registry.isDetached(id, kind: kind) else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        let content = registry.surface(for: id, appState: appState, runtime: runtime, kind: kind)
        guard content.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        content.removeFromSuperview()
        content.translatesAutoresizingMaskIntoConstraints = true
        content.frame = container.bounds
        content.autoresizingMask = [.width, .height]
        container.addSubview(content)
    }
}
