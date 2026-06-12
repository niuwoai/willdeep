//
//  AgentToolsCoreTests.swift
//  XeditTests
//
//  Covers the pure types and helpers in AgentTools that don't require
//  an open workspace or a launched Process: AgentToolRisk / Status /
//  ApprovalSource Codable contracts, AgentJSONValue's
//  decode/wrap/coerce path, AgentToolError messages, and the
//  shellEnvironment PATH-augmentation invariant used by run_command.
//

import Testing
import Foundation
@testable import WillDeep

@Suite
struct AgentToolsCoreTests {

    // MARK: - Risk / status enums

    /// Risk levels round-trip through JSON as their lowercase string
    /// names. Renaming a case silently here would corrupt every persisted
    /// session that had stored an in-flight tool call.
    @Test
    func toolRiskCodableRawValuesAreStable() throws {
        let cases: [(AgentToolRisk, String)] = [
            (.read,      "read"),
            (.write,     "write"),
            (.danger,    "danger"),
            (.userInput, "userInput")
        ]
        for (value, raw) in cases {
            let encoded = try JSONEncoder().encode([value])
            let str = String(data: encoded, encoding: .utf8) ?? ""
            #expect(str.contains("\"\(raw)\""))
            let decoded = try JSONDecoder().decode([AgentToolRisk].self, from: encoded)
            #expect(decoded.first == value)
        }
    }

    /// Tool-call status raw values are part of the on-disk session
    /// schema. Lock them in so a rename surfaces immediately.
    @Test
    func toolCallStatusRawValuesAreStable() {
        #expect(AgentToolCallStatus.pendingApproval.rawValue == "pendingApproval")
        #expect(AgentToolCallStatus.awaitingConfirm.rawValue == "awaitingConfirm")
        #expect(AgentToolCallStatus.awaitingUserAnswer.rawValue == "awaitingUserAnswer")
        #expect(AgentToolCallStatus.running.rawValue == "running")
        #expect(AgentToolCallStatus.succeeded.rawValue == "succeeded")
        #expect(AgentToolCallStatus.failed.rawValue == "failed")
        #expect(AgentToolCallStatus.denied.rawValue == "denied")
    }

    /// Approval source round-trips as a plain string. The UI uses these
    /// to badge auto-approved calls — drift here would mis-attribute
    /// approvals after a session reload.
    @Test
    func approvalSourceCodableRawValuesAreStable() throws {
        for source in [AgentToolApprovalSource.user,
                       .alwaysAllowList,
                       .staticAllowlist,
                       .llmJudge,
                       .goalMode,
                       .workspaceAccess,
                       .escalated,
                       .trustedServer] {
            let data = try JSONEncoder().encode([source])
            let decoded = try JSONDecoder().decode([AgentToolApprovalSource].self, from: data)
            #expect(decoded.first == source)
        }
    }

    // MARK: - AgentJSONValue.decode / wrap

    /// `decode(from:)` accepts a JSON fragment (an integer literal) and
    /// surfaces it as `.number`. Tool argument streams from the model
    /// arrive as JSON fragments, not always wrapped in `{}`.
    @Test
    func jsonValueDecodesIntegerFragment() {
        let value = AgentJSONValue.decode(from: "42")
        #expect(value == .number(42))
    }

    /// Booleans wrap as `.bool`. Note: JSONSerialization round-trips
    /// 0/1 numeric literals through NSNumber as char-type, so the
    /// existing `wrap` implementation treats them as `.bool`. We
    /// assert that contract here — non-0/1 numbers stay numeric.
    @Test
    func jsonValueWrapPreservesBool() {
        #expect(AgentJSONValue.decode(from: "true") == .bool(true))
        #expect(AgentJSONValue.decode(from: "false") == .bool(false))
        #expect(AgentJSONValue.decode(from: "42") == .number(42))
        #expect(AgentJSONValue.decode(from: "3.14") == .number(3.14))
    }

