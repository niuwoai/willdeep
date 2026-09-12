import Foundation
import Testing
@testable import WillDeepCore

/// Git Review 面板的提交按钮原本一律 `git add -A -- .`：它列的是整个工作区，
/// 提交的也是整个工作区，自洽，但用户自己手改的那一笔会被无声带进 Agent 的
/// 提交，事后在任何地方都找不到说明。
///
/// 这个 suite 守住归属的判据，尤其是「说不出口的时候就别说」那一条。
@Suite
struct AgentGitCommitAttributionTests {
    @Test("写集认领的进 attributed，其余进 unattributed")
    func splitsByWriteSet() {
        let split = AgentGitCommitAttribution.split(
            changePaths: ["Xedit/A.swift", "deploy/k8s/03-tokenhub.yaml", "Xedit/B.swift"],
            editedPaths: ["Xedit/A.swift", "Xedit/B.swift"]
        )
        #expect(split?.attributed == ["Xedit/A.swift", "Xedit/B.swift"])
        #expect(split?.unattributed == ["deploy/k8s/03-tokenhub.yaml"])
        #expect(split?.hasUnattributed == true)
    }

    /// 写集为空时不能宣称「这些都不是我改的」。刚开的会话、或恢复时丢了写集
    /// 的会话，对这些文件一无所知；把它读成「全部非本会话」会让提交按钮把
    /// 用户真正想提交的东西全部留在工作区。
    @Test("写集为空或缺失时不给出任何归属")
    func refusesToClaimWithoutAWriteSet() {
        #expect(AgentGitCommitAttribution.split(changePaths: ["a.swift"], editedPaths: []) == nil)
        #expect(AgentGitCommitAttribution.split(changePaths: ["a.swift"], editedPaths: nil) == nil)
    }

    /// 写集是补丁落盘时填的，历史上带过 `./` 前缀；git 报的是相对仓库根的
    /// 裸路径。两边不归一，同一个文件会被读成两个，于是悄悄掉出提交。
    @Test("比较前把 ./ 与前导 / 归一，同一文件不会被读成两个")
    func normalizesPathShapes() {
        let split = AgentGitCommitAttribution.split(
            changePaths: ["Xedit/A.swift", "Xedit/C.swift"],
            editedPaths: ["./Xedit/A.swift", "/Xedit/C.swift"]
        )
        #expect(split?.attributed == ["Xedit/A.swift", "Xedit/C.swift"])
        #expect(split?.unattributed.isEmpty == true)
    }

    @Test("工作区全是本会话改的时候没有需要提示的东西")
    func nothingToWarnAboutWhenAllMine() {
        let split = AgentGitCommitAttribution.split(
            changePaths: ["a.swift"],
            editedPaths: ["a.swift"]
        )
        #expect(split?.hasUnattributed == false)
        #expect(split?.unattributed.isEmpty == true)
    }

    /// 一个文件双方都改过时读作 attributed。路径级归属撑不起行级证据，所以
    /// 收窄的是提交范围，不是对作者身份的断言——UI 文案也据此说「不是本会话
    /// 的改动」，不说「Agent 没碰过」。
    @Test("双方都改过的文件算本会话的，归属只到路径级")
    func sharedFileCountsAsAttributed() {
        let split = AgentGitCommitAttribution.split(
            changePaths: ["shared.swift"],
            editedPaths: ["shared.swift"]
        )
        #expect(split?.attributed == ["shared.swift"])
    }
}
