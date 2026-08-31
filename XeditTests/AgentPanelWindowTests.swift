import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WillDeep

@Suite("工作标签窗口生命周期", .serialized)
@MainActor
struct AgentPanelWindowTests {
    private func fixture() -> (AppState, AgentRuntime) {
        var settings = EditorSettings.default
        settings.interfaceSkinID = EditorInterfaceSkin.system.id
        let state = AppState(editorSettings: settings, loadSessionCatalog: false)
        let runtime = AgentRuntime(session: AgentSession(title: "Panel fixture", workspaceRootPath: "/tmp"))
        state.agentRuntimes[runtime.id] = runtime
        state.agentSessions = [runtime.session]
        state.activeAgentSessionID = runtime.id
        return (state, runtime)
    }

    @Test("分离与收回移动同一个内容宿主")
    func retainsSurfaceAcrossWindowMove() throws {
        let (app, runtime) = fixture()
        let registry = AgentDetachedPanelRegistry.shared
        defer { registry.releaseSession(runtime.id) }
        let id = try #require(app.openPanelTab(.plan))
        let surface = registry.surface(for: id, appState: app, runtime: runtime, kind: .plan)
        registry.detach(id, appState: app)
        #expect(registry.windows[id]?.panelContent === surface)
        #expect(surface.window === registry.windows[id]?.window)
        registry.reattach(id, appState: app, reveal: false)
        #expect(registry.windows[id] == nil)
        #expect(registry.surface(for: id, appState: app, runtime: runtime, kind: .plan) === surface)
        #expect(runtime.sidePanelState.selectedTab?.id == id.tabID)
    }

    @Test("重复分离定位同一窗口，原生关闭不删标签")
    func duplicateDetachAndNativeClose() throws {
        let (app, runtime) = fixture()
        let registry = AgentDetachedPanelRegistry.shared
        defer { registry.releaseSession(runtime.id) }
        let id = try #require(app.openPanelTab(.plan))
        registry.detach(id, appState: app)
        let window = try #require(registry.windows[id]?.window)
        registry.detach(id, appState: app)
        #expect(registry.windows[id]?.window === window)
        window.close()
        #expect(!registry.hasWindow(sessionID: runtime.id))
        #expect(runtime.sidePanelState.openTabs.count == 1)
    }

    @Test("关闭标签不清空任务或终端控制器")
    func closingTabOnlyRemovesPresentation() throws {
        let (app, runtime) = fixture()
        let registry = AgentDetachedPanelRegistry.shared
        defer { registry.releaseSession(runtime.id) }
        let id = try #require(app.openPanelTab(.backgroundTasks))
        let terminal = app.agentTerminalController
        let jobs = app.agentJobRegistry.jobs.map(\.id)
        app.closePanelTab(id)
        #expect(runtime.sidePanelState.openTabs.isEmpty)
        #expect(app.agentTerminalController === terminal)
        #expect(app.agentJobRegistry.jobs.map(\.id) == jobs)
    }

    @Test("独立窗口上下文不跟随主会话改变")
    func scopeRemainsOwnedByOriginalSession() throws {
        let (app, owner) = fixture()
        defer { AgentDetachedPanelRegistry.shared.releaseSession(owner.id) }
        let id = try #require(app.openPanelTab(.preview, file: URL(fileURLWithPath: "/tmp/README.md")))
        let scope = AgentPanelScope(appState: app, runtime: owner, tabID: id.tabID)
        let other = AgentRuntime(session: AgentSession(title: "Other", workspaceRootPath: "/tmp/other"))
        app.agentRuntimes[other.id] = other
        app.activeAgentSessionID = other.id
        scope.input = "Only for original session"
        scope.selectedFile = URL(fileURLWithPath: "/tmp/notes.md")
        #expect(scope.workspaceRoot?.path == "/tmp")
        #expect(owner.input == "Only for original session")
        #expect(other.input.isEmpty)
        #expect(owner.sidePanelState.selectedTab?.title == "notes.md")
        #expect(other.sidePanelState == .empty)
    }

