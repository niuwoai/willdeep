import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WillDeep

/// Renders the Scheduled page with a realistic set of tasks so the redesign
/// can be checked against what it replaced rather than described.
///
/// The complaint it answers: three sections drew the same flat row shape at
/// one single font size, so a real task, a suggestion template, and a past
/// run were visually indistinguishable, and the page read as one long
/// undifferentiated list with a large empty right half.
@Suite
@MainActor
struct AgentScheduledTasksPageDesignQATests {
    private func routine(
        name: String,
        prompt: String,
        schedule: AgentRoutineSchedule,
        workspace: String?,
        isEnabled: Bool = true,
        lastRunAt: Date? = nil
    ) -> AgentRoutine {
        AgentRoutine(
            name: name,
            prompt: prompt,
            workspaceRootPath: workspace,
            schedule: schedule,
            isEnabled: isEnabled,
            lastRunAt: lastRunAt
        )
    }

    @Test("render the scheduled page for design QA")
    func rendersScheduledPageForDesignQA() throws {
        let appState = AppState()
        let now = Date(timeIntervalSince1970: 1_787_000_000)

        let logs = routine(
            name: "检查 some.im 线上日志",
            prompt: "请免密登陆 ssh root@h1.niuwoai.com 检查 niuwo, sslcat 这 2 个 systemd 服务的运行状态与最近错误日志，有异常就总结成一段结论。",
            schedule: .dailyAt(hour: 22, minute: 0),
            workspace: "/Users/rocky/Sites/muchtoken",
            lastRunAt: now.addingTimeInterval(-3_600)
        )
        let brief = routine(
            name: "每日简报",
            prompt: "请生成一份当前项目的晨间简报：检查 git 状态、最近变更、TODO 线索和今天需要关注的风险。",
            schedule: .weekdaysAt(hour: 9, minute: 0),
            workspace: "/Users/rocky/Sites/Xedit",
            lastRunAt: now.addingTimeInterval(-7_200)
        )
        let release = routine(
            name: "自动发版",
            prompt: "同时再帮我生成全新的 release app，并根据新的下载地址，更新本项目(new83d)的网页，发布上线。",
            schedule: .interval(minutes: 45),
            workspace: "/Users/rocky/Sites/new83d",
            isEnabled: false
        )
        appState.agentRoutines = [logs, brief, release]
        appState.agentRoutineRuns = [
            AgentRoutineRunRecord(
                routineID: logs.id,
                routineName: logs.name,
                sessionID: UUID(),
                startedAt: now.addingTimeInterval(-3_600),
                finishedAt: now.addingTimeInterval(-3_500),
                outcome: .failed,
                failureMessage: "模型服务返回 HTTP 404: model 'gemma4:e4b-it-qate4b' not found"
            ),
            AgentRoutineRunRecord(
                routineID: brief.id,
                routineName: brief.name,
                sessionID: UUID(),
                startedAt: now.addingTimeInterval(-90_000),
                finishedAt: now.addingTimeInterval(-89_400),
                outcome: .succeeded
            ),
            AgentRoutineRunRecord(
                routineID: logs.id,
                routineName: logs.name,
                sessionID: UUID(),
                startedAt: now.addingTimeInterval(-176_400),
                finishedAt: now.addingTimeInterval(-176_000),
                outcome: .failed,
                failureMessage: "当前似乎没有网络，检查 Wi-Fi 或网线后点「重试」"
            )
        ]

        let fixture = AgentScheduledTasksPage()
            .environmentObject(appState)
            .frame(width: 1_040, height: 900, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.light)

        let path = ProcessInfo.processInfo.environment["XEDIT_SCHEDULED_PAGE_SNAPSHOT"]
            ?? "/tmp/Xedit-scheduled-page.png"
        let hostingView = NSHostingView(rootView: fixture)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_040, height: 900)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)

        #expect(FileManager.default.fileExists(atPath: path))
    }

    /// The meta line is the redesign's load-bearing addition: schedule,
    /// workspace and *when it fires next* on one line, under the name. The
    /// page never showed the next fire time, though `nextFireDate()` had
    /// been computing it all along.
    @Test("a paused task says so instead of claiming a next run")
    func pausedTaskReportsPausedNotNextRun() {
        let paused = routine(
            name: "自动发版",
            prompt: "…",
            schedule: .interval(minutes: 45),
            workspace: "/Users/rocky/Sites/new83d",
            isEnabled: false
        )

        #expect(paused.nextFireDate() == nil)
    }
}
