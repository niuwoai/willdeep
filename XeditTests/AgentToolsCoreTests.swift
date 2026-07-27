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
import AppKit
import CoreGraphics
import Foundation
@testable import WillDeep

@Suite
@MainActor
struct AgentToolsCoreTests {
    private static let headlessCommandTimeoutSeconds = 30.0

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

    @Test("session mutation tools are write-tier and invoke host sinks")
    func sessionMutationToolsUseApprovedHostActions() async throws {
        #expect(AgentToolRegistry.descriptor(for: "rename_session")?.risk == .write)
        #expect(AgentToolRegistry.descriptor(for: "change_workspace")?.risk == .write)
        let normalToolNames = Set(AgentToolRegistry.tools(activeExperts: []).map(\.name))
        let goalToolNames = Set(AgentToolRegistry.tools(activeExperts: [], interactionMode: .goal).map(\.name))
        #expect(normalToolNames.contains("rename_session"))
        #expect(normalToolNames.contains("change_workspace"))
        #expect(goalToolNames.contains("rename_session"))
        #expect(!goalToolNames.contains("change_workspace"))

        var renamedTitle: String?
        var changedPath: String?
        let context = AgentToolContext(
            rootDirectory: nil,
            sessionRenameSink: { title in
                renamedTitle = title
                return title
            },
            workspaceChangeSink: { path in
                changedPath = path
                return path
            }
        )

        let renameResult = try await AgentToolRunner.run(
            name: "rename_session",
            arguments: ["title": .string("  Workspace   migration \n")],
            context: context
        )
        let workspaceResult = try await AgentToolRunner.run(
            name: "change_workspace",
            arguments: ["path": .string("/tmp/example")],
            context: context
        )

        #expect(renamedTitle == "Workspace migration")
        #expect(renameResult.payload.contains("Workspace migration"))
        #expect(changedPath == "/tmp/example")
        #expect(workspaceResult.payload.contains("Stop"))

        let appState = AppState()
        let renameAutoApproval = await appState.autoApprovalSource(
            toolName: "rename_session",
            arguments: [:],
            risk: .write,
            rootDirectory: nil,
            interactionMode: .goal
        )
        #expect(renameAutoApproval == .goalMode)

        let workspaceAutoApproval = await appState.autoApprovalSource(
            toolName: "change_workspace",
            arguments: [:],
            risk: .write,
            rootDirectory: nil,
            interactionMode: .goal
        )
        #expect(workspaceAutoApproval == nil)
    }

    @Test
    func delegatedCodingToolsRespectExecutionAgentAndMode() {
        let delegatedTools: Set<String> = ["claude_code", "codex_cli", "cursor_agent", "cline_cli"]

        let willDeepNormal = Set(AgentToolRegistry.tools(
            activeExperts: [],
            interactionMode: .normal,
            executionAgent: .willDeep
        ).map(\.name))
        let willDeepPlan = Set(AgentToolRegistry.tools(
            activeExperts: [],
            interactionMode: .plan,
            executionAgent: .willDeep
        ).map(\.name))
        let willDeepGoal = Set(AgentToolRegistry.tools(
            activeExperts: [],
            interactionMode: .goal,
            executionAgent: .willDeep
        ).map(\.name))
        let codexSelected = Set(AgentToolRegistry.tools(
            activeExperts: [],
            interactionMode: .normal,
            executionAgent: .codexCLI
        ).map(\.name))
        let cursorSelected = Set(AgentToolRegistry.tools(
            activeExperts: [],
            interactionMode: .normal,
            executionAgent: .cursorAgent
        ).map(\.name))
        let clineSelected = Set(AgentToolRegistry.tools(
            activeExperts: [],
            interactionMode: .normal,
            executionAgent: .clineCLI
        ).map(\.name))

        #expect(willDeepNormal.isDisjoint(with: delegatedTools))
        #expect(willDeepPlan.isDisjoint(with: delegatedTools))
        #expect(delegatedTools.isSubset(of: willDeepGoal))
        #expect(!willDeepGoal.contains("change_workspace"))
        #expect(codexSelected.intersection(delegatedTools) == ["codex_cli"])
        #expect(cursorSelected.intersection(delegatedTools) == ["cursor_agent"])
        #expect(clineSelected.intersection(delegatedTools) == ["cline_cli"])
    }

