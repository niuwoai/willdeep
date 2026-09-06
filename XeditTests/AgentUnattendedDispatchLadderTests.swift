import Foundation
import Testing
@testable import WillDeep

/// An unattended dispatch task has no operator to answer a card, so its Worker
/// tool calls resolve without one. That used to be a single line —
/// `if runtime.isUnattendedDispatchTask { return true }` — which admitted every
/// risk tier: `.danger` shell commands that seatbelt does not reach, Chrome
/// debugger control, and MCP servers the user had explicitly marked untrusted.
/// A scheduled node could do things the same user, sitting in front of the same
/// session, would have been asked to confirm.
///
/// The gate is narrow now, but nothing pinned the shape of it. These do. The
/// `XeditTests/AgentSubagentApprovalLadderTests.swift` suite that used to guard
/// the old gate was deleted with the dead function it called, and the very next
/// prerelease shipped a Worker approval regression.
@Suite
struct AgentUnattendedDispatchLadderTests {
    private func source(_ risk: AgentToolRisk) -> AgentToolApprovalSource? {
        AppState.unattendedDispatchApprovalSource(
            risk: risk,
            isUnattendedDispatchTask: true
        )
    }

    /// Ordinary workspace writes are the whole point of an unattended node:
    /// it edits files and runs builds with nobody watching.
    @Test("a write resolves as a dispatch-task grant")
    func writeIsAdmitted() {
        #expect(source(.write) == .dispatchTask)
    }

    /// The reported hole. A Worker's terminal command runs in the user's real
    /// shell, and `.danger` is the tier reserved for commands that destroy data
    /// or leave the workspace.
    @Test("danger is never granted, however unattended the task")
    func dangerIsRefused() {
        #expect(source(.danger) == nil)
    }

    /// `.userInput` exists to ask the operator something. Granting it
    /// unattended would answer on their behalf.
    @Test("a question is not something an unattended task may answer for itself")
    func userInputIsRefused() {
        #expect(source(.userInput) == nil)
    }

    /// Reads never reach this ladder — the Worker execution gate admits them
    /// earlier — so this must not hand back a grant that would put a read into
    /// the parent's approval queue and light the Dock badge.
    @Test("a read yields no grant, because it never needed one")
    func readIsNotGranted() {
        #expect(source(.read) == nil)
    }

    /// The unattended branch must not leak into ordinary sessions: with an
    /// operator present, every tier goes through the normal ladder instead.
    @Test("an attended session gets no unattended grant at any tier")
    func attendedSessionsAreUntouched() {
        for risk in [AgentToolRisk.read, .write, .danger, .userInput] {
            #expect(
                AppState.unattendedDispatchApprovalSource(
                    risk: risk,
                    isUnattendedDispatchTask: false
                ) == nil,
                "attended session leaked a grant at \(risk)"
            )
        }
    }

    /// The sandbox floor is the other half of the gate: a command the sandbox
    /// wants typed confirmation for is refused before the risk tier is even
    /// consulted. These are the shapes that floor has to keep catching.
    @Test("commands that demand typed confirmation stay outside the workspace floor")
    func typedConfirmationCommandsAreRecognised() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-unattended-ladder")
        for command in ["rm -rf /", "sudo rm -rf /Users/rocky/Sites"] {
            let decision = AgentSandboxPolicy.decision(
                toolName: "run_command",
                arguments: ["command": .string(command)],
                rootDirectory: root,
                additionalWorkspaceRoots: []
            )
            #expect(
                decision.requiresTypedConfirmation,
                "sandbox stopped demanding confirmation for \(command)"
            )
        }
    }
}
