//
//  AgentPluginRegistry.swift
//  WillDeep
//
//  Main-thread observable projection of plugin packages. Filesystem walking,
//  hashing and manifest validation happen off the main actor; views consume a
//  stable immutable snapshot.
//

import Foundation
import Combine

nonisolated enum AgentPluginPaths {
    static var installedRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".willdeep/plugins", isDirectory: true)
    }

    static var draftRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".willdeep/plugin-drafts", isDirectory: true)
    }

    static var codexCacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/plugins/cache", isDirectory: true)
    }

    static var stateURL: URL {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WillDeep", isDirectory: true)
        return support.appendingPathComponent("plugin-registry.json")
    }

    static var bundledRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("BundledPlugins", isDirectory: true)
    }
}

nonisolated enum AgentPluginRegistryStateStore {
    static func load(url: URL = AgentPluginPaths.stateURL) -> AgentPluginRegistryState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(AgentPluginRegistryState.self, from: data) else {
            return .empty
        }
        return normalized(state)
    }

    static func save(_ state: AgentPluginRegistryState, url: URL = AgentPluginPaths.stateURL) throws {
        let normalizedState = normalized(state)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(normalizedState).write(to: url, options: .atomic)
    }

    static func normalized(_ state: AgentPluginRegistryState) -> AgentPluginRegistryState {
        var copy = state
        copy.disabledPluginIDs = Array(Set(copy.disabledPluginIDs.filter { !$0.isEmpty })).sorted()
        copy.approvedDigests = Array(Set(copy.approvedDigests.filter { !$0.isEmpty })).sorted()
        copy.approvedInstallations = Array(Set(copy.approvedInstallations.filter { !$0.isEmpty })).sorted()
        copy.installSources = copy.installSources.filter {
            !$0.key.isEmpty && !$0.value.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var seenDestinations: Set<String> = []
        copy.pinnedDestinationIDs = copy.pinnedDestinationIDs.filter {
            !$0.isEmpty && seenDestinations.insert($0).inserted
        }
        if copy.pinnedDestinationIDs.count > AgentPluginRegistry.maximumPinnedDestinations {
            copy.pinnedDestinationIDs = Array(copy.pinnedDestinationIDs.prefix(AgentPluginRegistry.maximumPinnedDestinations))
        }
        copy.activeVersions = copy.activeVersions.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        return copy
    }
}

nonisolated enum AgentPluginRuntimeSnapshotStore {
    nonisolated(unsafe) private static var packages: [AgentPluginPackage] = []
    private static let lock = NSLock()

    static func update(from snapshot: AgentPluginRegistrySnapshot) {
        let activeIDs = Set(snapshot.records.filter(\.isEnabled).map { $0.activePackage.id })
        let next = snapshot.records
            .map(\.activePackage)
            .filter { activeIDs.contains($0.id) }
        lock.lock()
        packages = next
        lock.unlock()
    }

    static func activePackages() -> [AgentPluginPackage] {
        lock.lock()
        defer { lock.unlock() }
        return packages
    }
}

@MainActor
final class AgentPluginRegistry: ObservableObject {
    static let shared = AgentPluginRegistry()
    nonisolated static let maximumPinnedDestinations = 5

    @Published private(set) var snapshot: AgentPluginRegistrySnapshot = .empty
    @Published private(set) var isRefreshing = false

    private var state: AgentPluginRegistryState
    private var refreshGeneration = 0
    private let roots: [AgentPluginDiscovery.Root]
    private let currentWillDeepVersion: String
    private let stateURL: URL

