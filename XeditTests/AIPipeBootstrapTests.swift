import Darwin
import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AIPipeBootstrapTests {
    @Test("idle app termination does not ask for confirmation")
    func idleTerminationSkipsConfirmation() {
        var confirmationCount = 0

        let shouldTerminate = AppTerminationGuard.shouldAllowTermination(
            appStates: [],
            confirmation: {
                confirmationCount += 1
                return false
            }
        )

        #expect(shouldTerminate)
        #expect(confirmationCount == 0)
    }

    @Test("active background runtime requires explicit quit confirmation")
    func activeBackgroundRuntimeRequiresConfirmation() throws {
        let appState = AppState()
        let backgroundSession = appState.startNewAgentSession()
        let backgroundRuntime = try #require(appState.agentRuntimes[backgroundSession.id])
        _ = appState.startNewAgentSession()
        backgroundRuntime.isResponding = true

        var confirmationCount = 0
        let cancelledQuit = AppTerminationGuard.shouldAllowTermination(
            appStates: [appState],
            confirmation: {
                confirmationCount += 1
                return false
            }
        )
        let confirmedQuit = AppTerminationGuard.shouldAllowTermination(
            appStates: [appState],
            confirmation: {
                confirmationCount += 1
                return true
            }
        )

        #expect(!cancelledQuit)
        #expect(confirmedQuit)
        #expect(confirmationCount == 2)
    }

    @Test("valid environment configuration enables reporting")
    func validEnvironmentEnablesReporting() throws {
        var capturedConfig: AIPipeConfig?

        AIPipeBootstrap.initialize(
            environment: [
                "AIPIPE_API_KEY": "environment-key",
                "AIPIPE_ENDPOINT": "https://logs.example.com/api/v1",
                "AIPIPE_TOPIC": "willdeep-debug",
            ],
            compiledConfiguration: AIPipeBuildConfiguration(
                apiKey: "compiled-key",
                endpoint: "https://compiled.example.com/api/v1",
                topic: "compiled-topic"
            ),
            infoDictionary: [
                "AIPipeAPIKey": "plist-key",
                "AIPipeEndpoint": "https://plist.example.com/api/v1",
            ],
            reportingInitializer: { capturedConfig = $0 }
        )

        let config = try #require(capturedConfig)
        #expect(config.enabled)
        #expect(config.apiKey == "environment-key")
        #expect(config.endpoint == "https://logs.example.com/api/v1")
        #expect(config.topic == "willdeep-debug")
        #expect(config.source == "macos")
        #expect(config.format == "macos")
    }

    @Test("Info.plist key enables reporting with the default endpoint")
    func infoPlistKeyEnablesReporting() throws {
        var capturedConfig: AIPipeConfig?

        AIPipeBootstrap.initialize(
            environment: [:],
            compiledConfiguration: .empty,
            infoDictionary: ["AIPipeAPIKey": "plist-key"],
            reportingInitializer: { capturedConfig = $0 }
        )

        let config = try #require(capturedConfig)
        #expect(config.enabled)
        #expect(config.apiKey == "plist-key")
        #expect(config.endpoint == "https://17push.com/api/v1")
    }

    @Test("compiled configuration enables reporting without Info.plist credentials")
    func compiledConfigurationEnablesReporting() throws {
        var capturedConfig: AIPipeConfig?

        AIPipeBootstrap.initialize(
            environment: [:],
            compiledConfiguration: AIPipeBuildConfiguration(
                apiKey: "compiled-key",
                endpoint: "https://compiled.example.com/api/v1",
                topic: "compiled-topic"
            ),
            infoDictionary: [:],
            reportingInitializer: { capturedConfig = $0 }
        )

        let config = try #require(capturedConfig)
        #expect(config.enabled)
        #expect(config.apiKey == "compiled-key")
        #expect(config.endpoint == "https://compiled.example.com/api/v1")
        #expect(config.topic == "compiled-topic")
    }

    @Test("missing or unexpanded keys keep reporting disabled")
    func invalidKeysDoNotInitializeReporting() {
        var initializationCount = 0

        AIPipeBootstrap.initialize(
            environment: ["AIPIPE_API_KEY": "   "],
            compiledConfiguration: .empty,
            infoDictionary: ["AIPipeAPIKey": "$(AIPIPE_API_KEY)"],
            reportingInitializer: { _ in initializationCount += 1 }
        )

        #expect(initializationCount == 0)
    }
}

/// AIPipe SDK 本体的信号处置与队列安全测试。共享 `AIPipe.sharedInstance`
/// 单例状态，必须串行执行。
///
/// 落盘一律改到一次性 suite：测试宿主的 bundle id 就是 `com.willdeep.app`，
/// 和本机正在运行的 WillDeep、并发跑测试的其它 worktree 共用同一个偏好域，
/// 它们写入/删除 `AIPipeLogQueue` 曾把这里的落盘断言打成 0。
@Suite(.serialized)
@MainActor
struct AIPipeQueueSafetyTests {
    private static let isolatedSuitePrefix = "com.willdeep.tests.aipipe-queue."