    @Test("同类型的不同会话窗口不会互相收回")
    func returningAllIsSessionScoped() throws {
        let (app, owner) = fixture()
        let other = AgentRuntime(session: AgentSession(title: "Other"))
        app.agentRuntimes[other.id] = other
        let registry = AgentDetachedPanelRegistry.shared
        defer { registry.releaseSession(owner.id); registry.releaseSession(other.id) }
        let first = try #require(app.openPanelTab(.plan, runtime: owner))
        let second = try #require(app.openPanelTab(.plan, runtime: other))
        registry.detach(first, appState: app)
        registry.detach(second, appState: app)
        #expect(registry.windows[first]?.window !== registry.windows[second]?.window)
        registry.reattachAll(sessionID: owner.id, appState: app)
        #expect(registry.windows[first] == nil)
        #expect(registry.windows[second] != nil)
    }

    @Test("后台窗口打开媒体任务时保留原会话筛选条件")
    func mediaRequestKeepsOwnerScope() throws {
        let (app, owner) = fixture()
        defer { AgentDetachedPanelRegistry.shared.releaseSession(owner.id) }
        let other = AgentRuntime(session: AgentSession(title: "Other"))
        app.agentRuntimes[other.id] = other
        app.activeAgentSessionID = other.id
        let scope = AgentPanelScope(appState: app, runtime: owner)
        let filter = AgentMediaTaskScope(label: "Fixture", projectID: "fixture-project")
        scope.request = AgentSidePanelOpenRequest(kind: .mediaTasks, mediaTaskScope: filter)
        #expect(owner.sidePanelState.mediaTaskScope == filter)
        #expect(owner.sidePanelState.selectedTab?.kind == .mediaTasks)
        #expect(other.sidePanelState == .empty)
    }

    @Test("原生多标签界面截图用于设计验收")
    func renderWorkspaceForDesignQA() async throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/visual-qa/panel-tabs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: output.path) else { return }
        let (app, runtime) = fixture()
        let registry = AgentDetachedPanelRegistry.shared
        defer { registry.releaseSession(runtime.id) }
        let terminal = try #require(app.openPanelTab(.terminal))
        app.openPanelTab(.backgroundTasks)
        let readmeURL = output.appendingPathComponent("README.md")
        let document = try #require(app.openPanelTab(.preview, file: readmeURL, exactFile: true))
        let review = try #require(app.openPanelTab(.diff))
        registry.detach(document, appState: app)
        registry.detach(review, appState: app)
        registry.windows[document]?.window?.appearance = NSAppearance(named: .aqua)
        registry.windows[review]?.window?.appearance = NSAppearance(named: .aqua)
        app.updatePanelTabs(runtime: runtime) { $0.selectTab(terminal.tabID) }
        let root = AgentPanelWorkspaceView(runtime: runtime, showsOverview: true, onHide: {})
            .environmentObject(app).preferredColorScheme(.light)
            .frame(width: 740, height: 1000)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 1000),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.title = "WillDeep — Panel QA"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        if ProcessInfo.processInfo.environment["WILLDEEP_PANEL_TABS_INTERACTIVE_QA"] == "1" {
            NSApp.activate(ignoringOtherApps: true)
        }
        defer { window.close(); app.agentTerminalController.closeTabs(openedBy: runtime.id) }
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        try capture(host, to: output.appendingPathComponent("workspace.png"))
        if let content = registry.windows[document]?.window?.contentView {
            content.layoutSubtreeIfNeeded()
            try capture(content, to: output.appendingPathComponent("document-window.png"))
        }
        if let popover = NSApp.windows.first(where: { NSStringFromClass(type(of: $0)).contains("Popover") }),
           let content = popover.contentView {
            try capture(content, to: output.appendingPathComponent("overview.png"))
        }
        if ProcessInfo.processInfo.environment["WILLDEEP_PANEL_TABS_INTERACTIVE_QA"] == "1" {
            try await Task.sleep(for: .seconds(60))
        }
    }

    private func capture(_ view: NSView, to url: URL) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url, options: .atomic)
    }
}
