import Testing
@testable import WillDeep

@Suite
@MainActor
struct AIPipeBootstrapTests {
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