    private func withIsolatedPersistence(
        _ body: (UserDefaults) async throws -> Void
    ) async throws {
        let suiteName = Self.isolatedSuitePrefix + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        AIPipe.setPersistenceDefaultsForTesting(defaults)
        defer {
            AIPipe.resetQueueForTesting()
            AIPipe.setPersistenceDefaultsForTesting(nil)
            TestDefaultsHygiene.cleanup(suite: defaults, named: suiteName)
        }
        try await body(defaults)
    }

    /// 批量阈值与定时器都推到测试窗口之外，保证测试期间不触发任何网络上报。
    private func initializeQuietAIPipe() {
        let config = AIPipeConfig.default()
        config.apiKey = "unit-test-key"
        config.endpoint = "https://invalid.invalid/api/v1"
        config.source = "macos-test"
        config.format = "macos-test"
        config.batchSize = 100_000
        config.batchTimeoutMs = 3_600_000
        config.maxRetries = 0
        config.enabled = true
        AIPipe.initialize(with: config)
    }

    private func handlerAddress(forSignal sig: Int32) -> UInt {
        // signal(2) 返回旧处置；先读出再原样写回，只为查询当前值。
        let previous = signal(sig, SIG_DFL)
        signal(sig, previous)
        return unsafeBitCast(previous, to: UInt.self)
    }

    @Test("SIGPIPE is ignored and raising it does not kill the process")
    func sigpipeIsIgnoredAfterInitialize() async throws {
        try await withIsolatedPersistence { _ in
            initializeQuietAIPipe()

            // SIG_IGN == (sig_t)1。曾经的版本给 SIGPIPE 挂了会 malloc/dispatch
            // 的 handler，高频 SIGPIPE 下堆出 126GB 内存。
            #expect(handlerAddress(forSignal: SIGPIPE) == 1)

            // 若处置不是 SIG_IGN，默认行为会直接终止测试进程。
            raise(SIGPIPE)
            #expect(handlerAddress(forSignal: SIGPIPE) == 1)
        }
    }

    @Test("fatal signals keep a real handler distinct from SIG_DFL/SIG_IGN")
    func fatalSignalsKeepRealHandler() async throws {
        try await withIsolatedPersistence { _ in
            initializeQuietAIPipe()

            for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS] {
                let address = handlerAddress(forSignal: sig)
                #expect(address != 0, "signal \(sig) fell back to SIG_DFL")
                #expect(address != 1, "signal \(sig) is unexpectedly ignored")
            }
        }
    }

    @Test("log queue caps at 1000 entries and drops the oldest")
    func queueCapsAtLimitDroppingOldest() async throws {
        try await withIsolatedPersistence { _ in
            initializeQuietAIPipe()
            AIPipe.resetQueueForTesting()

            for index in 0..<1100 {
                AIPipe.log(withLevel: "INFO", content: "cap-\(index)")
            }

            let contents = AIPipe.pendingLogContentsForTesting()
            #expect(contents.count == 1000)
            #expect(contents.first == "cap-100")
            #expect(contents.last == "cap-1099")
        }
    }

    @Test("enqueueing a burst coalesces UserDefaults saves instead of one per log")
    func saveThrottleCoalescesWrites() async throws {
        try await withIsolatedPersistence { defaults in
            initializeQuietAIPipe()
            AIPipe.resetQueueForTesting()

            for index in 0..<200 {
                AIPipe.log(withLevel: "INFO", content: "throttle-\(index)")
            }
            #expect(AIPipe.pendingLogCountForTesting() == 200)

            // 等节流窗口（1s）结束、落盘真正发生。窗口放宽到 20s，避免满载
            // 环境下的计时脆断；只收紧证据（落盘次数），不收紧等待时间。
            var persistedCount = 0
            for _ in 0..<200 {
                persistedCount = defaults.array(forKey: "AIPipeLogQueue")?.count ?? 0
                if persistedCount == 200 { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            #expect(persistedCount == 200)
            // 落盘必须进注入的 suite，而不是和运行中 App 共用的标准域。
            #expect(UserDefaults.standard.array(forKey: "AIPipeLogQueue")?.count != 200)

            // 旧实现每条日志一次全量落盘（这里会是 200 次）；节流后一个窗口
            // 只落一次，留余量容忍相邻窗口。
            let saves = Int(AIPipe.queueSaveCountForTesting())
            #expect(saves >= 1)
            #expect(saves <= 5)
        }
    }
}