    init(
        roots: [AgentPluginDiscovery.Root]? = nil,
        currentWillDeepVersion: String? = nil,
        stateURL: URL = AgentPluginPaths.stateURL,
        autoRefresh: Bool = true
    ) {
        self.stateURL = stateURL
        self.state = AgentPluginRegistryStateStore.load(url: stateURL)
        self.currentWillDeepVersion = currentWillDeepVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.0.0"
        if let roots {
            self.roots = roots
        } else {
            var defaults = [
                AgentPluginDiscovery.Root(
                    url: AgentPluginPaths.installedRoot,
                    source: .installed,
                    maximumDepth: 3
                ),
                AgentPluginDiscovery.Root(
                    url: AgentPluginPaths.draftRoot,
                    source: .draft,
                    maximumDepth: 3
                ),
                AgentPluginDiscovery.Root(
                    url: AgentPluginPaths.codexCacheRoot,
                    source: .codexCache,
                    maximumDepth: 8
                ),
            ]
            if let bundled = AgentPluginPaths.bundledRoot {
                defaults.append(.init(url: bundled, source: .bundled, maximumDepth: 3))
            }
            self.roots = defaults
        }
        if autoRefresh {
            Task { await refresh() }
        }
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        let roots = roots
        let version = currentWillDeepVersion
        let result = await Task.detached(priority: .utility) {
            AgentPluginDiscovery.discover(roots: roots, currentWillDeepVersion: version)
        }.value
        guard generation == refreshGeneration else { return }
        snapshot = Self.makeSnapshot(packages: result.packages, issues: result.issues, state: state)
        AgentPluginRuntimeSnapshotStore.update(from: snapshot)
        AgentSkillDirectory.invalidateCache()
        isRefreshing = false
        pruneStateAgainstSnapshot()
    }

    func destination(id: AgentPluginDestinationID) -> AgentPluginDestinationDescriptor? {
        snapshot.activeDestinations.first { $0.qualifiedID == id }
    }

    func record(pluginID: AgentPluginID) -> AgentPluginRecord? {
        snapshot.records.first { $0.pluginID == pluginID }
    }

    /// 插件有没有声明某项权限。只认「已启用」的插件——停用的插件不该还能
    /// 借页面桥继续问模型。
    func hasPermission(_ permission: AgentPluginPermission, pluginID: AgentPluginID) -> Bool {
        guard let record = record(pluginID: pluginID), record.isEnabled else { return false }
        return record.activePackage.manifest?.permissions.contains(permission) ?? false
    }

    func commands(for pluginID: AgentPluginID) -> [AgentPluginCommandContribution] {
        guard let record = record(pluginID: pluginID), record.isEnabled else { return [] }
        return record.activePackage.manifest?.contributes.commands ?? []
    }

    func command(pluginID: AgentPluginID, commandID: AgentPluginCommandID) -> AgentPluginCommandContribution? {
        commands(for: pluginID).first { $0.id == commandID }
    }

    func menuCommands(at location: String) -> [AgentPluginResolvedCommand] {
        snapshot.records.flatMap { record -> [AgentPluginResolvedCommand] in
            guard record.isEnabled, let manifest = record.activePackage.manifest else { return [] }
            let commandsByID = Dictionary(uniqueKeysWithValues: manifest.contributes.commands.map { ($0.id, $0) })
            return (manifest.contributes.menus[location] ?? []).compactMap { commandID in
                commandsByID[commandID].map {
                    AgentPluginResolvedCommand(pluginID: record.pluginID, command: $0)
                }
            }
        }
    }

    func defaultDestinationID(for pluginID: AgentPluginID) -> AgentPluginDestinationID {
        snapshot.activeDestinations.first(where: { $0.pluginID == pluginID })?.qualifiedID
            ?? "\(pluginID):commands"
    }

    func setEnabled(_ enabled: Bool, pluginID: AgentPluginID) {
        var disabled = Set(state.disabledPluginIDs)
        if enabled {
            disabled.remove(pluginID)
        } else {
            disabled.insert(pluginID)
        }
        state.disabledPluginIDs = disabled.sorted()
        persistAndRebuild()
    }

