import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentDelegationPolicyTests {
    // MARK: Tool-table enforcement

    @Test("/no-subagent removes spawn_agent from the turn's tool table")
    func forbiddenRemovesSpawnAgent() {
        let tools = AgentToolRegistry.tools(
            activeExperts: [],
            delegationPolicy: .forbidden
        )

        #expect(!tools.contains { $0.name == "spawn_agent" })
        // Only the one tool is affected — the rest of the set is untouched.
        #expect(tools.contains { $0.name == "read_file" })
    }

    @Test("automatic and required both keep spawn_agent available")
    func nonForbiddenPoliciesKeepSpawnAgent() {
        for policy in [AgentDelegationPolicy.automatic, .agentPreferred, .required] {
            let tools = AgentToolRegistry.tools(
                activeExperts: [],
                delegationPolicy: policy
            )
            #expect(tools.contains { $0.name == "spawn_agent" }, "policy: \(policy.rawValue)")
        }
    }

    @Test("default tool table is unchanged when no policy is passed")
    func defaultPolicyMatchesAutomatic() {
        let implicit = AgentToolRegistry.tools(activeExperts: []).map(\.name)
        let explicit = AgentToolRegistry.tools(
            activeExperts: [],
            delegationPolicy: .automatic
        ).map(\.name)

        #expect(implicit == explicit)
    }

    // MARK: Honor accounting

    @Test("required is honored only when the turn actually spawned")
    func requiredIsHonoredOnlyWhenSpawned() {
        #expect(!AgentDelegationPolicy.required.isHonored(spawnCallCount: 0))
        #expect(AgentDelegationPolicy.required.isHonored(spawnCallCount: 1))
    }

    @Test("policies with nothing to honor never report a violation")
    func nonRequiredPoliciesAlwaysHonored() {
        #expect(AgentDelegationPolicy.automatic.isHonored(spawnCallCount: 0))
        // Forbidden is enforced by the tool table, so a zero count is the
        // expected outcome and must not be flagged.
        #expect(AgentDelegationPolicy.forbidden.isHonored(spawnCallCount: 0))
    }

    // MARK: Prompt injection

    @Test("only explicit policies inject a system-prompt directive")
    func promptInstructionOnlyForExplicitPolicies() throws {
        #expect(AgentDelegationPolicy.automatic.systemPromptInstruction == nil)

        let required = try #require(AgentDelegationPolicy.required.systemPromptInstruction)
        #expect(required.contains("spawn_agent"))
        let forbidden = try #require(AgentDelegationPolicy.forbidden.systemPromptInstruction)
        #expect(forbidden.contains("spawn_agent"))
    }

    @Test("isExplicit distinguishes slash-selected policies from the default")
    func isExplicitFlag() {
        #expect(!AgentDelegationPolicy.automatic.isExplicit)
        #expect(AgentDelegationPolicy.required.isExplicit)
        #expect(AgentDelegationPolicy.forbidden.isExplicit)
    }

    // MARK: Transcript marker

    @Test("an unhonored required turn reports that instead of claiming success")
    func markerReportsUnhonoredRequiredTurn() {
        let honored = AgentMessage(
            role: .user,
            content: "investigate",
            delegationPolicy: .required,
            delegationPolicyUnhonored: false
        )
        let unhonored = AgentMessage(
            role: .user,
            content: "investigate",
            delegationPolicy: .required,
            delegationPolicyUnhonored: true
        )

        #expect(honored.delegationMarkerTitle == L10n.AgentDelegation.markerRequired)
        #expect(unhonored.delegationMarkerTitle == L10n.AgentDelegation.markerRequiredNotHonored)
    }

    @Test("messages without an explicit directive show no marker")
    func noMarkerWithoutPolicy() {
        let message = AgentMessage(role: .user, content: "plain turn")

        #expect(message.delegationMarkerTitle == nil)
        #expect(message.delegationMarkerSymbol == nil)
    }

    // MARK: Persistence

    @Test("delegation fields survive a session encode/decode round trip")
    func messageCodableRoundTrip() throws {
        let original = AgentMessage(
            role: .user,
            content: "investigate the tenant permission model",
            delegationPolicy: .forbidden,
            delegationPolicyUnhonored: false
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: data)

        #expect(decoded.delegationPolicy == .forbidden)
        #expect(decoded.delegationPolicyUnhonored == false)
    }

    @Test("sessions written before these fields existed still decode")
    func messageDecodesWithoutDelegationFields() throws {
        let legacyJSON = """
        {
          "id": "\(UUID().uuidString)",
          "role": "user",
          "content": "older session",
          "images": [],
          "textAttachments": [],
          "toolCalls": [],
          "sourceReferences": [],
          "createdAt": 760000000
        }
        """

        let decoded = try JSONDecoder().decode(
            AgentMessage.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(decoded.delegationPolicy == nil)
        #expect(decoded.delegationPolicyUnhonored == nil)
        #expect(decoded.delegationMarkerTitle == nil)
    }

    // MARK: Slash commands

    @Test("both delegation commands are registered and resolve by exact name")
    func slashCommandsAreRegistered() throws {
        let commands = SlashCommand.builtIn(state: AppState())

        let subagent = try #require(commands.first { $0.title == "/subagent" })
        let noSubagent = try #require(commands.first { $0.title == "/no-subagent" })
        // Both are pointless without a prompt to run.
        #expect(subagent.argumentMode.requiresArguments)
        #expect(noSubagent.argumentMode.requiresArguments)
    }

    @Test("invocation splits the command from its prompt")
    func slashCommandInvocationParsing() throws {
        let commands = SlashCommand.builtIn(state: AppState())

        let invocation = try #require(
            SlashCommand.invocation(in: "/no-subagent check the auth flow", commands: commands)
        )

        #expect(invocation.command.title == "/no-subagent")
        #expect(invocation.args == "check the auth flow")
    }

    @Test("the palette finds /no-subagent under the names people actually type")
    func slashCommandAliasesResolve() throws {
        let commands = SlashCommand.builtIn(state: AppState())
        let canonical = try #require(commands.first { $0.title == "/no-subagent" })

        // The bug this guards: the palette filters on substrings of the id and
        // title, so the hyphen made "/noagent" match nothing at all and the
        // feature read as missing.
        for typed in ["/noagent", "/nosubagent", "/no-agent", "/solo", "/NoAgent"] {
            let matches = SlashCommand.filter(typed, allCommands: commands)
            #expect(matches.contains { $0.id == canonical.id }, "no match for \(typed)")
        }

        // Enter on an exact alias runs the command rather than sending prose.
        let invocation = try #require(
            SlashCommand.invocation(in: "/noagent check the auth flow", commands: commands)
        )
        #expect(invocation.command.title == "/no-subagent")
        #expect(invocation.args == "check the auth flow")

        // Prose that merely starts with a slash still falls through to send.
        #expect(SlashCommand.invocation(in: "/usr/bin/env is missing", commands: commands) == nil)
    }

    @Test("queued messages carry their directive to the drained turn")
    func queuedMessageCarriesPolicy() {
        let queued = AgentQueuedMessage(text: "later", delegationPolicy: .required)

        #expect(queued.delegationPolicy == .required)
        // Ordinary sends stay on the default.
        #expect(AgentQueuedMessage(text: "later").delegationPolicy == .automatic)
    }
}
