//
//  AgentTerminalSnapshotScrollbackTests.swift
//  WillDeepTests
//

import Foundation
import Testing

@testable import WillDeep

/// 取屏过去只读可见窗口，滚上去的输出对 Agent 不存在——用户能滚出来看，
/// Agent 却报告「没有输出」。这些用例锁住回滚尾部确实被读到，且边界安全。
///
/// 行号一律零填充：`line-1` 是 `line-10` 的子串，不填充的话 contains 断言
/// 会假阳性通过，测了个寂寞。
@Suite("Terminal snapshot scrollback")
struct AgentTerminalSnapshotScrollbackTests {
    private func makeMirror(cols: Int = 40, rows: Int = 5) -> AgentTerminalSnapshotMirror {
        AgentTerminalSnapshotMirror(
            cols: cols,
            rows: rows,
            scrollback: 500,
            label: "test.snapshot.mirror.\(UUID().uuidString)"
        )
    }

    /// 直接在镜像队列上喂字节，复刻 LocalProcess 的投递方式。
    private func feedLines(_ mirror: AgentTerminalSnapshotMirror, prefix: String, count: Int) {
        mirror.queue.sync {
            for index in 1...count {
                let label = String(format: "%@-%03d", prefix, index)
                mirror.feedOnQueue(Array("\(label)\r\n".utf8))
            }
        }
    }

    @Test("滚出可见窗口的输出仍然能被读到")
    func scrolledOutputIsStillCaptured() {
        let mirror = makeMirror(rows: 5)
        feedLines(mirror, prefix: "line", count: 40)

        let capture = mirror.capture()

        // 最新的行在可见窗口里。
        #expect(capture.viewport.contains("line-040"))
        // 早已滚出窗口的行以前完全取不到，现在在回滚里。
        #expect(capture.scrollback.contains("line-001"))
        #expect(capture.scrollback.contains("line-020"))
        // 回滚是「窗口之上」的部分，不该重复包含最新行。
        #expect(!capture.scrollback.contains("line-040"))
    }

    @Test("输出没超过一屏时回滚为空")
    func shortOutputHasNoScrollback() {
        let mirror = makeMirror(rows: 10)
        feedLines(mirror, prefix: "only", count: 1)

        let capture = mirror.capture()

        #expect(capture.viewport.contains("only-001"))
        #expect(capture.scrollback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("回滚深度受 historyLines 限制")
    func scrollbackHonorsRequestedHistoryDepth() {
        let mirror = makeMirror(rows: 5)
        feedLines(mirror, prefix: "row", count: 60)

        let shallow = mirror.capture(historyLines: 3)
        let deep = mirror.capture(historyLines: 200)

        // 浅回看只够到窗口上方几行，够不到最早的行；深回看够得到。
        #expect(!shallow.scrollback.contains("row-001"))
        #expect(deep.scrollback.contains("row-001"))
        #expect(deep.scrollback.count > shallow.scrollback.count)
        // 两者都不该把可见窗口里的最新行算进回滚。
        #expect(!shallow.scrollback.contains("row-060"))
        #expect(!deep.scrollback.contains("row-060"))
    }

    @Test("historyLines 为 0 或负数时安全退化为无回滚")
    func nonPositiveHistoryDepthIsSafe() {
        let mirror = makeMirror(rows: 4)
        feedLines(mirror, prefix: "x", count: 30)

        #expect(mirror.capture(historyLines: 0).scrollback.isEmpty)
        #expect(mirror.capture(historyLines: -10).scrollback.isEmpty)
    }

    @Test("回滚不足请求深度时不越界")
    func shallowHistoryDoesNotUnderflow() {
        let mirror = makeMirror(rows: 5)
        feedLines(mirror, prefix: "n", count: 7)

        // 只滚出去两三行，却要求回看 200 行：必须钳到 0，不能越界。
        let capture = mirror.capture(historyLines: 200)
        #expect(capture.scrollback.contains("n-001"))
        #expect(capture.viewport.contains("n-007"))
    }

    @Test("光标行与网格信息不受回滚读取影响")
    func cursorContextSurvivesScrollbackCapture() {
        let mirror = makeMirror(cols: 40, rows: 5)
        feedLines(mirror, prefix: "c", count: 30)
        mirror.queue.sync {
            mirror.feedOnQueue(Array("prompt$ ".utf8))
        }

        let capture = mirror.capture()

        #expect(capture.rows == 5)
        #expect(capture.cols == 40)
        #expect(capture.cursorLine.contains("prompt$"))
        #expect(capture.markedViewport.contains("=>"))
    }
}