    @Test("terminal protected-input payload exposes only prompts, never values")
    func terminalProtectedInputPromptSetParsesPendingPrompts() {
        let shortcutID = UUID()
        let payload = """
        {
          "id": "\(shortcutID.uuidString)",
          "title": "Deploy staging",
          "events": [
            {"index": 2, "kind": "protected_placeholder", "placeholder": "Staging password", "needs_value": true},
            {"index": 3, "kind": "protected_echo_off_input", "needs_value": false}
          ]
        }
        """

        let promptSet = TerminalShortcutProtectedPromptSet.parse(payload: payload)
        #expect(promptSet?.shortcutID == shortcutID)
        #expect(promptSet?.title == "Deploy staging")
        #expect(promptSet?.prompts == [
            TerminalShortcutProtectedPrompt(eventIndex: 2, label: "Staging password")
        ])
    }

    /// The provider-error headline extracts the server's own message from a
    /// JSON error body across the common shapes, so a 403 like
    /// `token_plan_required` shows "requires an active Coding Plan
    /// subscription" instead of a misleading "check your API key" guess.
    @Test
    func providerErrorMessageExtractsServerExplanation() {
        // some.im shape: top-level message + short error code.
        let someIM = #"{"error":"token_plan_required","message":"model someim-coding-plan-low requires an active Coding Plan subscription"}"#
        let someIMResult = AppState.providerErrorMessage(from: someIM)
        #expect(someIMResult?.contains("requires an active Coding Plan subscription") == true)
        #expect(someIMResult?.contains("token_plan_required") == true)

        // OpenAI/Anthropic shape: nested error object.
        #expect(AppState.providerErrorMessage(
            from: #"{"error":{"message":"Invalid API key","type":"auth"}}"#) == "Invalid API key")

        // Bare string error.
        #expect(AppState.providerErrorMessage(from: #"{"error":"rate limited"}"#) == "rate limited")

        // Non-JSON / empty → nil (caller falls back to the status-code hint).
        #expect(AppState.providerErrorMessage(from: "<html>502 Bad Gateway</html>") == nil)
        #expect(AppState.providerErrorMessage(from: "   ") == nil)
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

    /// Goal mode fast-approves sandbox-contained write tools but must route
    /// every command-shaped call through the static-classify → LLM-judge
    /// gate, so a dangerous command pauses for the user instead of being
    /// blanket-approved. This locks the exact membership the goal-mode
    /// fast-path in `autoApprovalSource` keys off of.
    @Test
    func commandShapedToolsAreExcludedFromGoalModeBlanketApproval() {
        for name in ["run_command", "terminal_send_command",
                     "terminal_send_control", "call_mcp_tool"] {
            #expect(AppState.isCommandShapedTool(name),
                    "\(name) must stay judge-gated even in goal mode")
        }
        for name in ["write_file", "apply_patch", "web_fetch",
                     "visual_qa_screenshot", "add_memory"] {
            #expect(!AppState.isCommandShapedTool(name),
                    "\(name) is sandbox-contained and may be goal fast-pathed")
        }
    }

    /// Delegated coding agents (Claude Code / Codex / Cursor / Cline) ship
    /// their own approval + sandbox review, so they auto-approve by default.
    /// Locks the exact membership `autoApprovalSource` keys off of — a rename
    /// or a new delegated agent must be added deliberately.
    @Test
    func trustedDelegatedAgentToolsAreRecognized() {
        for name in ["claude_code", "codex_cli", "cursor_agent", "cline_cli"] {
            #expect(AppState.isTrustedDelegatedAgentTool(name),
                    "\(name) should auto-approve as a trusted delegated agent")
        }
        for name in ["run_command", "spawn_agent", "write_file", "call_mcp_tool", "lark_cli"] {
            #expect(!AppState.isTrustedDelegatedAgentTool(name),
                    "\(name) is not a trusted delegated coding agent")
        }
    }

    /// A destructive, typed-confirmation command can never reach the safety
    /// judge — it always falls back to a human. Goal mode relies on this so
    /// `rm -rf` / force-push style ops pause instead of auto-running.
    @Test
    func typedConfirmationCommandsNeverReachSafetyJudge() {
        let destructive = AgentSandboxDecision(
            mode: .workspaceWrite,
            requiresUserApproval: true,
            requiresTypedConfirmation: true,
            reason: "destructive",
            prefixRule: nil
        )
        #expect(!AppState.canSendToSafetyJudge(
            toolName: "run_command", sandboxDecision: destructive))

        let ordinary = AgentSandboxDecision(
            mode: .workspaceWrite,
            requiresUserApproval: true,
            requiresTypedConfirmation: false,
            reason: "write",
            prefixRule: nil
        )
        #expect(AppState.canSendToSafetyJudge(
            toolName: "run_command", sandboxDecision: ordinary))
    }

    @Test
    func delegatedComposerApprovalSourceTreatsExecutorSelectionAsUserApproval() {
        #expect(AppState.delegatedComposerApprovalSource(risk: .read) == nil)
        #expect(AppState.delegatedComposerApprovalSource(risk: .write) == .user)
        #expect(AppState.delegatedComposerApprovalSource(risk: .danger) == .user)
    }

    @Test
    func visualQAScreenshotToolRequiresApprovalAndDocumentsBoundary() throws {
        let descriptor = try #require(AgentToolRegistry.descriptor(for: "visual_qa_screenshot"))
        #expect(descriptor.risk == .write)
        #expect(descriptor.description.contains("Image Understanding"))
        #expect(descriptor.description.contains("allow_vl"))
        #expect(descriptor.parameters.contains { $0.name == "path" && $0.required })
        #expect(descriptor.parameters.contains { $0.name == "allow_vl" && !$0.required })
    }

    @Test
    func visualQAScreenshotCanRunLocalOnly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-visual-qa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageURL = directory.appendingPathComponent("light-screen.png")
        let image = ImageWorkflowSupport.render(width: 16, height: 12, background: .white) { context in
            context.setFillColor(ImageWorkflowSupport.RGBAColor.black.nsColor.cgColor)
            context.fill(CGRect(x: 2, y: 2, width: 4, height: 4))
        }
        try ImageWorkflowSupport.save(image, to: imageURL, format: "png")

        let result = try await AgentToolRunner.run(
            name: "visual_qa_screenshot",
            arguments: [
                "path": .string(imageURL.path),
                "allow_vl": .bool(false),
                "focus": .string("colors")
            ],
            context: AgentToolContext(rootDirectory: nil, sandboxMode: .readOnly)
        )

        #expect(result.summary.contains("light-screen.png"))
        #expect(result.payload.contains("# Visual QA Screenshot"))
        #expect(result.payload.contains("Theme estimate:"))
        #expect(result.payload.contains("Dominant palette:"))
        #expect(result.payload.contains("VL analysis: skipped because `allow_vl=false`"))
    }

    @Test
    func agentImagePasteboardHelperReadsNSImageScreenshots() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("willdeep-image-paste-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let image = NSImage(size: NSSize(width: 12, height: 8))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 12, height: 8).fill()
        image.unlockFocus()

        #expect(pasteboard.writeObjects([image]) == true)
        #expect(AgentImagePasteboardHelper.pasteboardHasImage(pasteboard) == true)

        let images = AgentImagePasteboardHelper.readImages(from: pasteboard)
        let first = try #require(images.first)
        #expect(first.mimeType == "image/png")
        #expect(NSImage(data: first.data) != nil)
    }

    @Test
    func agentImagePasteboardHelperDeduplicatesEquivalentImageItems() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("willdeep-image-dedupe-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let image = NSImage(size: NSSize(width: 12, height: 8))
        image.lockFocus()
        NSColor.systemGreen.setFill()
        NSRect(x: 0, y: 0, width: 12, height: 8).fill()
        image.unlockFocus()
        let png = try #require(AgentToolsCoreTests.pngData(for: image))
        let first = NSPasteboardItem()
        first.setData(png, forType: .png)
        let second = NSPasteboardItem()
        second.setData(png, forType: .png)

        #expect(pasteboard.writeObjects([first, second]) == true)

        let images = AgentImagePasteboardHelper.readImages(from: pasteboard)
        #expect(images.count == 1)
        #expect(images.first?.data == png)
    }

    private static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    @Test
    func runCommandClosesStandardInputForHeadlessCLIs() async throws {
        let result = try await AgentToolRunner.run(
            name: "run_command",
            arguments: [
                "command": .string("read value || true; printf 'done:%s\\n' \"$value\""),
                "timeout_seconds": .number(Self.headlessCommandTimeoutSeconds),
            ],
            context: AgentToolContext(rootDirectory: nil, sandboxMode: .escalated)
        )

        #expect(result.payload.contains("done:"))
    }

    @Test
    func agentSecretPlaceholdersResolveLocallyWithTransforms() throws {
        let service = AgentCredentialStore._setTestKeychainServiceOverride("agent-secret-\(UUID().uuidString)")
        defer {
            AgentCredentialStore._wipeTestKeychain()
            AgentCredentialStore._setTestKeychainServiceOverride(nil)
        }
        #expect(service.hasPrefix("agent-secret-"))

        let secret = " p@ss word&role=admin "
        let placeholder = try #require(AgentSecretStore.saveSecret(secret, label: "Production Password"))
        #expect(placeholder == "${secret:production-password}")
        #expect(!placeholder.contains("p@ss word"))

        let saved = AgentSecretStore.savedSecrets()
        #expect(saved.count == 1)
        #expect(saved.first?.label == "Production Password")
        #expect(saved.first?.identifier == "production-password")

        let raw = AgentSecretStore.resolvePlaceholders(in: "value=\(placeholder)")
        #expect(raw.text == "value=\(secret)")
        #expect(raw.secretValues == [secret])

        let identifier = placeholder
            .replacingOccurrences(of: AgentSecretStore.placeholderPrefix, with: "")
            .replacingOccurrences(of: "}", with: "")
        let encoded = AgentSecretStore.resolvePlaceholders(
            in: AgentSecretStore.placeholder(identifier: identifier, transform: "base64")
        )
        #expect(encoded.text == "IHBAc3Mgd29yZCZyb2xlPWFkbWluIA==")

        let urlEncoded = AgentSecretStore.resolvePlaceholders(
            in: AgentSecretStore.placeholder(identifier: identifier, transform: "urlencode")
        )
        #expect(urlEncoded.text == "%20p%40ss%20word%26role%3Dadmin%20")

        let redactedStrictEncoding = AgentSecretStore.redact(
            "encoded=%20p%40ss%20word%26role%3Dadmin%20",
            secretValues: [secret]
        )
        #expect(redactedStrictEncoding == "encoded=[secret]")
    }

    @Test
    func agentSecretAliasesAreNormalizedAndUpdateExistingValues() throws {
        _ = AgentCredentialStore._setTestKeychainServiceOverride("agent-secret-alias-\(UUID().uuidString)")
        defer {
            AgentCredentialStore._wipeTestKeychain()
            AgentCredentialStore._setTestKeychainServiceOverride(nil)
        }

        #expect(AgentSecretStore.normalizedAlias("  Production / SSH Password  ") == "production-ssh-password")
        #expect(AgentSecretStore.normalizedAlias("生产 SSH 密码") == "生产-ssh-密码")

        let original = try #require(AgentSecretStore.saveSecret("old-value", label: "Production SSH Password"))
        let updated = try #require(AgentSecretStore.saveSecret("new-value", label: "production ssh password"))
        #expect(original == updated)
        #expect(AgentSecretStore.savedSecrets().count == 1)

        let resolved = AgentSecretStore.resolvePlaceholders(in: updated)
        #expect(resolved.text == "new-value")
        #expect(resolved.secretValues == ["new-value"])

        let legacyIdentifier = "d12c00b05721481ebf82bff83ffe3776"
        AgentCredentialStore.save("legacy-value", account: "agent-secret/\(legacyIdentifier)")
        let saved = AgentSecretStore.savedSecrets()
        #expect(saved.count == 2)
        #expect(saved.contains { $0.identifier == legacyIdentifier && $0.label.isEmpty })
        #expect(
            AgentSecretStore.resolvePlaceholders(
                in: AgentSecretStore.placeholder(identifier: legacyIdentifier)
            ).text == "legacy-value"
        )

        let source = "run \(updated) now"
        let match = try #require(AgentSecretStore.placeholderMatches(in: source).first)
        #expect((source as NSString).substring(with: match.range) == updated)
        #expect(match.identifier == "production-ssh-password")
    }

    @Test
    func agentSecretBatchInsertCapsAtThreePlaceholders() throws {
        _ = AgentCredentialStore._setTestKeychainServiceOverride("agent-secret-batch-\(UUID().uuidString)")
        defer {
            AgentCredentialStore._wipeTestKeychain()
            AgentCredentialStore._setTestKeychainServiceOverride(nil)
        }

        let placeholders = AgentSecretStore.saveSecrets([
            AgentSecretInput(label: "First", secret: "first-secret"),
            AgentSecretInput(label: "Blank", secret: "   "),
            AgentSecretInput(label: "Second", secret: "second-secret"),
            AgentSecretInput(label: "Third", secret: "third-secret"),
            AgentSecretInput(label: "Fourth", secret: "fourth-secret"),
        ])

        #expect(AgentSecretStore.maxBatchInsertCount == 3)
        #expect(placeholders.count == 3)
        #expect(placeholders == ["${secret:first}", "${secret:second}", "${secret:third}"])
        let resolved = AgentSecretStore.resolvePlaceholders(in: placeholders.joined(separator: " "))
        #expect(resolved.secretValues == ["first-secret", "second-secret", "third-secret"])
        #expect(!resolved.text.contains("fourth-secret"))
    }

    @Test
    func runCommandResolvesSecretPlaceholderButRedactsOutputs() async throws {
        _ = AgentCredentialStore._setTestKeychainServiceOverride("agent-secret-run-\(UUID().uuidString)")
        defer {
            AgentCredentialStore._wipeTestKeychain()
            AgentCredentialStore._setTestKeychainServiceOverride(nil)
        }
        let placeholder = try #require(AgentSecretStore.saveSecret("super-secret-password", label: "Shell Password"))

        let result = try await AgentToolRunner.run(
            name: "run_command",
            arguments: [
                "command": .string("printf '%s\\n' \(AgentToolRunner.shellQuoted(placeholder))"),
                "timeout_seconds": .number(Self.headlessCommandTimeoutSeconds),
            ],
            context: AgentToolContext(rootDirectory: nil, sandboxMode: .escalated)
        )

        #expect(result.payload.contains("[secret]"))
        #expect(!result.payload.contains("super-secret-password"))
        #expect(!result.payload.contains(placeholder))
    }

    @Test
    func secretPlaceholdersResolveOnlyForLocalExecutionBoundaries() {
        let localExecutionTools = [
            "run_command",
            "terminal_send_command",
            "lark_cli",
            "call_mcp_tool",
            "chrome_type",
        ]
        for toolName in localExecutionTools {
            #expect(AgentToolRunner.resolvesSecretsForTool(toolName))
        }

        let delegatedAIExecutors = [
            "claude_code",
            "codex_cli",
            "cursor_agent",
            "cline_cli",
        ]
        for toolName in delegatedAIExecutors {
            #expect(!AgentToolRunner.resolvesSecretsForTool(toolName))
        }
    }

    @Test
    func backgroundRunCommandStoresOnlyRedactedSecretCommand() async throws {
        _ = AgentCredentialStore._setTestKeychainServiceOverride("agent-secret-bg-\(UUID().uuidString)")
        defer {
            AgentCredentialStore._wipeTestKeychain()
            AgentCredentialStore._setTestKeychainServiceOverride(nil)
        }
        let placeholder = try #require(AgentSecretStore.saveSecret("background-secret", label: "Background Password"))
        let registry = AgentJobRegistry()
        let runtimeID = UUID()

        let result = try await AgentToolRunner.run(
            name: "run_command",
            arguments: [
                "command": .string("printf '%s\\n' \(AgentToolRunner.shellQuoted(placeholder))"),
                "run_in_background": .bool(true),
                "timeout_seconds": .number(3),
            ],
            context: AgentToolContext(
                rootDirectory: nil,
                runtimeID: runtimeID,
                jobRegistry: registry,
                sandboxMode: .escalated
            )
        )

        #expect(result.payload.contains("[secret]"))
        #expect(!result.payload.contains("background-secret"))
        let job = try #require(registry.jobs(forRuntime: runtimeID).first)
        #expect(job.command.contains("[secret]"))
        #expect(!job.command.contains("background-secret"))
        #expect(!job.command.contains(placeholder))
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
        #expect(AgentToolError.commandTimeout.errorDescription?.hasPrefix("Command timed out") == true)
        // The timeout message now carries recovery guidance for the model —
        // it must keep steering toward run_in_background / timeout_seconds
        // instead of a verbatim retry.
        #expect(AgentToolError.commandTimeout.errorDescription?.contains("run_in_background") == true)
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
    func sandboxPolicyAutoApprovesShellWrappedEchoSentinel() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-workspace")
        let decision = AgentSandboxPolicy.commandDecision(
            command: #"/bin/sh -lc "echo DOCKER_DONE""#,
            rootDirectory: root
        )
        #expect(decision.mode == .readOnly)
        #expect(decision.requiresUserApproval == false)
        #expect(decision.requiresTypedConfirmation == false)

        let hiddenPathRead = AgentSandboxPolicy.commandDecision(
            command: #"bash -lc "cat /etc/passwd""#,
            rootDirectory: root
        )
        #expect(hiddenPathRead.requiresUserApproval == true)
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
    func sandboxPolicyClassifiesSSHRemoteReadOnlyPayloads() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-workspace")

        let remoteCatDecision = AgentSandboxPolicy.commandDecision(
            command: "ssh deploy@example.com cat /var/log/nginx/access.log",
            rootDirectory: root
        )
        #expect(remoteCatDecision.mode == .readOnly)
        #expect(remoteCatDecision.requiresUserApproval == false)

        let remotePingDecision = AgentSandboxPolicy.commandDecision(
            command: #"ssh -p 2222 deploy@example.com "ping -c 1 8.8.8.8""#,
            rootDirectory: root
        )
        #expect(remotePingDecision.mode == .readOnly)
        #expect(remotePingDecision.requiresUserApproval == false)

        let remoteSecretDecision = AgentSandboxPolicy.commandDecision(
            command: #"ssh deploy@example.com "cat ~/.ssh/id_rsa""#,
            rootDirectory: root
        )
        #expect(remoteSecretDecision.mode == .escalated)
        #expect(remoteSecretDecision.requiresTypedConfirmation == true)

        let remoteDeleteDecision = AgentSandboxPolicy.commandDecision(
            command: #"ssh deploy@example.com "rm -rf /tmp/build""#,
            rootDirectory: root
        )
        #expect(remoteDeleteDecision.mode == .escalated)
        #expect(remoteDeleteDecision.requiresTypedConfirmation == true)

        let interactiveDecision = AgentSandboxPolicy.commandDecision(
            command: "ssh deploy@example.com",
            rootDirectory: root
        )
        #expect(interactiveDecision.mode == .escalated)
        #expect(interactiveDecision.requiresUserApproval == true)
        #expect(interactiveDecision.requiresTypedConfirmation == false)
    }

    @Test
    func commandAuthorizationDerivesSSHRemotePayloadSignature() {
        let signature = AgentCommandAuthorization.signature(
            for: #"ssh -p 2222 deploy@example.com "git status --short""#
        )
        #expect(signature == "ssh git status")

        let prefixRule = AgentCommandAuthorization.prefixRule(
            for: #"ssh deploy@example.com "git status --short""#
        )
        #expect(prefixRule == ["ssh", "git", "status"])

        let interactiveSignature = AgentCommandAuthorization.signature(
            for: "ssh deploy@example.com"
        )
        #expect(interactiveSignature == nil)
    }

    @Test
    func externalAgentCLIsRunAfterApprovalWithTheirNativeHomeAndSandbox() {
        for toolName in ["claude_code", "codex_cli", "cursor_agent", "cline_cli"] {
            let decision = AgentSandboxPolicy.decision(
                toolName: toolName,
                arguments: [:],
                rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-workspace")
            )
            #expect(decision.mode == .escalated, "\(toolName) must keep the native CLI auth/config home")
            #expect(decision.requiresUserApproval == true)
            #expect(decision.requiresTypedConfirmation == false)
        }
    }

    @Test
    func agentTerminalToolsKeepSnapshotReadOnlyAndWritesApproved() {
        let snapshot = AgentToolRegistry.descriptor(for: "terminal_snapshot")
        let sendCommand = AgentToolRegistry.descriptor(for: "terminal_send_command")
        let sendControl = AgentToolRegistry.descriptor(for: "terminal_send_control")
        let listShortcuts = AgentToolRegistry.descriptor(for: "terminal_list_shortcuts")
        let createShortcut = AgentToolRegistry.descriptor(for: "terminal_create_shortcut")
        let editShortcut = AgentToolRegistry.descriptor(for: "terminal_edit_shortcut")
        let listTabs = AgentToolRegistry.descriptor(for: "terminal_list_tabs")
        let selectTab = AgentToolRegistry.descriptor(for: "terminal_select_tab")

        #expect(snapshot?.risk == .read)
        #expect(sendCommand?.risk == .write)
        #expect(sendControl?.risk == .write)
        #expect(listShortcuts?.risk == .read)
        #expect(createShortcut?.risk == .write)
        #expect(editShortcut?.risk == .write)
        #expect(listTabs?.risk == .read)
        #expect(selectTab?.risk == .read)
        #expect(selectTab?.parameters.contains(where: { $0.name == "terminal_tab_id" && $0.required }) == true)
        #expect(sendCommand?.description.contains("OMIT terminal_tab_id") == true)
        #expect(sendCommand?.description.contains("stale UUID") == true)
        #expect(snapshot?.description.contains("ACTIVE Agent Terminal side-panel tab") == true)
        #expect(sendCommand?.description.contains("never send a local-intended command into an SSH tab") == true)
        #expect(sendCommand?.parameters.contains(where: { $0.name == "zmodem_upload_paths" && $0.type == .stringArray }) == true)
        #expect(sendCommand?.parameters.contains(where: { $0.name == "zmodem_download_directory" && $0.type == .string }) == true)

        let commandDecision = AgentSandboxPolicy.decision(
            toolName: "terminal_send_command",
            arguments: ["command": .string("systemctl status nginx --no-pager")],
            rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-workspace")
        )
        #expect(commandDecision.mode == .workspaceWrite)
        #expect(commandDecision.requiresUserApproval == true)
        #expect(commandDecision.requiresTypedConfirmation == false)

        let snapshotDecision = AgentSandboxPolicy.decision(
            toolName: "terminal_snapshot",
            arguments: [:],
            rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-workspace")
        )
        #expect(snapshotDecision.mode == .readOnly)
        #expect(snapshotDecision.requiresUserApproval == false)

        let editDecision = AgentSandboxPolicy.decision(
            toolName: "terminal_edit_shortcut",
            arguments: [:],
            rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-workspace")
        )
        #expect(editDecision.mode == .workspaceWrite)
        #expect(editDecision.requiresUserApproval == true)
        #expect(editDecision.requiresTypedConfirmation == false)

        let createDecision = AgentSandboxPolicy.decision(
            toolName: "terminal_create_shortcut",
            arguments: [:],
            rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-workspace")
        )
        #expect(createDecision.mode == .workspaceWrite)
        #expect(createDecision.requiresUserApproval == true)
        #expect(createDecision.requiresTypedConfirmation == false)
    }

    @Test
    func agentTerminalToolsHaveAlwaysAllowSignatures() {
        let commandSignature = AgentToolAuthorization.signature(
            toolName: "terminal_send_command",
            arguments: ["command": .string("systemctl status nginx --no-pager")]
        )
        #expect(commandSignature == "terminal_command:systemctl status nginx --no-pager")

        let zmodemSignature = AgentToolAuthorization.signature(
            toolName: "terminal_send_command",
            arguments: [
                "command": .string("rz"),
                "zmodem_upload_paths": .array([.string("build/app.tar.gz")]),
            ]
        )
        #expect(zmodemSignature == "terminal_command:rz|zmodem_upload:build/app.tar.gz")

        let controlSignature = AgentToolAuthorization.signature(
            toolName: "terminal_send_control",
            arguments: ["control": .string("ctrl_c")]
        )
        #expect(controlSignature == "terminal_control:ctrl_c")

        let enterSignature = AgentToolAuthorization.signature(
            toolName: "terminal_send_control",
            arguments: ["control": .string("enter")]
        )
        #expect(enterSignature == "terminal_control:enter")

        let eofSignature = AgentToolAuthorization.signature(
            toolName: "terminal_send_control",
            arguments: ["control": .string("ctrl_d")]
        )
        #expect(eofSignature == "terminal_control:ctrl_d")

        let telnetEscapeSignature = AgentToolAuthorization.signature(
            toolName: "terminal_send_control",
            arguments: ["control": .string("ctrl_right_bracket")]
        )
        #expect(telnetEscapeSignature == "terminal_control:ctrl_right_bracket")
        #expect(controlSignature != enterSignature)
    }

    @Test
    func alwaysAllowSuggestionHidesComplexOneOffCommands() {
        let reusable = AgentToolAuthorization.suggestedPersistentSignature(
            toolName: "run_command",
            arguments: ["command": .string("git push origin feature/approval-ui")]
        )
        #expect(reusable == "git push")

        let manyArguments = AgentToolAuthorization.suggestedPersistentSignature(
            toolName: "run_command",
            arguments: [
                "command": .string("go test ./... -run TestApprovalPolicy -count=1 -timeout=8m")
            ]
        )
        #expect(manyArguments == nil)

        let remoteLayer = AgentToolAuthorization.suggestedPersistentSignature(
            toolName: "run_command",
            arguments: ["command": .string("ssh deploy@example.com systemctl restart willdeep")]
        )
        #expect(remoteLayer == nil)

        let inlineScript = AgentToolAuthorization.suggestedPersistentSignature(
            toolName: "run_command",
            arguments: ["command": .string("ruby -e 'puts :one_off'")]
        )
        #expect(inlineScript == nil)

        let exactTerminalCommand = AgentToolAuthorization.suggestedPersistentSignature(
            toolName: "terminal_send_command",
            arguments: ["command": .string("systemctl status nginx --no-pager")]
        )
        #expect(exactTerminalCommand == "terminal_command:systemctl status nginx --no-pager")

        let zmodemFileSelection = AgentToolAuthorization.suggestedPersistentSignature(
            toolName: "terminal_send_command",
            arguments: [
                "command": .string("rz"),
                "zmodem_upload_paths": .array([.string("build/app.tar.gz")]),
            ]
        )
        #expect(zmodemFileSelection == nil)
    }

    @Test
    func alwaysAllowSuggestionOffersReusableShellCategories() {
        let kubernetesRollout = AgentToolAuthorization.suggestedPersistentSignature(
            toolName: "terminal_send_command",
            arguments: [
                "command": .string("kubectl -n tokenhub set image deployment/tokenhub tokenhub=harbor.example/tokenhub:1.2.3 && kubectl -n tokenhub rollout status deployment/tokenhub")
            ]
        )
        #expect(kubernetesRollout == "shell_category:kubernetes")

        let curlGet = AgentToolAuthorization.suggestedPersistentSignature(
            toolName: "run_command",
            arguments: ["command": .string("curl -L https://example.com/status")]
        )
        #expect(curlGet == "shell_category:http_get")

        let readOnlyInspection = AgentToolAuthorization.suggestedPersistentSignature(
            toolName: "terminal_send_command",
            arguments: ["command": .string("cat README.md && echo done && ps aux")]
        )
        #expect(readOnlyInspection == "shell_category:read_only_inspection")

        let curlPost = AgentToolAuthorization.suggestedPersistentSignature(
            toolName: "run_command",
            arguments: ["command": .string("curl -X POST https://example.com/deploy")]
        )
        #expect(curlPost == nil)
    }

    @Test
    func alwaysAllowMatchingAcceptsSavedShellCategoriesAndLegacyExactSignatures() {
        let kubernetesSignatures = AgentToolAuthorization.matchingSignatures(
            toolName: "terminal_send_command",
            arguments: ["command": .string("kubectl get pods -n tokenhub")]
        )
        #expect(kubernetesSignatures.contains("shell_category:kubernetes"))
        #expect(kubernetesSignatures.contains("terminal_command:kubectl get pods -n tokenhub"))

        let exactSignatures = AgentToolAuthorization.matchingSignatures(
            toolName: "terminal_send_command",
            arguments: ["command": .string("systemctl status nginx --no-pager")]
        )
        #expect(exactSignatures == ["terminal_command:systemctl status nginx --no-pager"])
    }

    @Test
    func artifactFileActionsIdentifyTextPreviewCandidatesByExtension() {
        #expect(AgentArtifactFileActions.isTextFile(URL(fileURLWithPath: "/tmp/report.md")))
        #expect(AgentArtifactFileActions.isSidePanelPreviewCandidate(URL(fileURLWithPath: "/tmp/main.swift")))
        #expect(!AgentArtifactFileActions.isTextFile(URL(fileURLWithPath: "/tmp/frame.png")))
    }

    @Test
    func existingAlwaysAllowSignatureContractRemainsStableForComplexCommands() {
        let command = "go test ./... -run TestApprovalPolicy -count=1 -timeout=8m"
        #expect(AgentToolAuthorization.signature(
            toolName: "run_command",
            arguments: ["command": .string(command)]
        ) == "go test")
        #expect(AgentToolAuthorization.suggestedPersistentSignature(
            toolName: "run_command",
            arguments: ["command": .string(command)]
        ) == nil)
    }

    @Test
    func agentTerminalOutputRedactsCommonSecretShapes() {
        let output = """
        export API_TOKEN=abcdef123456
        Authorization: Bearer sk-live-secret
        password = hunter2
        jwt=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature
        """
        let redacted = AgentTerminalRedactor.redact(output)
        #expect(!redacted.contains("abcdef123456"))
        #expect(!redacted.contains("sk-live-secret"))
        #expect(!redacted.contains("hunter2"))
        #expect(!redacted.contains("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature"))
        #expect(redacted.contains("[redacted]"))
    }

    @Test
    func agentErrorDetailsPreviewMiddleEllipsizesLongSections() {
        let longLine = "prefix-" + String(repeating: "x", count: 2_000) + "-suffix"
        let preview = AgentErrorDetailsPreview.text(longLine, totalLimit: 500, lineLimit: 180)

        #expect(preview.isTruncated)
        #expect(preview.text.count <= 500)
        #expect(preview.text.contains("prefix-"))
        #expect(preview.text.contains("-suffix"))
        #expect(preview.text.contains("省略"))
        #expect(!preview.text.contains(String(repeating: "x", count: 1_000)))
    }

    @Test
    func delegatedAgentCommandTimeoutDefaultsAvoidPrematureKills() {
        let background = AgentToolRunner.delegatedAgentForwardedCommandArguments(
            command: "codex exec task",
            sourceArguments: [:]
        )
        #expect(background["run_in_background"]?.boolValue() == true)
        #expect(background["timeout_seconds"] == nil)

        let foreground = AgentToolRunner.delegatedAgentForwardedCommandArguments(
            command: "codex exec task",
            sourceArguments: ["run_in_background": .bool(false)]
        )
        #expect(foreground["run_in_background"]?.boolValue() == false)
        #expect(foreground["timeout_seconds"]?.intValue() == Int(AgentToolRunner.delegatedAgentForegroundTimeout))

        let explicitTimeout = AgentToolRunner.delegatedAgentForwardedCommandArguments(
            command: "codex exec task",
            sourceArguments: [
                "run_in_background": .bool(true),
                "timeout_seconds": .number(42)
            ]
        )
        #expect(explicitTimeout["timeout_seconds"]?.intValue() == 42)
    }

    @Test
    func composerDelegatedAgentsUseVisibleBoundTerminal() {
        let arguments = AppState.delegatedAgentArguments(
            prompt: "delegate this task",
            executionAgent: .codexCLI
        )

        #expect(arguments["run_in_background"]?.boolValue() == false)
        #expect(arguments["use_visible_terminal"]?.boolValue() == true)
        #expect(arguments["visible_terminal_label"]?.stringValue() == "Codex")
        #expect(arguments["permission_mode"]?.stringValue() == AgentExecutionAgent.codexCLI.defaultPermissionMode)

        let cursorArguments = AppState.delegatedAgentArguments(
            prompt: "delegate this task",
            executionAgent: .cursorAgent
        )
        let clineArguments = AppState.delegatedAgentArguments(
            prompt: "delegate this task",
            executionAgent: .clineCLI
        )
        #expect(cursorArguments["visible_terminal_label"]?.stringValue() == "Cursor Agent")
        #expect(cursorArguments["permission_mode"]?.stringValue() == AgentExecutionAgent.cursorAgent.defaultPermissionMode)
        #expect(clineArguments["visible_terminal_label"]?.stringValue() == "Cline")
        #expect(clineArguments["permission_mode"]?.stringValue() == AgentExecutionAgent.clineCLI.defaultPermissionMode)
    }

    @Test
    func terminalToolsExposeExactTabTargeting() {
        for toolName in ["terminal_snapshot", "terminal_send_command", "terminal_send_control"] {
            let descriptor = AgentToolRegistry.descriptor(for: toolName)
            #expect(descriptor?.parameters.contains(where: { $0.name == "terminal_tab_id" }) == true)
            // Default routing follows the ACTIVE side-panel tab; the explicit
            // terminal_tab_id parameter stays as the one-off override.
            #expect(descriptor?.description.contains("ACTIVE") == true)
        }
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
            mode: .workspaceWriteNetwork,
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
        #expect(env["WILLDEEP_AGENT_SANDBOX"] == AgentSandboxMode.workspaceWriteNetwork.rawValue)
        #expect(env["WILLDEEP_WORKSPACE_ROOT"] == root.path)
    }

    @Test
    func sandboxLaunchSkipsSeatbeltForAlwaysSafeReadOnlyCommands() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-workspace")
        for command in [
            "pwd",
            "cat README.md",
            "diff -u a b",
            "jq . package.json",
            "git log -1 --oneline",
            "git shortlog -s HEAD",
            "git grep -n seatbelt",
            "rg AgentSandboxPolicy .",
            "unzip -l archive.zip",
            "defaults read com.apple.finder"
        ] {
            #expect(
                AgentSandboxPolicy.shouldRunWithoutSeatbelt(command: command, mode: .readOnly),
                "\(command) should skip seatbelt in readOnly"
            )
            let launch = AgentSandboxPolicy.shellLaunch(
                command: command,
                mode: .readOnly,
                rootDirectory: root
            )
            #expect(launch.executableURL.path == "/bin/sh")
            #expect(launch.arguments == ["-c", command])
        }
    }

    @Test
    func sandboxLaunchKeepsSeatbeltForWorkspaceWriteAndNetworkShapedReads() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-workspace")
        #expect(!AgentSandboxPolicy.shouldRunWithoutSeatbelt(
            command: "git status",
            mode: .workspaceWrite
        ))
        // Read-shaped curl may be alwaysSafe, but still needs the network deny.
        #expect(!AgentSandboxPolicy.shouldRunWithoutSeatbelt(
            command: "curl -fsSL https://example.com",
            mode: .readOnly
        ))

        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { return }
        let writeLaunch = AgentSandboxPolicy.shellLaunch(
            command: "git status",
            mode: .workspaceWrite,
            rootDirectory: root
        )
        #expect(writeLaunch.executableURL.path == "/usr/bin/sandbox-exec")
        #expect(writeLaunch.arguments.contains("/bin/sh"))
    }

    @Test
    func sandboxLaunchAllowsNetworkOnlyForWorkspaceNetworkMode() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = projectRoot
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("willdeep-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let launch = AgentSandboxPolicy.shellLaunch(
            command: "npm install pptxgenjs",
            mode: .workspaceWriteNetwork,
            rootDirectory: root
        )
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") {
            let profile = launch.arguments.first { $0.contains("allow network") } ?? ""
            #expect(profile.contains("(allow network*)"))
            #expect(profile.contains(root.path))
        } else {
            #expect(launch.executableURL.path == "/bin/sh")
        }
    }

    @Test
    func sandboxProfileAllowsWritingDeviceFilesInEveryMode() {
        // git 几乎所有子命令都会以写模式打开 /dev/null；(deny default) profile
        // 不放行会导致沙箱下 git 恒 EPERM。只断言纯函数生成的 profile 字符串，
        // 不端到端跑 sandbox-exec 子进程（CI 虚拟化 runner 上行为不可靠）。
        // readOnly + alwaysSafe 已跳过 seatbelt，这里只覆盖仍会套 profile 的模式。
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { return }
        for mode in [AgentSandboxMode.workspaceWrite, .workspaceWriteNetwork] {
            let launch = AgentSandboxPolicy.shellLaunch(
                command: "git status",
                mode: mode,
                rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-workspace")
            )
            let profile = launch.arguments.first { $0.contains("file-write") } ?? ""
            #expect(profile.contains("(literal \"/dev/null\")"), "mode \(mode) 应放行 /dev/null 写入")
            #expect(profile.contains("(literal \"/dev/tty\")"), "mode \(mode) 应放行 /dev/tty 写入")
        }
    }

    @Test
    func sandboxDenialHeuristicRecognizesSeatbeltSignals() {
        #expect(
            AgentSandboxPolicy.looksLikeSandboxDenial(
                exitStatus: 1,
                output: "sandbox-exec: git: Operation not permitted",
                sandboxMode: .workspaceWrite
            )
        )
        #expect(
            AgentSandboxPolicy.looksLikeSandboxDenial(
                error: AgentToolError.commandFailed(1, "sh: /dev/null: Operation not permitted"),
                sandboxMode: .readOnly
            )
        )
        #expect(
            !AgentSandboxPolicy.looksLikeSandboxDenial(
                exitStatus: 1,
                output: "sandbox-exec: git: Operation not permitted",
                sandboxMode: .escalated
            )
        )
        #expect(
            !AgentSandboxPolicy.looksLikeSandboxDenial(
                exitStatus: 1,
                output: "error: test failed\nexpected 3 got 4",
                sandboxMode: .workspaceWrite
            )
        )
        // Long logs only count "permission denied" when it sits near the end.
        let longNoise = String(repeating: "ok\n", count: 80) + "permission denied\n"
        #expect(
            AgentSandboxPolicy.looksLikeSandboxDenial(
                exitStatus: 1,
                output: longNoise,
                sandboxMode: .workspaceWrite
            )
        )
        let buriedDenial = "permission denied\n" + String(repeating: "ok\n", count: 400)
        #expect(
            !AgentSandboxPolicy.looksLikeSandboxDenial(
                exitStatus: 2,
                output: buriedDenial,
                sandboxMode: .workspaceWrite
            )
        )
    }

    @Test
    func sandboxedFailureNoteOnlyForSeatbeltedRunCommands() {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { return }
        // A command in workspaceWrite mode really ran under seatbelt → note.
        let note = AgentSandboxPolicy.sandboxedFailureNote(
            toolName: "run_command",
            command: "mkdir -p build/out",
            effectiveMode: .workspaceWrite
        )
        #expect(note?.contains("[sandbox]") == true)
        #expect(note?.contains("do NOT retry the identical command") == true)

        // alwaysSafe read-only commands skip seatbelt entirely — no note.
        #expect(AgentSandboxPolicy.sandboxedFailureNote(
            toolName: "run_command",
            command: "git status",
            effectiveMode: .readOnly
        ) == nil)
        // Escalated runs are unsandboxed — a post-escalation failure must
        // not be blamed on the sandbox.
        #expect(AgentSandboxPolicy.sandboxedFailureNote(
            toolName: "run_command",
            command: "mkdir -p build/out",
            effectiveMode: .escalated
        ) == nil)
        // Other tools never get the note (terminal commands run unsandboxed).
        #expect(AgentSandboxPolicy.sandboxedFailureNote(
            toolName: "terminal_send_command",
            command: "mkdir -p build/out",
            effectiveMode: .workspaceWrite
        ) == nil)
        #expect(AgentSandboxPolicy.sandboxedFailureNote(
            toolName: "run_command",
            command: nil,
            effectiveMode: .workspaceWrite
        ) == nil)
    }

    @Test
    func judgeVerdictCacheKeyGroupsByCommandFamily() {
        #expect(
            AgentToolAuthorization.judgeVerdictCacheKey(toolName: "run_command", command: "git commit -m 'a'")
                == AgentToolAuthorization.judgeVerdictCacheKey(toolName: "run_command", command: "git commit --amend --no-edit")
        )
        #expect(
            AgentToolAuthorization.judgeVerdictCacheKey(toolName: "run_command", command: "git commit -m 'a'")
                != AgentToolAuthorization.judgeVerdictCacheKey(toolName: "run_command", command: "git push origin main")
        )
        // Tool name is part of the key: a run_command YES must not leak to
        // the terminal tool family (they have different blast radii).
        #expect(
            AgentToolAuthorization.judgeVerdictCacheKey(toolName: "run_command", command: "git commit -m 'a'")
                != AgentToolAuthorization.judgeVerdictCacheKey(toolName: "terminal_send_command", command: "git commit -m 'a'")
        )
    }

    @Test
    func sandboxEscalationApprovalCopyUsesEscalationPrompt() {
        let descriptor = AgentApprovalNoticeCopy.descriptor(
            toolName: "run_command",
            arguments: [
                "command": .string("git add -A"),
                AgentSandboxPolicy.sandboxEscalationRequestArgumentKey: .bool(true),
                AgentSandboxPolicy.sandboxDenialDetailArgumentKey: .string("Operation not permitted"),
            ]
        )
        #expect(descriptor.title == L10n.ToolCard.sandboxEscalationTitle)
        #expect(descriptor.approveTitle == L10n.ToolCard.sandboxEscalationApprove)
        #expect(descriptor.declineTitle == L10n.ToolCard.sandboxEscalationDecline)
        #expect(descriptor.metadata.contains(L10n.ToolCard.sandboxEscalationMetadata))
        #expect(descriptor.metadata.contains("Operation not permitted"))
    }

    @Test("智能审批在沙箱拒绝后自动无沙箱重跑，其他模式不越权")
    func smartApprovalAutomaticallyRetriesSandboxDenial() {
        #expect(
            AppState.smartApprovalAutomaticallyRetriesSandboxDenial(
                approvalMode: .smart
            )
        )
        #expect(
            !AppState.smartApprovalAutomaticallyRetriesSandboxDenial(
                approvalMode: .requestEveryTime
            )
        )
        #expect(
            !AppState.smartApprovalAutomaticallyRetriesSandboxDenial(
                approvalMode: .workspaceAccess
            )
        )
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
    func stopAgentResponseDeniesAwaitingConfirm() {
        let state = AppState()
        _ = state.startNewAgentSession()
        guard let runtime = state.activeRuntime else {
            Issue.record("Expected active runtime")
            return
        }

        runtime.isResponding = true
        runtime.toolCalls = [
            AgentToolCall(
                messageID: UUID(),
                externalID: "confirm-1",
                toolName: "run_command",
                arguments: [:],
                risk: .danger,
                status: .awaitingConfirm
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
        #expect(queued.executionAgent == .willDeep)
        let delegated = AgentQueuedMessage(id: UUID(), text: "fix it", executionAgent: .claudeCode)
        #expect(delegated.executionAgent == .claudeCode)

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
        #expect(runtime.shouldConsumeQueueAfterStop == true)
    }

    @Test
    @MainActor
    func queuedMessagesCanBeReorderedInBothDirections() {
        let state = AppState()
        _ = state.startNewAgentSession()
        guard let runtime = state.activeRuntime else {
            Issue.record("Expected active runtime")
            return
        }

        let first = AgentQueuedMessage(text: "first")
        let second = AgentQueuedMessage(text: "second")
        let third = AgentQueuedMessage(text: "third")
        runtime.queuedMessages = [first, second, third]

        state.moveQueuedAgentMessage(id: first.id, to: third.id)
        #expect(runtime.queuedMessages.map(\.id) == [second.id, third.id, first.id])

        state.moveQueuedAgentMessage(id: first.id, to: second.id)
        #expect(runtime.queuedMessages.map(\.id) == [first.id, second.id, third.id])
    }

    @Test
    @MainActor
    func sendingQueuedMessageNowDeniesAwaitingConfirm() {
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
                externalID: "confirm-1",
                toolName: "run_command",
                arguments: [:],
                risk: .danger,
                status: .awaitingConfirm
            )
        ]

        state.sendQueuedAgentMessageNow(id: queued.id)

        #expect(runtime.toolCalls.first?.status == .denied)
        #expect(runtime.toolCalls.first?.errorMessage == "Sending queued message")
        #expect(runtime.queuedMessages.first?.id == queued.id)
        #expect(runtime.shouldConsumeQueueAfterStop == true)
    }

    @Test
    @MainActor
    func queuedMessageCancellationFallbackReleasesStuckTurnSlot() async {
        let state = AppState()
        _ = state.startNewAgentSession()
        guard let runtime = state.activeRuntime else {
            Issue.record("Expected active runtime")
            return
        }

        let providerID = "test-provider"
        #expect(state.acquireProviderSlotIfPossible(providerID: providerID))
        _ = state.claimProviderSlot(for: runtime, providerID: providerID)
        runtime.isResponding = true
        runtime.turnStartedAt = Date()
        runtime.shouldConsumeQueueAfterStop = true
        runtime.requestTask = Task {}

        // 显式等 fallback Task 跑完再断言;之前 3 秒盲轮询在满载全并行时
        // 等不到扫描执行,断言先于回收发生而随机失败。
        await state.scheduleQueuedMessageConsumptionAfterCancellation(
            for: runtime,
            fallbackPollAttempts: 1,
            fallbackPollIntervalNanoseconds: 0
        ).value

        #expect(runtime.isResponding == false)
        #expect(runtime.turnStartedAt == nil)
        #expect(runtime.requestTask == nil)
        #expect(runtime.currentProviderSlotClaim == nil)
        #expect(state.inFlightCountByProvider[providerID] == nil)
    }

    @Test
    @MainActor
    func sendingNewMessageWhileAwaitingUserDecisionClosesBlockingCall() {
        let state = AppState()
        _ = state.startNewAgentSession()
        guard let runtime = state.activeRuntime else {
            Issue.record("Expected active runtime")
            return
        }

        runtime.input = "skip that and continue here"
        runtime.isResponding = true
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

        state.sendAgentMessage()

        #expect(runtime.toolCalls.first?.status == .denied)
        #expect(runtime.toolCalls.first?.errorMessage == "New message sent")
        #expect(runtime.queuedMessages.first?.text == "skip that and continue here")
        #expect(runtime.shouldConsumeQueueAfterStop == true)
    }

    @Test
    @MainActor
    func sendingNewMessageDuringNonBlockingResponseOnlyQueuesIt() {
        let state = AppState()
        _ = state.startNewAgentSession()
        guard let runtime = state.activeRuntime else {
            Issue.record("Expected active runtime")
            return
        }

        runtime.input = "next normal message"
        runtime.isResponding = true
        runtime.toolCalls = [
            AgentToolCall(
                messageID: UUID(),
                externalID: "read-1",
                toolName: "git_status",
                arguments: [:],
                risk: .read,
                status: .running
            )
        ]

        state.sendAgentMessage()

        #expect(runtime.toolCalls.first?.status == .running)
        #expect(runtime.queuedMessages.first?.text == "next normal message")
        #expect(runtime.shouldConsumeQueueAfterStop == false)
    }
}

