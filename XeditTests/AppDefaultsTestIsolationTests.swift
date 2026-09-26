//
//  AppDefaultsTestIsolationTests.swift
//  WillDeepTests
//
//  The unit-test host is a Debug WillDeep.app with the installed app's bundle
//  id, so `UserDefaults.standard` in this process is the installed app's
//  preferences domain. Until 1.404.0-rc5 `WillDeepTests.init` and
//  `EditorCoreBehaviorTests.init` cleared the installed app's recent files,
//  recent folders and restored editor session before every test. These tests
//  pin down that the stores and those inits can no longer reach the real
//  domain from a test process.
//
//  Every case is synchronous on the main actor. Writes go to a per-test suite
//  installed with `AppDefaults._withTestDefaults`, which is task-local, so
//  suites running in parallel neither see it nor clear it.
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct AppDefaultsTestIsolationTests {
    // Keys the installed app reads. Read-only here: the tests only compare
    // snapshots of the real domain, they never write it.
    private static let appKeys = [
        "com.willdeep.recentFiles.v1",
        "com.willdeep.recentFolders.v1",
        "com.willdeep.session.v1",
        "com.willdeep.terminalShortcuts.v1",
        "com.willdeep.agentSkillSettings.v1",
        "com.willdeep.agentSkillSettings.defaultThreshold.rc219",
        "willdeep.agent.autoDispatchWorkers",
    ]

    private static let recentFile = URL(fileURLWithPath: "/willdeep-isolation-fixture/Sources/main.swift")
    private static let recentFolder = URL(fileURLWithPath: "/willdeep-isolation-fixture")

    private final class ResolvedDefaults: @unchecked Sendable {
        var value: UserDefaults?
    }

    private static func snapshot(of defaults: UserDefaults) -> [String: Data] {
        var snapshot: [String: Data] = [:]
        for key in appKeys {
            guard let value = defaults.object(forKey: key) else { continue }
            snapshot[key] = try? PropertyListSerialization.data(
                fromPropertyList: value, format: .binary, options: 0
            )
        }
        return snapshot
    }

    private static func withSuite(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = AppDefaults.xctestSuitePrefix + UUID().uuidString
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsHygiene.cleanup(suite: suite, named: suiteName) }
        try AppDefaults._withTestDefaults(suite) { try body(suite) }
    }

    @Test("under XCTest every store's defaults is the throwaway suite, never the app's domain")
    func storesResolveToThrowawaySuite() {
        let fallback = AppDefaults.standard
        #expect(AppDefaults.isRunningUnderXCTest)
        #expect(fallback !== UserDefaults.standard)
        #expect(RecentItemsStore.defaults === fallback)
        #expect(SessionStore.defaults === fallback)
        #expect(TerminalShortcutStore.defaults === fallback)
        #expect(AgentSkillSettingsStore.defaults === fallback)
    }

    @Test("a test's injected suite is visible only to its own task")
    func injectedSuiteIsTaskLocal() throws {
        let fallback = AppDefaults.standard
        try Self.withSuite { suite in
            RecentItemsStore.saveFiles([Self.recentFile])
            #expect(RecentItemsStore.defaults === suite)
            #expect(suite.stringArray(forKey: RecentItemsStore.filesKey) == [Self.recentFile.path])

            // What a parallel suite's `init()` sees while this test holds the
            // suite: the shared fallback, so it cannot clear this test's keys.
            let resolved = ResolvedDefaults()
            let done = DispatchSemaphore(value: 0)
            Thread {
                resolved.value = RecentItemsStore.defaults
                done.signal()
            }.start()
            #expect(done.wait(timeout: .now() + 5) == .success)
            #expect(resolved.value === fallback)
        }
        #expect(RecentItemsStore.defaults === fallback)
    }

    @Test("the suite inits and the stores' writes leave the installed app's domain alone")
    func suiteInitsAndStoreWritesLeaveRealDomainAlone() throws {
        let before = Self.snapshot(of: .standard)
        try Self.withSuite { suite in
            RecentItemsStore.saveFiles([Self.recentFile])
            RecentItemsStore.saveFolders([Self.recentFolder])
            SessionStore.save(EditorSessionSnapshot(
                rootDirectoryPath: Self.recentFolder.path,
                rootDirectoryBookmarkData: nil,
                tabPaths: [Self.recentFile.path],
                activeTabPath: Self.recentFile.path
            ))
            #expect(RecentItemsStore.loadFiles() == [Self.recentFile])
            #expect(RecentItemsStore.loadFolders() == [Self.recentFolder])
            #expect(SessionStore.load()?.tabPaths == [Self.recentFile.path])

            // Skill settings and the dispatch switch resolve through the
            // same suite.
            AgentSkillSettingsStore.save(AgentSkillSettingsStore.load())
            #expect(suite.data(forKey: "com.willdeep.agentSkillSettings.v1") != nil)
            #expect(AppState.autoDispatchWorkersEnabled)

            // The per-test setUps that used to clear `.standard` now clear
            // the stores' defaults, and only those.
            _ = WillDeepTests()
            _ = EditorCoreBehaviorTests()
            #expect(RecentItemsStore.loadFiles().isEmpty)
            #expect(RecentItemsStore.loadFolders().isEmpty)
            #expect(SessionStore.load() == nil)
        }
        #expect(Self.snapshot(of: .standard) == before)
    }
}
