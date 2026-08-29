//
//  AgentProfileStore.swift
//  WillDeep
//
//  The single persisted source for agent profiles, replacing the two v1
//  stores (`...subagent-profile-bindings.v1` for trades and
//  `...executionProfiles.v1` for dispatch).
//
//  The v1 keys are read once during migration and then left untouched, so a
//  downgrade still finds its own data.
//

import Foundation

nonisolated struct AgentProfileStore {
    static let defaultsKey = "com.willdeep.agentProfiles.v2"
    static let migrationFlagKey = "com.willdeep.agentProfiles.migratedFromV1"
    /// v1 keys, read-only from here on.
    static let legacySubagentBindingsKey = "com.willdeep.agent.subagent-profile-bindings.v1"
    static let legacyExecutionProfilesKey = "com.willdeep.agentDispatch.executionProfiles.v1"

    private let defaults: UserDefaults

    /// Same redirect as `AgentDispatchStore`: under XCTest the whole process
    /// writes into a throwaway suite. Profiles are reached through two
    /// façades used all over AppState, so a test that touches either one
    /// would otherwise rewrite the user's real trades and dispatch profiles.
    /// The `willdeep-profiles-` prefix is registered with TestDefaultsHygiene.
    private static let processDefaults: UserDefaults = {
        let environment = ProcessInfo.processInfo.environment
        let underTest = NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest") != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        guard underTest,
              let sandbox = UserDefaults(
                  suiteName: "willdeep-profiles-process-\(ProcessInfo.processInfo.processIdentifier)"
              ) else {
            return .standard
        }
        return sandbox
    }()

    init(defaults: UserDefaults = AgentProfileStore.processDefaults) {
        self.defaults = defaults
    }

    // MARK: - Records

    func loadRecords() -> AgentProfileRecords {
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(AgentProfileRecords.self, from: data) {
            return decoded
        }
        guard !defaults.bool(forKey: Self.migrationFlagKey) else { return AgentProfileRecords() }
        let migrated = migratedRecordsFromV1()
        save(records: migrated)
        defaults.set(true, forKey: Self.migrationFlagKey)
        return migrated
    }

    func save(records: AgentProfileRecords) {
        var cleaned = records
        cleaned.overrides = records.overrides.filter { !$0.value.isEmpty }
        cleaned.managed = records.managed.filter { $0.origin == .managed && !$0.name.isEmpty }
        guard let data = try? JSONEncoder().encode(cleaned) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    // MARK: - Profiles

    /// Built-ins with the user's overrides applied, then user-created
    /// profiles, then read-only CLI profiles discovered on disk.
    func profiles(workspacePath: String? = nil, includeDiscovered: Bool = false) -> [AgentProfile] {
        let records = loadRecords()
        let builtIns = AgentProfile.builtIns.map { profile in
            records.overrides[profile.id]?.applied(to: profile) ?? profile
        }
        let discovered = includeDiscovered
            ? LocalAgentCLIProfile.discover(workspacePath: workspacePath)
                .map { AgentProfile.from(execution: AgentExecutionProfile(
                    id: $0.id,
                    name: $0.displayName,
                    executor: $0.executor,
                    modelID: $0.modelID,
                    providerID: $0.providerID,
                    nativeProfileName: $0.nativeProfileName,
                    origin: .discovered
                )) }
            : []
        var seen = Set<String>()
        return (builtIns + records.managed + discovered)
            .filter { seen.insert($0.id).inserted }
    }

    func profiles(
        usage: AgentProfile.Usage,
        workspacePath: String? = nil,
        includeDiscovered: Bool = false
    ) -> [AgentProfile] {
        profiles(workspacePath: workspacePath, includeDiscovered: includeDiscovered)
            .filter { $0.usages.contains(usage) }
    }

    /// Persists a full list back into override + managed form. Built-ins are
    /// diffed against code so only real edits are stored; discovered profiles
    /// are dropped (they are rebuilt from disk).
    func save(profiles: [AgentProfile]) {
        let builtInsByID = Dictionary(uniqueKeysWithValues: AgentProfile.builtIns.map { ($0.id, $0) })
        var records = AgentProfileRecords()
        for profile in profiles {
            switch profile.origin {
            case .builtIn:
                guard let base = builtInsByID[profile.id] else { continue }
                let override = Self.override(for: profile, base: base)
                if !override.isEmpty { records.overrides[profile.id] = override }
            case .managed:
                records.managed.append(profile)
            case .discovered:
                continue
            }
        }
        save(records: records)
    }

    static func override(for profile: AgentProfile, base: AgentProfile) -> AgentProfileOverride {
        AgentProfileOverride(
            name: profile.name == base.name ? nil : profile.name,
            promptSection: profile.soul.promptSection == base.soul.promptSection
                ? nil
                : profile.soul.promptSection,
            skillIdentifiers: profile.soul.skillIdentifiers == base.soul.skillIdentifiers
                ? nil
                : profile.soul.skillIdentifiers,
            modelBinding: profile.runtime.modelBinding == base.runtime.modelBinding
                ? nil
                : profile.runtime.modelBinding,
            nativeProfileName: profile.runtime.nativeProfileName == base.runtime.nativeProfileName
                ? nil
                : profile.runtime.nativeProfileName,
            usages: profile.usages == base.usages
                ? nil
                : Array(profile.usages).sorted { $0.rawValue < $1.rawValue },
            maxRounds: profile.capability?.maxRounds == base.capability?.maxRounds
                ? nil
                : profile.capability?.maxRounds
        )
    }

    // MARK: - Migration

    func migratedRecordsFromV1() -> AgentProfileRecords {
        var records = AgentProfileRecords()

        // Trades: v1 stored only the model binding.
        if let data = defaults.data(forKey: Self.legacySubagentBindingsKey),
           let bindings = try? JSONDecoder().decode(
               [String: AgentSubagentProfile.ModelBinding].self,
               from: data
           ) {
            for (id, binding) in bindings where AgentSubagentProfileCatalog.isKnown(id: id) {
                records.overrides[id] = AgentProfileOverride(modelBinding: binding)
            }
        }

        // Dispatch: v1 stored built-in overlays and user-created profiles in
        // one array, distinguished by `origin`.
        if let data = defaults.data(forKey: Self.legacyExecutionProfilesKey),
           let stored = try? JSONDecoder().decode([AgentExecutionProfile].self, from: data) {
            let builtInsByID = Dictionary(
                uniqueKeysWithValues: AgentProfile.builtIns.map { ($0.id, $0) }
            )
            for execution in stored {
                let profile = AgentProfile.from(execution: execution)
                if execution.origin == .builtIn, let base = builtInsByID[execution.id] {
                    let override = Self.override(for: profile, base: base)
                    if !override.isEmpty { records.overrides[execution.id] = override }
                } else if execution.origin == .managed {
                    records.managed.append(profile)
                }
            }
        }

        return records
    }
}