@Suite
@MainActor
struct DelegatedAgentComposerOutputTests {
    @Test
    func delegatedAgentVisibleContentUsesCommandStdout() {
        let payload = """
        exit=0
        --- stdout ---
        今天是星期五。
        --- stderr ---

        """
        let content = AppState.delegatedAgentVisibleContent(
            executionAgent: .codexCLI,
            status: .succeeded,
            result: AgentToolResult(summary: "exit 0", payload: payload),
            errorMessage: nil,
            toolPayload: payload
        )

        #expect(content == "今天是星期五。")
    }

    @Test
    func delegatedAgentVisibleContentPrefersFinalResponseBlock() {
        let payload = """
        exit=0
        --- stdout ---
        Lots of implementation logs...
        WILLDEEP_FINAL_RESPONSE_BEGIN
        已完成上下文包优化，并补充测试。
        WILLDEEP_FINAL_RESPONSE_END
        trailing diagnostics
        --- stderr ---

        """
        let content = AppState.delegatedAgentVisibleContent(
            executionAgent: .codexCLI,
            status: .succeeded,
            result: AgentToolResult(summary: "exit 0", payload: payload),
            errorMessage: nil,
            toolPayload: payload
        )

        #expect(content == "已完成上下文包优化，并补充测试。")
    }