    func approve(package: AgentPluginPackage, source: AgentPluginInstallSourceRecord) {
        var approved = Set(state.approvedDigests)
        approved.insert(package.digest)
        state.approvedDigests = approved.sorted()
        state.installSources[package.id] = source
        var approvedInstallations = Set(state.approvedInstallations)
        approvedInstallations.insert(Self.approvalKey(digest: package.digest, source: source))
        state.approvedInstallations = approvedInstallations.sorted()
        state.activeVersions[package.pluginID] = package.version
        var disabled = Set(state.disabledPluginIDs)
        disabled.remove(package.pluginID)
        state.disabledPluginIDs = disabled.sorted()
        persistAndRebuild()
    }

    func isApproved(package: AgentPluginPackage) -> Bool {
        if package.source == .bundled { return true }
        if let source = state.installSources[package.id] {
            return state.approvedInstallations.contains(
                Self.approvalKey(digest: package.digest, source: source)
            )
        }
        return state.approvedDigests.contains(package.digest)
    }

    func revokeApproval(package: AgentPluginPackage) {
        state.approvedDigests.removeAll { $0 == package.digest }
        state.approvedInstallations.removeAll { $0.hasPrefix("\(package.digest)\u{1e}") }
        state.pinnedDestinationIDs.removeAll { $0.hasPrefix("\(package.pluginID):") }
        persistAndRebuild()
    }

    func removeInstalledPluginState(pluginID: AgentPluginID) {
        let installedPackages = snapshot.records
            .first(where: { $0.pluginID == pluginID })?
            .availableVersions
            .filter { $0.source == .installed } ?? []
        for package in installedPackages {
            guard let source = state.installSources[package.id] else { continue }
            let key = Self.approvalKey(digest: package.digest, source: source)
            state.approvedInstallations.removeAll { $0 == key }
        }
        state.installSources = state.installSources.filter { !$0.key.hasPrefix("\(pluginID)@") }
        let knownDigests = installedPackages.map(\.digest)
        state.approvedDigests.removeAll { knownDigests.contains($0) }
        state.activeVersions.removeValue(forKey: pluginID)
        state.disabledPluginIDs.removeAll { $0 == pluginID }
        state.pinnedDestinationIDs.removeAll { $0.hasPrefix("\(pluginID):") }
        persistAndRebuild()
    }

    func installSource(for package: AgentPluginPackage) -> AgentPluginInstallSourceRecord? {
        state.installSources[package.id]
    }

    func pageToolbarCommands(for destination: AgentPluginDestinationDescriptor) -> [AgentPluginCommandContribution] {
        let explicit = destination.toolbarCommandIDs.compactMap {
            command(pluginID: destination.pluginID, commandID: $0)
        }
        let menu = menuCommands(at: "plugin.page.toolbar")
            .filter { $0.pluginID == destination.pluginID }
            .map(\.command)
        return deduplicatedCommands(explicit + menu)
    }

    func sidebarRowContextCommands(
        for destination: AgentPluginDestinationDescriptor,
        explicitCommandIDs: [AgentPluginCommandID]
    ) -> [AgentPluginCommandContribution] {
        let explicit = explicitCommandIDs.compactMap {
            command(pluginID: destination.pluginID, commandID: $0)
        }
        let menu = menuCommands(at: "plugin.sidebar.row.context")
            .filter { $0.pluginID == destination.pluginID }
            .map(\.command)
        return deduplicatedCommands(explicit + menu)
    }

    func activate(version: String, pluginID: AgentPluginID) {
        guard record(pluginID: pluginID)?.availableVersions.contains(where: { $0.version == version }) == true else {
            return
        }
        state.activeVersions[pluginID] = version
        persistAndRebuild()
    }

    func pin(destinationID: AgentPluginDestinationID) {
        guard snapshot.activeDestinations.contains(where: { $0.qualifiedID == destinationID }),
              !snapshot.pinnedDestinationIDs.contains(destinationID),
              snapshot.pinnedDestinationIDs.count < Self.maximumPinnedDestinations else { return }
        state.pinnedDestinationIDs.append(destinationID)
        persistAndRebuild()
    }