    /// Malformed JSON falls back to a `.string(raw)` so the call site
    /// always gets *something* back rather than blowing up — the runner
    /// then surfaces it to the model as a tool error.
    @Test
    func jsonValueDecodeFallsBackToStringOnMalformedJSON() {
        let value = AgentJSONValue.decode(from: "not { valid")
        #expect(value == .string("not { valid"))
    }

    /// Nested object/array shapes survive a wrap → rawAny round trip
    /// — the runner uses `rawAny` to feed `JSONSerialization` when it
    /// hands tool results back to the model.
    @Test
    func jsonValueWrapAndUnwrapNestedShapes() {
        let value = AgentJSONValue.decode(from: """
            {"items": [1, 2, "x"], "deep": {"k": true}}
            """)
        guard case .object(let dict) = value else {
            Issue.record("expected object, got \(value)")
            return
        }
        guard case .array(let items) = dict["items"] else {
            Issue.record("expected array under items")
            return
        }
        #expect(items.count == 3)
        #expect(items.last == .string("x"))
        guard case .object(let deep) = dict["deep"] else {
            Issue.record("expected nested object")
            return
        }
        #expect(deep["k"] == .bool(true))
    }

    // MARK: - AgentJSONValue coercions

    /// `intValue()` coerces both .number and numeric .string. Tool
    /// argument streams from the model may arrive either way.
    @Test
    func intValueCoercesNumberAndNumericString() {
        #expect(AgentJSONValue.number(7).intValue() == 7)
        #expect(AgentJSONValue.string("12").intValue() == 12)
        #expect(AgentJSONValue.string("abc").intValue() == nil)
        #expect(AgentJSONValue.null.intValue() == nil)
    }

    /// `boolValue()` understands the common textual variants the model
    /// might emit when a tool schema says "boolean" but it sends a
    /// string anyway.
    @Test
    func boolValueAcceptsCommonStringVariants() {
        #expect(AgentJSONValue.string("true").boolValue() == true)
        #expect(AgentJSONValue.string("YES").boolValue() == true)
        #expect(AgentJSONValue.string("1").boolValue() == true)
        #expect(AgentJSONValue.string("false").boolValue() == false)
        #expect(AgentJSONValue.string("no").boolValue() == false)
        #expect(AgentJSONValue.string("0").boolValue() == false)
        #expect(AgentJSONValue.string("maybe").boolValue() == nil)
    }

    /// `stringArrayValue` only succeeds when EVERY element is a string —
    /// partial matches return nil so we never silently drop the
    /// non-string entries.
    @Test
    func stringArrayValueAllOrNothing() {
        #expect(AgentJSONValue.array([.string("a"), .string("b")]).stringArrayValue() == ["a", "b"])
        #expect(AgentJSONValue.array([.string("a"), .number(1)]).stringArrayValue() == nil)
        #expect(AgentJSONValue.string("oops").stringArrayValue() == nil)
    }

    /// `displaySummary` truncates long strings at 80 chars + ellipsis.
    /// Used by the tool-call card in the chat UI — drift here would
    /// either crowd the row or hide useful prefixes.
    @Test
    func displaySummaryTruncatesLongStrings() {
        let long = String(repeating: "x", count: 200)
        let summary = AgentJSONValue.string(long).displaySummary
        #expect(summary.hasSuffix("…"))
        #expect(summary.count == 81)
    }

    /// Integer-valued doubles render without a decimal so the UI shows
    /// `5` not `5.0`.
    @Test
    func displaySummaryRendersIntegersWithoutDecimal() {
        #expect(AgentJSONValue.number(5).displaySummary == "5")
        #expect(AgentJSONValue.number(-3).displaySummary == "-3")
    }

    // MARK: - AgentToolError messages

