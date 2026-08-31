import SwiftUI
import UniformTypeIdentifiers

struct AgentPanelWorkspaceView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var runtime: AgentRuntime
    @ObservedObject private var registry = AgentDetachedPanelRegistry.shared
    @State private var showsOverview = false
    let onHide: () -> Void

    init(runtime: AgentRuntime, showsOverview: Bool = false, onHide: @escaping () -> Void) {
        self.runtime = runtime
        self.onHide = onHide
        _showsOverview = State(initialValue: showsOverview)
    }

    private var tabs: [AgentPanelTab] { runtime.sidePanelState.openTabs }
    private var selected: AgentPanelTab? { runtime.sidePanelState.selectedTab }
    private var palette: EditorInterfaceSkinPalette { appState.editorSettings.interfaceSkin.palette }
    private func id(_ tab: AgentPanelTab) -> AgentPanelTabID { .init(sessionID: runtime.id, tabID: tab.id) }
    private func isDetached(_ tab: AgentPanelTab) -> Bool { registry.isDetached(id(tab), kind: tab.kind) }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabStrip
            Divider()
            if let selected {
                contentHeader(selected)
                Divider().opacity(0.6)
                if isDetached(selected) { detachedPlaceholder(selected) }
                else {
                    AgentPanelDockSurface(id: id(selected), kind: selected.kind, appState: appState, runtime: runtime)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text(L10n.PanelTabs.empty).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if selected?.kind == .terminal || selected?.kind == .backgroundTasks {
                Divider().opacity(0.5)
                Label(L10n.PanelTabs.keepsRunning, systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 7)
            }
        }
        .background(palette.panelFill)
        .focusable(false)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(L10n.PanelTabs.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                ForEach(AgentSidePanelKind.allCases.filter { $0.isAvailable(activeExperts: runtime.activeExperts) }) { kind in
                    Button { appState.openPanelTab(kind, runtime: runtime) } label: { Label(kind.title, systemImage: kind.systemImage) }
                }
            } label: { Image(systemName: "plus").frame(width: 22, height: 24) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().focusable(false)
            .help(L10n.PanelTabs.add)
            Button { showsOverview.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.grid.2x2")
                    Text(L10n.PanelTabs.all).lineLimit(1)
                    Text(tabs.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 5)
                .background(palette.controlFill, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain).focusable(false)
            .popover(isPresented: $showsOverview, arrowEdge: .bottom) { overview }
            Button(action: onHide) { Image(systemName: "xmark").frame(width: 22, height: 24) }
                .buttonStyle(.plain).focusable(false).help(L10n.AgentSidePanel.close)
        }
        .padding(.horizontal, 12).frame(height: 44)
    }

    private var tabStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(tabs) { tab in tabChip(tab).id(tab.id) }
                }.padding(.horizontal, 5)
            }
            .frame(height: 36)
            .onCompatibleChange(of: selected?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .onDrop(of: [.willDeepPanelTab], isTargeted: nil) { receiveDrop($0, before: nil) }
    }

    private func tabChip(_ tab: AgentPanelTab) -> some View {
        let active = selected?.id == tab.id && !isDetached(tab)
        return HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: tab.systemImage)
                Text(tab.title).lineLimit(1).truncationMode(.middle)
                if tab.kind == .backgroundTasks {
                    let count = appState.agentJobRegistry.jobs.filter { $0.runtimeID == runtime.id && $0.isAlive }.count
                    if count > 0 { Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit() }
                }
                if isDetached(tab) { Image(systemName: "arrow.up.right").foregroundStyle(.secondary) }
            }
            .padding(.leading, 10).padding(.vertical, 9)
            .overlay {
                AgentPanelTabDragHandle(id: id(tab), title: tab.title,
                                        onClick: { select(tab) }, onDetach: { detach(tab) })
            }
            Button { appState.closePanelTab(id(tab)) } label: {
                Image(systemName: "xmark").font(.system(size: 9)).frame(width: 18, height: 26)
            }
            .buttonStyle(.plain).focusable(false).foregroundStyle(.secondary).help(L10n.PanelTabs.closeTab)
        }
        .font(.system(size: 11, weight: active ? .semibold : .regular))
        .frame(maxWidth: 220).frame(height: 35)
        .background(active ? palette.panelFill : palette.controlFill.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(palette.hairline.opacity(0.7), lineWidth: 0.5))
        .overlay(alignment: .bottom) { if active { Rectangle().fill(Color.accentColor).frame(height: 2) } }
        .help(tab.file?.path ?? tab.title)
        .contextMenu {
            Button(L10n.AgentSidePanel.detach) { detach(tab) }
            if isDetached(tab) { Button(L10n.PanelTabs.returnToDock) { registry.reattach(id(tab), appState: appState) } }
            Divider()
            Button(L10n.PanelTabs.closeTab) { appState.closePanelTab(id(tab)) }
        }
        .onDrop(of: [.willDeepPanelTab], isTargeted: nil) { receiveDrop($0, before: tab.id) }
    }

    private func contentHeader(_ tab: AgentPanelTab) -> some View {
        HStack(spacing: 6) {
            Label(tab.title, systemImage: tab.systemImage).lineLimit(1)
            if let path = runtime.workspaceRootPath {
                Text("· " + URL(fileURLWithPath: path).lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { detach(tab) } label: { Image(systemName: "macwindow.on.rectangle").frame(width: 24, height: 24) }
                .buttonStyle(.plain).focusable(false).help(L10n.AgentSidePanel.detach)
        }
        .font(.system(size: 11)).padding(.horizontal, 12).frame(height: 34)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.PanelTabs.openTabs).font(.system(size: 11)).foregroundStyle(.secondary).padding(14)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(tabs) { tab in
                        Button { select(tab); showsOverview = false } label: {
                            HStack(spacing: 9) {
                                Image(systemName: tab.systemImage).frame(width: 18)
                                Text(tab.title).lineLimit(1)
                                Spacer(minLength: 12)
                                Text(isDetached(tab) ? L10n.PanelTabs.window : L10n.PanelTabs.dock)
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                if isDetached(tab) { Image(systemName: "arrow.up.right").font(.system(size: 10)) }
                            }
                            .font(.system(size: 12)).padding(.horizontal, 12).frame(height: 34)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).focusable(false)
                    }
                }
            }.frame(height: min(CGFloat(tabs.count) * 36, 300))
            Divider().padding(.top, 6)
            Button {
                registry.reattachAll(sessionID: runtime.id, appState: appState)
                showsOverview = false
            } label: { Label(L10n.PanelTabs.returnAll, systemImage: "rectangle.on.rectangle") }
            .controlSize(.small).focusable(false).padding(12)
            .disabled(!tabs.contains(where: isDetached))
        }.frame(width: 310)
    }

    private func detachedPlaceholder(_ tab: AgentPanelTab) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle").font(.system(size: 28)).foregroundStyle(.secondary)
            Text(L10n.PanelTabs.inWindow).font(.system(size: 12)).foregroundStyle(.secondary)
            Button(L10n.PanelTabs.focusWindow) { registry.focus(id(tab), kind: tab.kind) }
            Button(L10n.PanelTabs.returnToDock) { registry.reattach(id(tab), appState: appState) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func select(_ tab: AgentPanelTab) {
        guard !registry.focus(id(tab), kind: tab.kind) else { return }
        appState.updatePanelTabs(runtime: runtime) { $0.selectTab(tab.id) }
    }

    private func detach(_ tab: AgentPanelTab) {
        registry.detach(id(tab), appState: appState)
        if selected?.id == tab.id, let next = tabs.first(where: { !isDetached($0) }) { select(next) }
    }

    private func receiveDrop(_ providers: [NSItemProvider], before target: UUID?) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.willDeepPanelTab.identifier) { data, _ in
            guard let data, let dropped = try? JSONDecoder().decode(AgentPanelTabID.self, from: data) else { return }
            Task { @MainActor in
                guard dropped.sessionID == runtime.id,
                      tabs.contains(where: { $0.id == dropped.tabID }) else { return }
                registry.reattach(dropped, appState: appState, reveal: false)
                appState.updatePanelTabs(runtime: runtime) {
                    if let target { $0.moveTab(dropped.tabID, before: target) }
                    $0.selectTab(dropped.tabID)
                }
            }
        }
        return true
    }
}