    func unpin(destinationID: AgentPluginDestinationID) {
        guard destination(id: destinationID)?.defaultPinned != true else { return }
        state.pinnedDestinationIDs.removeAll { $0 == destinationID }
        persistAndRebuild()
    }

    func movePinned(destinationID: AgentPluginDestinationID, before targetID: AgentPluginDestinationID) {
        guard destinationID != targetID,
              destination(id: destinationID)?.defaultPinned != true,
              destination(id: targetID)?.defaultPinned != true,
              let sourceIndex = state.pinnedDestinationIDs.firstIndex(of: destinationID),
              let targetIndex = state.pinnedDestinationIDs.firstIndex(of: targetID) else { return }
        let moved = state.pinnedDestinationIDs.remove(at: sourceIndex)
        let adjustedIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        state.pinnedDestinationIDs.insert(moved, at: adjustedIndex)
        persistAndRebuild()
    }

    func localizedTitle(for destination: AgentPluginDestinationDescriptor) -> String {
        guard let record = record(pluginID: destination.pluginID) else {
            return destination.navigation.titleKey
        }
        return AgentPluginPackageLoader.localizedString(
            key: destination.navigation.titleKey,
            package: record.activePackage
        )
    }

    func localizedString(_ key: String, pluginID: AgentPluginID) -> String {
        guard let record = record(pluginID: pluginID) else { return key }
        return AgentPluginPackageLoader.localizedString(key: key, package: record.activePackage)
    }

    private func persistAndRebuild() {
        state = AgentPluginRegistryStateStore.normalized(state)
        try? AgentPluginRegistryStateStore.save(state, url: stateURL)
        let packages = snapshot.records.flatMap(\.availableVersions)
        snapshot = Self.makeSnapshot(packages: packages, issues: snapshot.issues, state: state)
        AgentPluginRuntimeSnapshotStore.update(from: snapshot)
        AgentSkillDirectory.invalidateCache()
    }

    private func deduplicatedCommands(
        _ commands: [AgentPluginCommandContribution]
    ) -> [AgentPluginCommandContribution] {
        var seen: Set<String> = []
        return commands.filter { seen.insert($0.id).inserted }
    }

    private func pruneStateAgainstSnapshot() {
        let validDestinationIDs = Set(snapshot.activeDestinations.map(\.qualifiedID))
        let filtered = state.pinnedDestinationIDs.filter { validDestinationIDs.contains($0) }
        guard filtered != state.pinnedDestinationIDs else { return }
        state.pinnedDestinationIDs = filtered
        persistAndRebuild()
    }