    /// Tool error messages are surfaced to the model verbatim — locking
    /// in the prefixes catches accidental rewordings that would change
    /// the model's downstream behavior (it parses these strings).
    @Test
    func toolErrorMessagesUseStableFormat() {
        #expect(AgentToolError.missingArgument("path").errorDescription == "Missing argument: path")
        #expect(AgentToolError.noWorkspace.errorDescription == "Open a project folder before using this tool.")
        #expect(AgentToolError.pathOutsideWorkspace("/etc/passwd").errorDescription
                == "Path is outside the workspace: /etc/passwd")
        #expect(AgentToolError.notFound("/x").errorDescription == "Path does not exist: /x")
        #expect(AgentToolError.commandTimeout.errorDescription == "Command timed out.")
        #expect(AgentToolError.unknownTool("foo").errorDescription == "Unknown tool: foo")
    }

    /// Command failures include the exit code and trimmed stderr.
    /// Empty stderr falls back to a clean "status X" message rather
    /// than "status X: ".
    @Test
    func commandFailedTrimsStderrAndHandlesEmpty() {
        #expect(AgentToolError.commandFailed(127, "  not found  \n").errorDescription
                == "Command exited with status 127: not found")
        #expect(AgentToolError.commandFailed(1, "").errorDescription
                == "Command exited with status 1.")
        #expect(AgentToolError.commandFailed(1, "   \n").errorDescription
                == "Command exited with status 1.")
    }

    // MARK: - shellEnvironment

    /// `shellEnvironment` is the one-stop PATH builder used by
    /// run_command. It MUST augment the base PATH with the supplemental
    /// entries (Homebrew etc.) so spawned shells find user-installed
    /// tools. Test by passing a synthetic base environment so we don't
    /// depend on whatever the test runner inherits.
    @Test
    func shellEnvironmentAppendsSupplementalPathEntries() {
        let base: [String: String] = ["PATH": "/usr/bin:/bin"]
        let env = AgentToolRunner.shellEnvironment(from: base)
        let entries = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        // base entries preserved
        #expect(entries.contains("/usr/bin"))
        #expect(entries.contains("/bin"))
        // every supplemental entry added
        for entry in AgentToolRunner.supplementalCommandPathEntries {
            #expect(entries.contains(entry),
                    "expected supplemental PATH entry \(entry) to be present")
        }
    }

    /// Idempotent: if a supplemental entry was already on PATH we
    /// don't duplicate it. Otherwise the PATH grows unbounded across
    /// nested shells.
    @Test
    func shellEnvironmentDoesNotDuplicateExistingEntries() {
        guard let first = AgentToolRunner.supplementalCommandPathEntries.first else {
            Issue.record("supplementalCommandPathEntries is unexpectedly empty")
            return
        }
        let base: [String: String] = ["PATH": "/usr/bin:\(first)"]
        let env = AgentToolRunner.shellEnvironment(from: base)
        let occurrences = (env["PATH"] ?? "")
            .split(separator: ":")
            .filter { String($0) == first }
            .count
        #expect(occurrences == 1)
    }

    /// Non-PATH variables in the base environment are preserved
    /// verbatim — we only augment PATH.
    @Test
    func shellEnvironmentPreservesOtherVariables() {
        let base: [String: String] = [
            "PATH": "/usr/bin",
            "HOME": "/Users/test",
            "LANG": "en_US.UTF-8"
        ]
        let env = AgentToolRunner.shellEnvironment(from: base)
        #expect(env["HOME"] == "/Users/test")
        #expect(env["LANG"] == "en_US.UTF-8")
    }

    // MARK: - AgentSandboxPolicy

    @Test
    func sandboxPolicyKeepsReadOnlyCommandsInsideReadOnlyMode() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-workspace")
        let decision = AgentSandboxPolicy.commandDecision(
            command: "pwd && rg AgentSandboxPolicy .",
            rootDirectory: root
        )
        #expect(decision.mode == .readOnly)
        #expect(decision.requiresUserApproval == false)
        #expect(decision.requiresTypedConfirmation == false)
    }

    @Test
    func sandboxPolicyRequiresEscalationForNetworkAndCredentialCommands() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-workspace")
        let decision = AgentSandboxPolicy.commandDecision(
            command: "gh auth status",
            rootDirectory: root
        )
        #expect(decision.mode == .escalated)
        #expect(decision.requiresUserApproval == true)
        #expect(decision.requiresTypedConfirmation == false)
        #expect(decision.prefixRule == ["gh", "auth"])
    }

    @Test
    func sandboxPolicyRequiresConfirmationForOutsideWorkspacePaths() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-workspace")
        let decision = AgentSandboxPolicy.commandDecision(
            command: "cat /Users/rocky/.ssh/id_ed25519",
            rootDirectory: root
        )
        #expect(decision.mode == .escalated)
        #expect(decision.requiresUserApproval == true)
        #expect(decision.requiresTypedConfirmation == true)
    }

    @Test
    func sandboxedEnvironmentScrubsSecretsAndUsesTemporaryHome() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-workspace")
        let env = AgentSandboxPolicy.sandboxedEnvironment(
            mode: .workspaceWrite,
            rootDirectory: root,
            base: [
                "PATH": "/usr/bin",
                "HOME": "/Users/real",
                "GITHUB_TOKEN": "ghp_should_not_survive",
                "MY_SECRET": "secret-value",
                "LANG": "en_US.UTF-8"
            ]
        )
        #expect(env["GITHUB_TOKEN"] == nil)
        #expect(env["MY_SECRET"] == nil)
        #expect(env["LANG"] == "en_US.UTF-8")
        #expect(env["HOME"] != "/Users/real")
        #expect(env["WILLDEEP_AGENT_SANDBOX"] == AgentSandboxMode.workspaceWrite.rawValue)
        #expect(env["WILLDEEP_WORKSPACE_ROOT"] == root.path)
    }

    @Test
    func sandboxLaunchWrapsNonEscalatedCommandsWhenSeatbeltIsAvailable() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-workspace")
        let launch = AgentSandboxPolicy.shellLaunch(
            command: "pwd",
            mode: .readOnly,
            rootDirectory: root
        )
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") {
            #expect(launch.executableURL.path == "/usr/bin/sandbox-exec")
            #expect(launch.arguments.contains("/bin/sh"))
            #expect(launch.arguments.contains("pwd"))
        } else {
            #expect(launch.executableURL.path == "/bin/sh")
        }
    }
}

