import Foundation
import Testing
@testable import WillDeep

/// Contract for the always-allow file shared with the willdeep-rs CLI.
///
/// These are not "does my code work" tests so much as "does my code still obey
/// someone else's file format" tests. Everything asserted here has a
/// counterpart in `willdeep-core::tools` (`command_signature`,
/// `with_always_allow_store`, `persist_always_allowed`); when that side moves,
/// this suite is where it should hurt first.
@Suite
struct AgentSharedAlwaysAllowStoreTests {
    private static func temporaryStore(_ name: String) -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("willdeep-shared-allow-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("always-allow.json")
    }

    @Test("published rules use the CLI's exact-command prefix and normalization")
    func signatureMatchesTheRustContract() {
        #expect(
            AgentSharedAlwaysAllowStore.exactCommandSignature(for: " cargo   test --all ")
                == "command-exact:cargo test --all"
        )
        // Shell composition is refused on both sides: the pinned text would no
        // longer be a single command.
        for composed in [
            "cargo test && deploy",
            "ls | grep foo",
            "echo hi > out.txt",
            "cat a; cat b",
        ] {
            #expect(
                AgentSharedAlwaysAllowStore.exactCommandSignature(for: composed) == nil,
                "shell composition must not mint a rule: \(composed)"
            )
        }
        #expect(AgentSharedAlwaysAllowStore.exactCommandSignature(for: "   ") == nil)
    }

    /// The CLI stopped minting credential-bearing rules in 0.39.0-rc2 and
    /// prunes old ones on load. If this side published them anyway the leak
    /// would just reappear from a different process, so the guard is mirrored
    /// here rather than assumed.
    @Test("commands carrying credentials are never published")
    func credentialCommandsAreNeverPublished() {
        for command in [
            "MODEL_API_KEY=sk_live_0123456789abcdef ruby scripts/probe.rb",
            "curl -H Authorization: Bearer sk-0123456789abcdef https://example.com",
            "mysql --password hunter2 -e select",
            "deploy --token ghp_0123456789abcdef",
            "publish sk-0123456789abcdefghij",
        ] {
            #expect(
                AgentSharedAlwaysAllowStore.carriesCredentials(command),
                "must be recognised as credential-bearing: \(command)"
            )
            #expect(
                AgentSharedAlwaysAllowStore.exactCommandSignature(for: command) == nil,
                "must not mint a rule: \(command)"
            )
        }

        // The guard must not swallow ordinary commands that merely mention a
        // credential-shaped word without a value.
        for command in ["grep -r api_key src", "cargo test --all", "git push origin main"] {
            #expect(
                !AgentSharedAlwaysAllowStore.carriesCredentials(command),
                "ordinary command misread as credential-bearing: \(command)"
            )
        }
    }

    @Test("a rule the CLI pinned is honored here, and only for that exact command")
    func cliRulesAreHonoredExactly() throws {
        let store = Self.temporaryStore("read")
        try Data(#"["command-exact:cargo test --all"]"#.utf8).write(to: store)

        #expect(AgentSharedAlwaysAllowStore.allows(command: "cargo test --all", in: store))
        // Whitespace differences are normalized away, exactly as the CLI does.
        #expect(AgentSharedAlwaysAllowStore.allows(command: "cargo  test   --all", in: store))
        // A wider command in the same family is a different rule. Honoring it
        // would turn the CLI's exact-command pin into a family pin behind the
        // operator's back.
        #expect(!AgentSharedAlwaysAllowStore.allows(command: "cargo test --all -- --nocapture", in: store))
        #expect(!AgentSharedAlwaysAllowStore.allows(command: "cargo test", in: store))
    }

    @Test("publishing merges with what the CLI already wrote and keeps 0600")
    func publishingPreservesForeignRulesAndMode() throws {
        let store = Self.temporaryStore("write")
        let foreign = "command-exact:cargo build --release"
        try Data("[\"\(foreign)\"]".utf8).write(to: store)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.path)

        #expect(AgentSharedAlwaysAllowStore.publish(command: "git push origin main", to: store))

        let rules = AgentSharedAlwaysAllowStore.loadRules(from: store)
        #expect(rules.contains(foreign), "a blind overwrite would drop the CLI's rules")
        #expect(rules.contains("command-exact:git push origin main"))

        // The CLI refuses the entire store when the mode has group/other bits
        // (`with_always_allow_store` returns PermissionDenied), which would
        // break every CLI run rather than just this feature.
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.int16Value == 0o600)
    }

    @Test("publishing is idempotent and refuses what the CLI could not match")
    func publishingIsIdempotentAndBounded() throws {
        let store = Self.temporaryStore("idempotent")

        #expect(AgentSharedAlwaysAllowStore.publish(command: "cargo test --all", to: store))
        #expect(AgentSharedAlwaysAllowStore.publish(command: "cargo  test --all", to: store))
        #expect(AgentSharedAlwaysAllowStore.loadRules(from: store).count == 1)

        #expect(!AgentSharedAlwaysAllowStore.publish(command: "cargo test && deploy", to: store))
        #expect(!AgentSharedAlwaysAllowStore.publish(
            command: "API_KEY=sk_live_0123456789abcdef deploy", to: store
        ))
        #expect(AgentSharedAlwaysAllowStore.loadRules(from: store).count == 1)
    }

    /// Rules this app cannot represent belong to the CLI and must survive a
    /// round trip untouched — dropping them would silently un-pin the other
    /// side's decisions.
    @Test("unknown rule shapes are preserved rather than dropped")
    func foreignRuleShapesSurvive() throws {
        let store = Self.temporaryStore("foreign")
        try Data(#"["future-rule-kind:something","command-exact:ls -la"]"#.utf8).write(to: store)

        #expect(AgentSharedAlwaysAllowStore.publish(command: "git status", to: store))

        let rules = AgentSharedAlwaysAllowStore.loadRules(from: store)
        #expect(rules.contains("future-rule-kind:something"))
        #expect(rules.count == 3)
        // Unknown shapes are carried, not matched.
        #expect(AgentSharedAlwaysAllowStore.exactCommands(from: store).count == 2)
    }

    @Test("a missing store is an empty rule set, not a failure")
    func missingStoreIsEmpty() {
        let store = Self.temporaryStore("absent")
        #expect(AgentSharedAlwaysAllowStore.loadRules(from: store).isEmpty)
        #expect(!AgentSharedAlwaysAllowStore.allows(command: "cargo test", in: store))
    }

    @Test("the store path follows WILLDEEP_HOME the same way the config reader does")
    func storePathMatchesTheConfigConvention() {
        let configDirectory = AgentAttentionPreferencesStore.defaultConfigURL()
            .deletingLastPathComponent()
        #expect(
            AgentSharedAlwaysAllowStore.defaultStoreURL().deletingLastPathComponent().path
                == configDirectory.path
        )
        #expect(AgentSharedAlwaysAllowStore.defaultStoreURL().lastPathComponent == "always-allow.json")
    }
}