    nonisolated static func makeSnapshot(
        packages: [AgentPluginPackage],
        issues: [String],
        state: AgentPluginRegistryState
    ) -> AgentPluginRegistrySnapshot {
        let normalized = AgentPluginRegistryStateStore.normalized(state)
        let approved = Set(normalized.approvedDigests)
        let approvedInstallations = Set(normalized.approvedInstallations)
        let disabled = Set(normalized.disabledPluginIDs)
        let grouped = Dictionary(grouping: packages, by: \.pluginID)
        let bundledFixedDestinationIDs = Set(
            packages
                .filter { $0.source == .bundled }
                .flatMap(\.destinations)
                .filter(\.defaultPinned)
                .map(\.qualifiedID)
        )
        var records: [AgentPluginRecord] = []
        var activeDestinations: [AgentPluginDestinationDescriptor] = []

        for pluginID in grouped.keys.sorted() {
            let versions = (grouped[pluginID] ?? []).sorted(by: packageVersionDescending)
            guard !versions.isEmpty else { continue }
            let requestedVersion = normalized.activeVersions[pluginID]
            let active = versions.first(where: { $0.version == requestedVersion }) ?? versions[0]
            let isApproved: Bool
            if active.source == .bundled {
                isApproved = true
            } else if let source = normalized.installSources[active.id] {
                isApproved = approvedInstallations.contains(
                    approvalKey(digest: active.digest, source: source)
                )
            } else {
                isApproved = approved.contains(active.digest)
            }
            let isEnabled = isApproved && !disabled.contains(pluginID)
            let record = AgentPluginRecord(
                pluginID: pluginID,
                activePackage: active,
                availableVersions: versions,
                isEnabled: isEnabled,
                isApproved: isApproved,
                validationMessage: nil
            )
            records.append(record)
            if isEnabled {
                activeDestinations.append(contentsOf: active.destinations.map { destination in
                    AgentPluginDestinationDescriptor(
                        qualifiedID: destination.qualifiedID,
                        pluginID: destination.pluginID,
                        packageURL: destination.packageURL,
                        navigation: destination.navigation,
                        companionSidebar: destination.companionSidebar,
                        mainPage: destination.mainPage,
                        toolbarCommandIDs: destination.toolbarCommandIDs,
                        defaultPinned: bundledFixedDestinationIDs.contains(destination.qualifiedID)
                    )
                })
            }
        }
        activeDestinations.sort {
            if $0.pluginID != $1.pluginID { return $0.pluginID < $1.pluginID }
            return $0.qualifiedID < $1.qualifiedID
        }
        let validIDs = Set(activeDestinations.map(\.qualifiedID))
        let fixed = activeDestinations
            .filter(\.defaultPinned)
            .map(\.qualifiedID)
            .prefix(maximumPinnedDestinations)
        let fixedIDs = Set(fixed)
        let remainingCapacity = maximumPinnedDestinations - fixed.count
        let userPinned = normalized.pinnedDestinationIDs
            .filter { validIDs.contains($0) && !fixedIDs.contains($0) }
            .prefix(remainingCapacity)
        return AgentPluginRegistrySnapshot(
            records: records,
            activeDestinations: activeDestinations,
            pinnedDestinationIDs: Array(fixed) + Array(userPinned),
            issues: issues
        )
    }

    private nonisolated static func packageVersionDescending(
        _ lhs: AgentPluginPackage,
        _ rhs: AgentPluginPackage
    ) -> Bool {
        guard let left = AppVersion(lhs.version), let right = AppVersion(rhs.version) else {
            return lhs.version > rhs.version
        }
        if left != right { return left > right }
        let leftRank = sourceRank(lhs.source)
        let rightRank = sourceRank(rhs.source)
        if leftRank != rightRank { return leftRank < rightRank }
        return lhs.packageURL.path < rhs.packageURL.path
    }

    private nonisolated static func sourceRank(_ source: AgentPluginPackageSource) -> Int {
        switch source {
        case .installed: return 0
        case .bundled: return 1
        case .codexCache: return 2
        case .draft: return 3
        }
    }

    private nonisolated static func approvalKey(
        digest: String,
        source: AgentPluginInstallSourceRecord
    ) -> String {
        "\(digest)\u{1e}\(source.fingerprint)"
    }
}

@MainActor
final class AgentPluginDestinationSessionState: ObservableObject {
    static let shared = AgentPluginDestinationSessionState()

    @Published private(set) var selectedItemIDs: [AgentPluginDestinationID: String] = [:]
    @Published private(set) var refreshGenerations: [AgentPluginDestinationID: Int] = [:]

    func selectedItemID(for destinationID: AgentPluginDestinationID) -> String? {
        selectedItemIDs[destinationID]
    }

    func select(itemID: String?, destinationID: AgentPluginDestinationID) {
        if let itemID, !itemID.isEmpty {
            selectedItemIDs[destinationID] = itemID
        } else {
            selectedItemIDs.removeValue(forKey: destinationID)
        }
    }

    func requestRefresh(destinationID: AgentPluginDestinationID) {
        refreshGenerations[destinationID, default: 0] += 1
    }
}