    @Test
    func delegatedAgentVisibleContentReportsBackgroundStartWithoutParsingPromptTemplate() {
        let payload = """
        Started background job job_abc123.
        Command: codex exec WillDeep Delegated Executor Context Package v1
        WILLDEEP_FINAL_RESPONSE_BEGIN
        <concise user-facing answer, change summary, verification, and any important caveats>
        WILLDEEP_FINAL_RESPONSE_END

        The job is running.
        """
        let content = AppState.delegatedAgentVisibleContent(
            executionAgent: .codexCLI,
            status: .succeeded,
            result: AgentToolResult(summary: "▶ job_abc123 started", payload: payload),
            errorMessage: nil,
            toolPayload: payload
        )

        #expect(content == "Codex 已在后台运行（job_abc123）。完成后会自动回写结果。")
    }

    @Test
    func delegatedBackgroundJobCommandDetectionRecognizesComposerDelegationOnly() {
        let codexCommand = """
        codex exec 'WillDeep Delegated Executor Context Package v1
        You are being invoked from WillDeep Composer as the selected execution agent: Codex.'
        """
        let claudeCommand = """
        claude -p 'WillDeep Delegated Executor Context Package v1
        You are being invoked from WillDeep Composer as the selected execution agent: Claude Code.'
        """
        let cursorCommand = """
        cursor agent --print 'WillDeep Delegated Executor Context Package v1
        You are being invoked from WillDeep Composer as the selected execution agent: Cursor Agent.'
        """
        let clineCommand = """
        cline --json 'WillDeep Delegated Executor Context Package v1
        You are being invoked from WillDeep Composer as the selected execution agent: Cline.'
        """
        let ordinaryCommand = "codex exec 'selected execution agent: Codex'"

        #expect(AppState.delegatedExecutionAgent(forBackgroundJobCommand: codexCommand) == .codexCLI)
        #expect(AppState.delegatedExecutionAgent(forBackgroundJobCommand: claudeCommand) == .claudeCode)
        #expect(AppState.delegatedExecutionAgent(forBackgroundJobCommand: cursorCommand) == .cursorAgent)
        #expect(AppState.delegatedExecutionAgent(forBackgroundJobCommand: clineCommand) == .clineCLI)
        #expect(AppState.delegatedExecutionAgent(forBackgroundJobCommand: ordinaryCommand) == nil)
    }

