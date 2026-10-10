import Testing
@testable import WillDeep

@Suite("主 Agent 按实际工具进展续跑")
@MainActor
struct AgentMainLoopProgressTests {
    @Test("连续新结果跨越多个轮数检查点")
    func newResultsContinue() {
        let progress = AgentMainLoopProgress()
        for round in 0..<100 {
            #expect(progress.admitNextRound(completedRounds: round, segmentLength: 3,
                isGoalMode: false, hasActiveJobs: false) == .run)
            progress.observe(toolName: "read_file", argumentsJSON: "{\"start_line\":\(round)}",
                payload: "line \(round)", succeeded: true)
        }
    }

    @Test("相同成功结果和轮流重读旧结果不制造进展")
    func repeatedSuccessIsNotProgress() {
        let progress = AgentMainLoopProgress()
        for round in 0..<6 {
            #expect(progress.admitNextRound(completedRounds: round, segmentLength: 3,
                isGoalMode: false, hasActiveJobs: false) == .run)
            progress.observe(toolName: "read_file", argumentsJSON: "{\"path\":\"\(round % 2)\"}",
                payload: "unchanged", succeeded: true)
        }
        #expect(progress.admitNextRound(completedRounds: 6, segmentLength: 3,
            isGoalMode: false, hasActiveJobs: false) == .pause)
    }

    @Test("同一失败五次暂停，成功恢复后可以继续")
    func repeatedFailuresPause() {
        let progress = AgentMainLoopProgress()
        for _ in 0..<5 {
            progress.observe(toolName: "run_command", argumentsJSON: "make test", payload: "error", succeeded: false)
        }
        #expect(progress.admitNextRound(completedRounds: 5, segmentLength: 64,
            isGoalMode: false, hasActiveJobs: false) == .pause)
        progress.observe(toolName: "run_command", argumentsJSON: "make test", payload: "pass", succeeded: true)
        #expect(progress.admitNextRound(completedRounds: 6, segmentLength: 64,
            isGoalMode: false, hasActiveJobs: false) == .run)
    }

    @Test("新轮询句柄和计划声明不算进展，后台等待不算停滞")
    func pollingAndBackgroundWaiting() {
        let progress = AgentMainLoopProgress()
        for round in 0..<40 {
            #expect(progress.admitNextRound(completedRounds: round, segmentLength: 3,
                isGoalMode: false, hasActiveJobs: true) == .run)
            progress.observe(toolName: "get_job_output", argumentsJSON: "job", payload: "elapsed \(round)", succeeded: true)
            progress.observe(toolName: "update_plan", argumentsJSON: "{}", payload: "claimed \(round)", succeeded: true)
        }
        #expect(progress.stagnantRounds == 0)
        #expect(progress.admitNextRound(completedRounds: 42, segmentLength: 3,
            isGoalMode: false, hasActiveJobs: false) == .pause)
    }

    @Test("同一后台回执重复交付不重复计失败")
    func duplicateReceipts() {
        let progress = AgentMainLoopProgress()
        for _ in 0..<10 {
            progress.observe(toolName: "background_command", argumentsJSON: "test", payload: "error",
                succeeded: false, observationID: "same-job")
        }
        #expect(progress.admitNextRound(completedRounds: 1, segmentLength: 64,
            isGoalMode: false, hasActiveJobs: false) == .run)
    }

    @Test("Goal 交接检查段后旧成功结果仍不算新进展")
    func goalHandoffRetainsEvidence() {
        let progress = AgentMainLoopProgress()
        progress.observe(toolName: "read_file", argumentsJSON: "{}", payload: "old", succeeded: true)
        #expect(progress.admitNextRound(completedRounds: 3, segmentLength: 3,
            isGoalMode: true, hasActiveJobs: false) == .handoff)
        for round in 0..<3 {
            #expect(progress.admitNextRound(completedRounds: round, segmentLength: 3,
                isGoalMode: true, hasActiveJobs: false) == .run)
            progress.observe(toolName: "read_file", argumentsJSON: "{}", payload: "old", succeeded: true)
        }
        #expect(progress.admitNextRound(completedRounds: 3, segmentLength: 3,
            isGoalMode: true, hasActiveJobs: false) == .pause)
    }
}
