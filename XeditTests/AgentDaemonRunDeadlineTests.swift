import Foundation
import Testing
@testable import WillDeep

struct AgentDaemonRunDeadlineTests {
    @Test("命令时限保留默认值、最小值、前台截断和后台六小时上限")
    func commandTimeoutLimits() {
        let cases: [(Int?, TimeInterval, Bool, Int)] = [
            (nil, 60, false, 60), (600, 5, false, 5),
            (2, 5, false, 2), (0, 5, false, 1),
            (-10, 0, false, 1), (600, 5, true, 600),
            (nil, 60, true, 60), (30_000, 30_000, false, 21_600),
            (30_000, 5, true, 21_600), (0, 5, true, 1)
        ]
        for (requested, foreground, background, expected) in cases {
            #expect(AgentDaemonRunDeadline.commandTimeout(requestedSeconds: requested,
                foregroundMaximum: foreground, background: background) == expected)
        }
    }

    @Test("实例相对时钟不依赖服务器墙上时间，按剩余预算向下取整")
    func remainingBudgetOnly() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(try AgentDaemonRunDeadline.resolve(localDeadline: now.addingTimeInterval(1.2345),
            serverElapsedMilliseconds: 50_000, timeoutSeconds: 60, now: now) == 51_234)
        #expect(try AgentDaemonRunDeadline.resolve(localDeadline: now.addingTimeInterval(120),
            serverElapsedMilliseconds: 50_000, timeoutSeconds: 7, now: now) == 57_000)
        #expect(try AgentDaemonRunDeadline.resolve(localDeadline: nil,
            serverElapsedMilliseconds: nil, timeoutSeconds: 60, now: now) == nil)
    }

    @Test("过期或亚毫秒预算不能启动", arguments: [-1.0, 0, 0.0005])
    func exhausted(remaining: Double) {
        let now = Date()
        #expect(throws: AgentToolExecutionBudgetError.exhausted) {
            try AgentDaemonRunDeadline.resolve(localDeadline: now.addingTimeInterval(remaining),
                serverElapsedMilliseconds: 1000, timeoutSeconds: 60, now: now)
        }
    }

    @Test("相加溢出被拒绝而非换成无限预算")
    func overflow() {
        let now = Date()
        #expect(throws: AgentToolError.self) {
            try AgentDaemonRunDeadline.resolve(localDeadline: now.addingTimeInterval(60),
                serverElapsedMilliseconds: AgentDaemonRunDeadline.maximumMilliseconds - 1, timeoutSeconds: 60, now: now)
        }
    }
}