    @Test
    func delegatedBackgroundCompletionPrefersFinalResponseBlock() {
        let job = AgentBackgroundJob(
            id: UUID(),
            shortID: "abc123",
            command: "codex exec",
            workingDirectoryPath: nil,
            runtimeID: UUID(),
            runtimeDisplayName: nil,
            remoteRuntimeID: nil,
            remotePID: nil,
            startedAt: Date(),
            pid: 123,
            status: .completed,
            exitCode: 0,
            finishedAt: Date(),
            outputByteCount: 100
        )
        let output = """
        implementation logs
        WILLDEEP_FINAL_RESPONSE_BEGIN
        后台真实结果。
        WILLDEEP_FINAL_RESPONSE_END
        trailing logs
        """

        let content = AppState.delegatedBackgroundJobCompletionContent(
            executionAgent: .codexCLI,
            job: job,
            output: output
        )

        #expect(content == "后台真实结果。")
    }

    @Test
    func delegatedAgentFinalResponseIgnoresPromptPlaceholderAndUsesLatestRealBlock() {
        let output = """
        WILLDEEP_FINAL_RESPONSE_BEGIN
        <concise user-facing answer, change summary, verification, and any important caveats>
        WILLDEEP_FINAL_RESPONSE_END
        logs...
        WILLDEEP_FINAL_RESPONSE_BEGIN
        这是实际回答。
        WILLDEEP_FINAL_RESPONSE_END
        """

        #expect(AppState.delegatedAgentFinalResponse(from: output) == "这是实际回答。")
    }

