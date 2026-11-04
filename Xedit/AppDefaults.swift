//
//  AppDefaults.swift
//  WillDeep
//
//  The unit-test host is a Debug WillDeep.app with the installed app's bundle
//  id, so `UserDefaults.standard` in a test process *is* the installed
//  /Applications/WillDeep.app's preferences domain. Until 1.404.0-rc5 every
//  `xcodebuild test` run wiped the installed app's recent files, recent
//  folders and restored editor session, because the suites cleared those keys
//  in `.standard` before each test.
//
//  Stores that read or write app preferences go through `AppDefaults.standard`
//  instead: the shipping app gets `.standard`, a test process gets one
//  throwaway suite for its whole lifetime, whether or not a test opted in.
//

import Foundation

nonisolated enum AppDefaults {
    #if DEBUG
    static let isRunningUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Suite-name prefix of the throwaway defaults below. Registered in
    /// `TestDefaultsHygiene.disposableSuitePrefixes`, which sweeps the leftovers.
    static let xctestSuitePrefix = "com.willdeep.tests.app-defaults."

    private static let xctestFallback: UserDefaults? = {
        guard isRunningUnderXCTest else { return nil }
        return UserDefaults(suiteName: xctestSuitePrefix + UUID().uuidString)
    }()

    @TaskLocal private static var testOverride: UserDefaults?

    /// Runs `body` with every store on `AppDefaults.standard` pointed at
    /// `defaults` (a per-test `UserDefaults(suiteName:)`); cleaning up the
    /// suite is the caller's job. Task-local rather than a settable static:
    /// suites running in parallel clear these keys from their `init()`, and a
    /// process-wide override would hand them this test's suite.
    static func _withTestDefaults<T>(_ defaults: UserDefaults, _ body: () throws -> T) rethrows -> T {
        try $testOverride.withValue(defaults, operation: body)
    }

    static func _withTestDefaults<T>(_ defaults: UserDefaults, _ body: () async throws -> T) async rethrows -> T {
        try await $testOverride.withValue(defaults, operation: body)
    }
    #endif

    /// `.standard` in the app. Under XCTest, the suite a test installed with
    /// `_withTestDefaults`, otherwise the per-process throwaway suite.
    static var standard: UserDefaults {
        #if DEBUG
        if let testOverride { return testOverride }
        if let xctestFallback { return xctestFallback }
        #endif
        return .standard
    }
}
