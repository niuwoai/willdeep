//
//  SomeIMStoreTestIsolationTests.swift
//  WillDeepTests
//
//  The unit-test host is a Debug WillDeep.app with the installed app's bundle
//  id, so `UserDefaults.standard` in this process is the installed app's
//  preferences domain. On 2026-09-26 the some.im store tests switched the
//  installed app's integration off on every `xcodebuild test` run. These tests
//  pin down that the store can no longer reach the real app's defaults or the
//  shared Keychain session from a test process, even when a test forgets to
//  opt into the overrides.
//
//  Every case is synchronous on the main actor and puts the store's
//  process-wide test state back before returning, so suites suspended at an
//  `await` never observe the changes.
//

import Testing
import Foundation
@testable import WillDeep

@Suite(.serialized)
@MainActor
struct SomeIMStoreTestIsolationTests {
    private static let settingsKey = "com.willdeep.someIM.integrationSettings.v1"

    // Keys the installed app reads. Read-only here: the tests only compare
    // snapshots of the real domain, they never write it.
    private static let storeKeys = [
        settingsKey,
        "com.willdeep.someIM.account.v1",
        "com.willdeep.someIM.codingPlanStatus.v1",
        "com.willdeep.someIM.sharedSessionMigration.v1",
    ]

    // The store's per-app credential rows. Under XCTest `AgentCredentialStore`
    // keeps them in memory, shared by the whole process.
    private static let legacyCredentialAccounts = ["some-im/api-key", "some-im/customer-session"]

    private static func snapshot(of defaults: UserDefaults) -> [String: Data] {
        var snapshot: [String: Data] = [:]
        for key in storeKeys {
            guard let value = defaults.object(forKey: key) else { continue }
            snapshot[key] = try? PropertyListSerialization.data(
                fromPropertyList: value, format: .binary, options: 0
            )
        }
        return snapshot
    }

    /// Runs `body` with the store's test state saved and restored around it,
    /// including whatever `body` writes into the current defaults and the
    /// in-memory legacy credential rows.
    private static func withIsolatedStoreState(_ body: () throws -> Void) rethrows {
        let state = SomeIMIntegrationStore._captureTestState()
        let defaults = SomeIMIntegrationStore.defaults
        let values = storeKeys.map { defaults.object(forKey: $0) }
        let credentials = legacyCredentialAccounts.map { AgentCredentialStore.load(account: $0) }
        defer {
            for (key, value) in zip(storeKeys, values) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            for (account, secret) in zip(legacyCredentialAccounts, credentials) {
                AgentCredentialStore.save(secret, account: account)
            }
            SomeIMIntegrationStore._restoreTestState(state)
        }
        try body()
    }

    private static func sampleAccount(email: String) -> SomeIMAccount {
        SomeIMAccount(
            email: email,
            tenantID: "tenant-isolation",
            balanceUSD: "1.00",
            credits: "100000",
            creditsPerUSD: 100000,
            defaultModel: "someim-auto-flash",
            lastUpdatedAt: Date()
        )
    }

    @Test("under XCTest the store's defaults are never the app's standard domain")
    func fallbackDefaultsIsNotStandard() {
        Self.withIsolatedStoreState {
            SomeIMIntegrationStore._setTestDefaultsOverride(nil)
            #expect(SomeIMIntegrationStore.isRunningUnderXCTest)
            #expect(SomeIMIntegrationStore.defaults !== UserDefaults.standard)
        }
    }

    @Test("a test that skips every override still cannot disable the installed app's some.im")
    func unoptedLogoutLeavesRealDomainAlone() {
        let before = Self.snapshot(of: .standard)
        let accessesBefore = SomeIMIntegrationStore._testRealSharedSessionStoreAccessCount
        Self.withIsolatedStoreState {
            SomeIMIntegrationStore._setTestDefaultsOverride(nil)
            SomeIMIntegrationStore._setTestSharedSessionOverride(enabled: false)

            // What the old SomeIMBrowserLoginStatusTests did around each case,
            // minus the opt-in: enable, cache an account, sign in, log out.
            var settings = SomeIMIntegrationStore.loadSettings()
            settings.enabled = true
            SomeIMIntegrationStore.saveSettings(settings)
            SomeIMIntegrationStore.saveAccount(Self.sampleAccount(email: "isolation@example.com"))
            #expect(SomeIMIntegrationStore.saveAPIKey("sk-test-isolation"))
            #expect(SomeIMIntegrationStore.loadSettings().enabled)
            #expect(SomeIMIntegrationStore.loadAccount()?.email == "isolation@example.com")

            SomeIMIntegrationStore.logout()

            #expect(!SomeIMIntegrationStore.loadSettings().enabled)
            #expect(SomeIMIntegrationStore.loadAccount() == nil)
            #expect(SomeIMIntegrationStore.loadAPIKey().isEmpty)
        }
        #expect(Self.snapshot(of: .standard) == before)
        #expect(SomeIMIntegrationStore._testRealSharedSessionStoreAccessCount == accessesBefore)
    }

    @Test("an injected suite receives the store's writes")
    func injectedSuiteReceivesWrites() throws {
        let suiteName = SomeIMIntegrationStore.xctestDefaultsSuitePrefix + UUID().uuidString
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsHygiene.cleanup(suite: suite, named: suiteName) }
        let before = Self.snapshot(of: .standard)

        Self.withIsolatedStoreState {
            SomeIMIntegrationStore._setTestDefaultsOverride(suite)
            var settings = SomeIMIntegrationStore.loadSettings()
            settings.enabled = true
            SomeIMIntegrationStore.saveSettings(settings)

            #expect(SomeIMIntegrationStore.defaults === suite)
            #expect(suite.data(forKey: Self.settingsKey) != nil)
        }
        #expect(Self.snapshot(of: .standard) == before)
    }

    /// The host app's `applicationDidFinishLaunching` calls
    /// `configureSharedSession()` before any test runs, and any test earlier in
    /// this process may have logged in or out. None of it may have reached the
    /// shared Keychain session.
    @Test("nothing in the test process has reached the shared Keychain session")
    func sharedKeychainSessionNeverTouched() {
        SomeIMIntegrationStore.configureSharedSession()
        #expect(SomeIMIntegrationStore._testRealSharedSessionStoreAccessCount == 0)
    }
}