    @Test
    func delegatedConversationContextExcludesCurrentTaskAndClipsHistory() {
        let longAssistant = String(repeating: "历史实现细节", count: 120)
        let messages = [
            AgentMessage(role: .user, content: "前面说过优先保证缓存率"),
            AgentMessage(role: .assistant, content: longAssistant),
            AgentMessage(role: .user, content: "现在继续做")
        ]

        let context = AppState.delegatedConversationContextBlock(
            from: messages,
            currentUserText: "现在继续做"
        ) ?? ""

        #expect(context.contains("前面说过优先保证缓存率"))
        #expect(context.contains("[truncated]"))
        #expect(!context.contains("现在继续做"))
    }

    @Test
    func delegatedAgentVisibleContentShowsFailures() {
        let content = AppState.delegatedAgentVisibleContent(
            executionAgent: .claudeCode,
            status: .failed,
            result: nil,
            errorMessage: "CLI timed out",
            toolPayload: "Tool error: CLI timed out"
        )

        #expect(content.contains("Claude Code failed: CLI timed out"))
    }

    @Test
    func delegatedAgentFailureOutputUsesTailFallback() {
        let noisy = String(repeating: "bundled javascript noise ", count: 300)
        let payload = """
        exit=1
        --- stdout ---

        --- stderr ---
        \(noisy)
        actual useful error: authentication expired
        """
        let content = AppState.delegatedAgentVisibleContent(
            executionAgent: .claudeCode,
            status: .failed,
            result: nil,
            errorMessage: "Command exited with status 1",
            toolPayload: payload
        )

        #expect(content.contains("Earlier delegated executor output omitted"))
        #expect(content.contains("actual useful error: authentication expired"))
        #expect(content.count < 3_000)
    }

