//
//  AgentContextCompressionFolder.swift
//  WillDeep
//
//  压缩的折叠驱动器，从 `AppStateAgentContextCompression` 里抽出来。
//
//  抽出来的唯一理由是子 Agent 也需要它。此前 worker 撞窗就是整个 run 抛错
//  终止，前面几十轮的钱全白花，而错误文案只能建议用户「拆任务或换更大的
//  档」——它自己明明有一条现成的压缩管线，只是那条管线绑在 AppState 上。
//
//  折叠器对 AppState 的依赖其实只有三样：请求账本、工具执行预算、辅助请求
//  记账。三样都改成入参（后两样可空），于是同一份折叠逻辑既能被主会话用，
//  也能被没有会话行的 worker 用（WorkflowEngine 那条路径连 AppState 都没有）。
//
//  分块与折叠的语义一个字没改，包括那条最重要的不变量：压缩请求自己必须
//  分块。旧实现把整个 head 作为一个请求发出去，而那个请求的大小恰好随着
//  压缩要解决的问题一起长，于是窗口一满摘要器也溢出返回 400——唯一的逃生
//  口正好在最需要它的时刻卡死。
//

import Foundation

nonisolated enum AgentContextCompressionFolder {
    // 三个常量刻意引用主会话那一份，不另立门户：两处各存一个数，迟早
    // 漂移成「主会话折两层、worker 折三层」这种没人解释得清的差异。
    static var maximumFoldDepth: Int { AppState.maximumCompressionFoldDepth }
    static var maximumConcurrentRequests: Int { AppState.maximumConcurrentCompressionRequests }
    static var minimumChunkTokens: Int { AppState.minimumCompressionChunkTokens }

    /// 折叠一份 transcript 的分段，直到只剩一条摘要。
    ///
    /// `recordAuxiliary` 给调用方记账用。worker 传 nil：它没有会话行，主
    /// 会话那条记账路径遇到它会静默 return，传了也只是白走一趟。
    static func fold(
        segments: [String],
        configuration: AgentConfiguration,
        someIMContext: SomeIMRequestContext?,
        requestLedger: AgentModelRequestLedger?,
        executionBudget: AgentToolExecutionBudget?,
        recordAuxiliary: (@Sendable (AgentAuxiliaryModelRequestRecord) async -> Void)? = nil
    ) async throws -> String {
        let window = AppState.agentContextWindow(
            model: configuration.model,
            providerID: configuration.providerID
        )
        var budget = AppState.compressionChunkTokenBudget(contextWindow: window)
        var current = segments
        var foldDepth = 0

        while true {
            let chunks = AppState.compressionChunks(segments: current, tokenBudget: budget)
            guard !chunks.isEmpty else { return "" }
            do {
                let summaries = try await summarize(
                    chunks: chunks,
                    configuration: configuration,
                    someIMContext: someIMContext,
                    requestLedger: requestLedger,
                    executionBudget: executionBudget,
                    recordAuxiliary: recordAuxiliary
                )
                if chunks.count == 1 || summaries.count <= 1 {
                    return summaries.first ?? ""
                }
                foldDepth += 1
                guard foldDepth < maximumFoldDepth else {
                    return summaries.joined(separator: "\n\n")
                }
                current = summaries.enumerated().map { "PART \($0.offset + 1) SUMMARY:\n\($0.element)" }
            } catch let error where AppState.isContextOverflowError(error) && budget > minimumChunkTokens {
                // 估算器又低估了这家 provider 的分词。对半砍再折一次，而不是
                // 把一个用户无从下手的 400 抛出去。
                budget /= 2
                continue
            }
        }
    }

    private static func summarize(
        chunks: [String],
        configuration: AgentConfiguration,
        someIMContext: SomeIMRequestContext?,
        requestLedger: AgentModelRequestLedger?,
        executionBudget: AgentToolExecutionBudget?,
        recordAuxiliary: (@Sendable (AgentAuxiliaryModelRequestRecord) async -> Void)?
    ) async throws -> [String] {
        if chunks.count == 1 {
            let summary = try await requestSummary(
                transcript: chunks[0],
                configuration: configuration,
                someIMContext: someIMContext,
                requestLedger: requestLedger,
                executionBudget: executionBudget,
                recordAuxiliary: recordAuxiliary,
                part: 1,
                partCount: 1
            )
            return summary.isEmpty ? [] : [summary]
        }

        var ordered = [String?](repeating: nil, count: chunks.count)
        let partCount = chunks.count
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0
            func addTask(at index: Int) {
                let transcript = chunks[index]
                group.addTask {
                    let summary = try await requestSummary(
                        transcript: transcript,
                        configuration: configuration,
                        someIMContext: someIMContext,
                        requestLedger: requestLedger,
                        executionBudget: executionBudget,
                        recordAuxiliary: recordAuxiliary,
                        part: index + 1,
                        partCount: partCount
                    )
                    return (index, summary)
                }
            }
            while next < min(maximumConcurrentRequests, chunks.count) {
                addTask(at: next)
                next += 1
            }
            // 按 transcript 顺序回填：摘要拼接的顺序错了，后一次折叠读到的
            // 就是一段时间被打乱的历史。
            while let (index, summary) = try await group.next() {
                ordered[index] = summary
                if next < chunks.count {
                    addTask(at: next)
                    next += 1
                }
            }
        }
        return ordered.compactMap { $0 }.filter { !$0.isEmpty }
    }

    private static func requestSummary(
        transcript: String,
        configuration: AgentConfiguration,
        someIMContext: SomeIMRequestContext?,
        requestLedger: AgentModelRequestLedger?,
        executionBudget: AgentToolExecutionBudget?,
        recordAuxiliary: (@Sendable (AgentAuxiliaryModelRequestRecord) async -> Void)?,
        part: Int,
        partCount: Int
    ) async throws -> String {
        let context = configuration.providerID == AgentProviderPreset.someIMID
            ? someIMContext
            : nil
        let client = AgentClient(
            configuration: configuration,
            someIMContext: context,
            requestLedger: requestLedger
        )
        let collector = CompressionSummaryCollector()
        let measurement = AgentAuxiliaryRequestMeasurement()
        let messages = AppState.compressionRequestMessages(
            transcript: transcript,
            configuration: configuration,
            part: part,
            partCount: partCount
        )
        func report(succeeded: Bool) async {
            guard let recordAuxiliary else { return }
            await recordAuxiliary(
                await measurement.record(
                    purpose: .contextCompression,
                    providerID: configuration.providerID,
                    modelID: configuration.model,
                    isLocal: AgentLocalModelPrompting.isLocalProvider(configuration),
                    succeeded: succeeded
                )
            )
        }
        do {
            try await client.streamChat(messages: messages, executionBudget: executionBudget) { event in
                await measurement.consume(event)
                if case .textDelta(let delta) = event {
                    await collector.append(delta)
                }
            }
            let summary = await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
            await report(succeeded: !summary.isEmpty)
            return summary
        } catch {
            await report(succeeded: false)
            throw error
        }
    }
}

