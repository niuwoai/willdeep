import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentToolApprovalNotifierTests {
    @Test("interactive notification titles use localized resources")
    func localizedInteractionTitles() {
        #expect(
            AgentToolApprovalNotifier.titleText(for: .pendingApproval)
                == L10n.AgentNotifications.approvalTitle
        )
        #expect(
            AgentToolApprovalNotifier.titleText(for: .awaitingConfirm)
                == L10n.AgentNotifications.confirmationTitle
        )
        #expect(
            AgentToolApprovalNotifier.titleText(for: .awaitingUserAnswer)
                == L10n.AgentNotifications.answerTitle
        )
    }

    @Test("terminal command notification does not expose its raw tool id")
    func localizedTerminalCommandBody() {
        let body = AgentToolApprovalNotifier.bodyText(
            for: "terminal_send_command",
            arguments: [:],
            status: .pendingApproval
        )

        #expect(body == L10n.AgentNotifications.toolTerminalCommand)
        #expect(body != "terminal_send_command")
    }

    @Test("file notification localizes the operation and keeps only the filename")
    func localizedFileBody() {
        let body = AgentToolApprovalNotifier.bodyText(
            for: "edit_file",
            arguments: ["path": .string("/private/workspace/README.md")],
            status: .pendingApproval
        )

        #expect(body?.contains(L10n.AgentNotifications.toolEditFile) == true)
        #expect(body?.contains("README.md") == true)
        #expect(body?.contains("/private/workspace") == false)
        #expect(body?.contains("edit_file") == false)
    }
}
