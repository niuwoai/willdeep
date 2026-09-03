import Foundation

/// A tab describes one session-scoped workbench surface. Live terminal and
/// browser resources are released by AppState when their owning tab closes;
/// background jobs remain managed by their dedicated registry.
nonisolated struct AgentPanelTab: Codable, Equatable, Identifiable {
    var id = UUID()
    let kind: AgentSidePanelKind
    var selectedFilePath: String?
    /// Identity of live content hosted by this outer tab (a PTY tab or an
    /// embedded-browser controller). Nil keeps legacy session JSON readable.
    var resourceID: UUID? = nil
    var customTitle: String? = nil

    var file: URL? { selectedFilePath.map { URL(fileURLWithPath: $0) } }
    var title: String { customTitle ?? file?.lastPathComponent ?? kind.title }
    var systemImage: String { kind == .preview && file != nil ? "doc.text" : kind.systemImage }
}

nonisolated struct AgentPanelTabID: Codable, Hashable {
    let sessionID: UUID
    let tabID: UUID
}

extension AgentSidePanelState {
    /// Optional storage keeps pre-tabs session documents backwards compatible.
    var openTabs: [AgentPanelTab] {
        if let tabs { return tabs }
        guard let kind else { return [] }
        // Stable migration identity; materialized before the first mutation.
        return [AgentPanelTab(id: Self.legacyTabID, kind: kind, selectedFilePath: selectedFilePath)]
    }

    private static let legacyTabID = UUID(uuidString: "629E9078-27DF-44D7-98C0-2600F4B15196")!

    var selectedTab: AgentPanelTab? {
        openTabs.first { $0.id == selectedTabID && (kind == nil || $0.kind == kind) }
            ?? openTabs.first { $0.kind == kind }
    }

    @discardableResult
    mutating func openTab(kind: AgentSidePanelKind, file: URL? = nil, exactFile: Bool = false) -> AgentPanelTab {
        var items = openTabs
        let path = file?.standardizedFileURL.path
        let fileSpecific = kind == .preview || kind == .diff
        let existing = items.first {
            $0.kind == kind && (!fileSpecific || (!exactFile && file == nil) || $0.selectedFilePath == path)
        }
        let tab = existing ?? AgentPanelTab(kind: kind, selectedFilePath: path)
        if existing == nil { items.append(tab) }
        tabs = items
        selectTab(tab.id)
        return tab
    }

    @discardableResult
    mutating func createTab(
        kind: AgentSidePanelKind,
        file: URL? = nil,
        resourceID: UUID? = nil,
        title: String? = nil
    ) -> AgentPanelTab {
        var items = openTabs
        let tab = AgentPanelTab(
            kind: kind,
            selectedFilePath: file?.standardizedFileURL.path,
            resourceID: resourceID,
            customTitle: title
        )
        items.append(tab)
        tabs = items
        selectTab(tab.id)
        return tab
    }

    mutating func selectTab(_ id: UUID) {
        guard let tab = openTabs.first(where: { $0.id == id }) else { return }
        tabs = openTabs
        selectedTabID = id
        kind = tab.kind
        selectedFilePath = tab.selectedFilePath
        lastViewedAt = Date()
    }

    mutating func closeTab(_ id: UUID) {
        var items = openTabs
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedTab?.id == id
        items.remove(at: index)
        tabs = items
        if wasSelected {
            selectedTabID = nil
            kind = nil
            selectedFilePath = nil
            if !items.isEmpty { selectTab(items[min(index, items.count - 1)].id) }
        }
    }

    mutating func updateTabFile(_ file: URL?, tabID: UUID) {
        var items = openTabs
        guard let index = items.firstIndex(where: { $0.id == tabID }) else { return }
        items[index].selectedFilePath = file?.standardizedFileURL.path
        tabs = items
        if selectedTab?.id == tabID { selectedFilePath = items[index].selectedFilePath }
    }

    mutating func updateTabResource(_ resourceID: UUID?, title: String?, tabID: UUID) {
        var items = openTabs
        guard let index = items.firstIndex(where: { $0.id == tabID }) else { return }
        items[index].resourceID = resourceID
        if let title, !title.isEmpty { items[index].customTitle = title }
        tabs = items
    }

    mutating func moveTab(_ id: UUID, before target: UUID) {
        var items = openTabs
        guard id != target, let index = items.firstIndex(where: { $0.id == id }),
              items.contains(where: { $0.id == target }) else { return }
        let tab = items.remove(at: index)
        if let targetIndex = items.firstIndex(where: { $0.id == target }) { items.insert(tab, at: targetIndex) }
        tabs = items
    }
}

/// A detached tab lives in its own window, so the sidebar strip must not keep a
/// placeholder chip for it: the chip would be a second surface for content that
/// is already visible somewhere else. The full list (dock + windows) stays
/// reachable from the overview popover.
nonisolated enum AgentPanelTabStrip {
    static func docked(_ tabs: [AgentPanelTab], isDetached: (AgentPanelTab) -> Bool) -> [AgentPanelTab] {
        tabs.filter { !isDetached($0) }
    }

    /// Selection may still point at a detached tab (opening a panel kind focuses
    /// its window without moving it back), so the dock falls back to the first
    /// tab it can actually render.
    static func active(selected: AgentPanelTab?, in tabs: [AgentPanelTab],
                       isDetached: (AgentPanelTab) -> Bool) -> AgentPanelTab? {
        if let selected, !isDetached(selected) { return selected }
        return docked(tabs, isDetached: isDetached).first
    }
}