    // MARK: - Parallel read batch

    /// The concurrent-read whitelist must only ever contain read-tier
    /// tools with no approval, plan-gate, or sandbox-escalation paths.
    /// `run_command` (even when classified read-only) and `spawn_agent`
    /// must stay serial: escalation/approval suspends on the runtime's
    /// single tool-decision waiter, which concurrent calls cannot share.
    @Test
    func parallelReadBatchWhitelistOnlyContainsPureReadTools() {
        for name in AppState.parallelReadBatchToolNames {
            #expect(
                AgentToolRegistry.risk(for: name, arguments: [:]) == .read,
                "\(name) must classify as read-tier"
            )
        }
        #expect(!AppState.parallelReadBatchToolNames.contains("run_command"))
        #expect(!AppState.parallelReadBatchToolNames.contains("spawn_agent"))
        #expect(!AppState.parallelReadBatchToolNames.contains("change_workspace"))
        #expect(!AppState.parallelReadBatchToolNames.contains("rename_session"))
    }

    /// Whitelisted read tools must be safe to fan out: concurrent
    /// AgentToolRunner.run calls over the same workspace return the same
    /// independent results the serial loop produced, keyed back by index.
    @Test
    func whitelistedReadToolsRunConcurrentlyWithIndependentResults() async throws {
        let workspace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("willdeep_test_parallel_read_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        try "alpha needle one\n".write(
            to: workspace.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8
        )
        try "beta needle two\n".write(
            to: workspace.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8
        )

        let context = AgentToolContext(rootDirectory: workspace)
        let calls: [(name: String, arguments: [String: AgentJSONValue])] = [
            ("read_file", ["path": .string("one.txt")]),
            ("read_file", ["path": .string("two.txt")]),
            ("grep_files", ["pattern": .string("needle")]),
            ("list_directory", ["path": .string(".")])
        ]

        var payloads = [String?](repeating: nil, count: calls.count)
        await withTaskGroup(of: (Int, String?).self) { group in
            for (index, call) in calls.enumerated() {
                let name = call.name
                let arguments = call.arguments
                group.addTask {
                    let result = try? await AgentToolRunner.run(
                        name: name,
                        arguments: arguments,
                        context: context
                    )
                    return (index, result?.payload)
                }
            }
            for await (index, payload) in group {
                payloads[index] = payload
            }
        }

        #expect(payloads[0]?.contains("alpha needle one") == true)
        #expect(payloads[1]?.contains("beta needle two") == true)
        #expect(payloads[2]?.contains("one.txt") == true)
        #expect(payloads[2]?.contains("two.txt") == true)
        #expect(payloads[3]?.contains("one.txt") == true)
        #expect(payloads[3]?.contains("two.txt") == true)
    }
}