@Suite
struct AgentQueueModeTests {
    @Test
    @MainActor
    func stopAgentResponseDeniesAwaitingUserAnswer() {
        let state = AppState()
        _ = state.startNewAgentSession()
        guard let runtime = state.activeRuntime else {
            Issue.record("Expected active runtime")
            return
        }

        let callID = UUID()
        runtime.isResponding = true
        runtime.toolCalls = [
            AgentToolCall(
                id: callID,
                messageID: UUID(),
                externalID: "ask-user-1",
                toolName: "ask_user",
                arguments: [:],
                risk: .userInput,
                status: .awaitingUserAnswer
            )
        ]

        state.stopAgentResponse()

        #expect(runtime.toolCalls.first?.status == .denied)
        #expect(runtime.toolCalls.first?.errorMessage == "Response stopped")
    }

    @Test
    @MainActor
    func sendingQueuedMessageNowDeniesAwaitingUserAnswer() {
        let state = AppState()
        _ = state.startNewAgentSession()
        guard let runtime = state.activeRuntime else {
            Issue.record("Expected active runtime")
            return
        }

        let queued = AgentQueuedMessage(id: UUID(), text: "next please")
        runtime.isResponding = true
        runtime.queuedMessages = [queued]
        runtime.toolCalls = [
            AgentToolCall(
                messageID: UUID(),
                externalID: "ask-user-1",
                toolName: "ask_user",
                arguments: [:],
                risk: .userInput,
                status: .awaitingUserAnswer
            )
        ]

        state.sendQueuedAgentMessageNow(id: queued.id)

        #expect(runtime.toolCalls.first?.status == .denied)
        #expect(runtime.toolCalls.first?.errorMessage == "Sending queued message")
        #expect(runtime.queuedMessages.first?.id == queued.id)
    }
}
