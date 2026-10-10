import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentToolApprovalNotifierTests {
    /// 测试宿主是真实的 WillDeep.app：`AgentBackgroundJobsTests` 里 `exit 7` 这类任务
    /// 结束时曾弹出真实的「后台任务失败」系统横幅。所有通知与 webhook 出口靠这个判断拦住。
    @Test("system notifications and webhooks are suppressed while unit tests run")
    func notificationsAreSuppressedUnderTests() {
        #expect(AgentToolApprovalNotifier.isSuppressedForTests)
    }

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

    @Test("job outcomes never interrupt agent recovery with a system banner", arguments: [false, true])
    func backgroundJobNotificationPolicy(isAppActive: Bool) {
        let statuses: [AgentBackgroundJob.Status] = [
            .running,
            .completed,
            .killed,
            .failed,
            .timedOut,
            .launchFailed,
        ]
        for status in statuses {
            #expect(
                !AgentToolApprovalNotifier.shouldNotifyJobFinished(
                    status: status,
                    isAppActive: isAppActive
                )
            )
        }
    }
}