/// 子 Agent 的 transcript 压缩。
///
/// 主会话压缩是「不动本地 transcript，请求时把前缀换成摘要」；worker 的
/// transcript 就是一个本地数组，没有会话存储也没有 checkpoint 链，所以直接
/// 重写数组即可，反而简单。
///
/// 不变量：系统提示与**原始任务那条 user 消息**永不进 head。worker 撞窗的
/// 常见形态是读了十几个大文件，把任务本身压掉会让它后半程忘记要干什么——
/// 那比撞窗失败更糟，因为它会继续跑并交出一份跑偏的报告。
nonisolated enum AgentWorkerTranscriptCompression {
    /// 同一个 run 最多压几次。对应主会话的自动续跑上限：压过三次还在撞窗，
    /// 说明这个任务本身就不该由一个 worker 独自扛。
    static let maximumCompressionsPerRun = 3
    /// 保留最近几条。比主会话的 4 更紧：worker 的每条工具结果都已经按工种
    /// 上限截断过，留太多就压不出空间。
    static let keepRecent = 2
    /// 少于这个条数不压：前两条是系统提示与任务，再去掉要保留的尾巴，
    /// 剩下的 head 压出来的空间还不够一次请求的开销。
    static let minimumCompressibleCount = 6

    struct Outcome {
        var transcript: [AgentMessage]
        var summary: String
    }

    /// 切分方案。抽成纯函数是为了能被测到：保留哪两条、head 从哪开始、
    /// tail 有没有把 assistant 的 tool_calls 和它的结果切开，这三件事错一样
    /// 都会让 worker 后半程跑偏，而它们不该只能靠打一次真实网络来验证。
    struct Plan: Equatable {
        /// 系统提示与原始任务，永不进 head。
        var preservedPrefix: [AgentMessage]
        var head: [AgentMessage]
        var tail: [AgentMessage]
        var segments: [String]
    }

    static func plan(transcript: [AgentMessage], priorSummary: String?) -> Plan? {
        guard transcript.count >= minimumCompressibleCount else { return nil }
        let preservedPrefix = Array(transcript.prefix(2))
        let compressible = Array(transcript.dropFirst(2))
        let tailStart = AppState.compressionTailStart(messages: compressible, keepRecent: keepRecent)
        guard tailStart > 0 else { return nil }

        let head = Array(compressible[..<tailStart])
        let tail = Array(compressible[tailStart...])
        let segments = AppState.compressionTranscriptSegments(head: head, priorSummary: priorSummary)
        guard !segments.isEmpty else { return nil }
        return Plan(preservedPrefix: preservedPrefix, head: head, tail: tail, segments: segments)
    }

    /// 把摘要装回一份 transcript。
    ///
    /// 摘要按不可信内容标注，和主会话一致：它是模型写的文本，不是宿主指令，
    /// 不该让后续轮次把它当成新的任务要求。
    static func rebuild(plan: Plan, summary: String) -> [AgentMessage] {
        let summaryMessage = AgentMessage(
            role: .user,
            content: """
            <untrusted-conversation-summary>
            \(summary)
            </untrusted-conversation-summary>
            """
        )
        return plan.preservedPrefix + [summaryMessage] + plan.tail
    }

    /// 把中间轮折成一条摘要。返回 nil 表示没什么可压的。
    static func compress(
        transcript: [AgentMessage],
        priorSummary: String?,
        configuration: AgentConfiguration,
        someIMContext: SomeIMRequestContext?,
        requestLedger: AgentModelRequestLedger?,
        executionBudget: AgentToolExecutionBudget?
    ) async throws -> Outcome? {
        guard let plan = plan(transcript: transcript, priorSummary: priorSummary) else { return nil }
        let summary = try await AgentContextCompressionFolder.fold(
            segments: plan.segments,
            configuration: configuration,
            someIMContext: someIMContext,
            requestLedger: requestLedger,
            executionBudget: executionBudget
        )
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Outcome(transcript: rebuild(plan: plan, summary: trimmed), summary: trimmed)
    }
}
