//
//  DeclarativeWorkflow.swift
//  WillDeep
//
//  1.85.0-rc5：把 UserWorkflowManifest 包成 WorkflowDefinition,
//  让它能直接挂进 WorkflowRegistry,跟内置 workflow 走同一套
//  WorkflowEngine 调度 / Card UI / Token 记账。
//
//  执行模型:
//   - 默认按 steps 顺序串行跑每一步,每步一次 `engine.agent(prompt, label:)`
//   - 连续标记 `parallel: true` 的步骤组成并行批次,实际并发受
//     manifest.max_agents 限制
//   - 渲染 prompt 时替换占位符:
//       `{{args}}` —— slash 后面用户输入的整段
//       `{{steps.<id>.output}}` —— 之前已完成 step 的输出文本
//   - 最终用同一套占位符渲染 summary 模板,返回给 engine 当 report.summary
//
//  暂时不支持的(留到后续 rc):
//   - 条件分支 / 失败重试 / 任意 DAG 依赖
//   - widget 模板渲染(workflow.yaml 同目录有 widget.html 时,直接推
//     widget 卡而不是 markdown summary)
//

import Foundation

struct DeclarativeWorkflow: WorkflowDefinition {
    let manifest: UserWorkflowManifest

    var name: String { manifest.name }
    var displayTitle: String { manifest.displayTitle }
    var slashCommand: String { manifest.slashCommand }
    var shortDescription: String { manifest.shortDescription }
    var argsPlaceholder: String { manifest.argsPlaceholder }
    var maxAgents: Int { manifest.maxAgents }
    var allowsEmptyArgs: Bool { manifest.allowsEmptyArgs }

    func run(engine: WorkflowEngine, args: String) async throws -> String {
        let trimmedArgs = args.trimmingCharacters(in: .whitespacesAndNewlines)
        var outputs: [String: String] = [:]

        var stepIndex = 0
        while stepIndex < manifest.steps.count {
            let step = manifest.steps[stepIndex]
            if step.runsInParallel {
                let batchEnd = manifest.steps[stepIndex...].firstIndex(where: { !$0.runsInParallel })
                    ?? manifest.steps.endIndex
                let batch = Array(manifest.steps[stepIndex..<batchEnd])
                let completedOutputs = outputs
                let tasks: [@Sendable () async throws -> StepOutput] = batch.map { parallelStep in
                    let prompt = render(
                        template: parallelStep.prompt,
                        args: trimmedArgs,
                        stepOutputs: completedOutputs
                    )
                    return { @Sendable in
                        let output = try await engine.agent(prompt, label: parallelStep.label)
                        return StepOutput(id: parallelStep.id, output: output)
                    }
                }
                let results = try await engine.parallel(
                    maxConcurrent: manifest.maxAgents,
                    tasks
                )
                guard results.allSatisfy({ $0 != nil }) else {
                    throw WorkflowError.allTasksFailed(
                        reason: "One or more parallel workflow steps failed."
                    )
                }
                for result in results.compactMap({ $0 }) {
                    outputs[result.id] = result.output
                }
                stepIndex = batchEnd
                continue
            }

            let prompt = render(
                template: step.prompt,
                args: trimmedArgs,
                stepOutputs: outputs
            )
            let result: String
            do {
                result = try await engine.agent(prompt, label: step.label)
            } catch {
                // 单步失败直接抛上层,engine 已经把 sub-agent 状态标 failed。
                throw error
            }
            outputs[step.id] = result
            stepIndex += 1
        }

        return render(
            template: manifest.summaryTemplate,
            args: trimmedArgs,
            stepOutputs: outputs
        )
    }

    private struct StepOutput: Sendable {
        let id: String
        let output: String
    }

    /// 占位符替换。简单字符串替换,不解析表达式;故意不支持 HTML escape /
    /// JSON encode 之类的变换 —— prompt 里就是当字符串拼。
    private func render(
        template: String,
        args: String,
        stepOutputs: [String: String]
    ) -> String {
        var result = template
        result = result.replacingOccurrences(of: "{{args}}", with: args)
        for (id, output) in stepOutputs {
            result = result.replacingOccurrences(
                of: "{{steps.\(id).output}}",
                with: output
            )
        }
        return result
    }
}

/// 在 `~/.willdeep/skills/<slug>/workflow.yaml`(以及 legacy `~/.codex/skills/`
/// 和 bundle 内 BundledSkills/)里发现的用户 workflow。
///
/// 设计:发现纯靠目录扫描,不持久化任何 cache —— 每次访问都重读,
/// 简单可靠,也方便用户改完 yaml 立即生效。规模上 skill 数量是
/// 十级别,扫描成本可忽略。
enum UserWorkflowRegistry {
    /// 最近一次 discover() 收集到的解析错误,UI 用来在用户尝试触发
    /// 不存在的 workflow 时主动提示"你那几个 yaml 还没解析过"。
    /// 单线程访问(WorkflowRegistry.all 只能 @MainActor 用,本注册表
    /// 跟着同样的隔离),不用上锁。
    nonisolated(unsafe) private(set) static var recentErrors: [String] = []

    /// 扫盘,返回所有可用的 declarative workflow。
    /// `reservedSlashCommands`:内置 workflow 的 slash 集合,用来阻止
    /// 用户用 yaml 覆盖内置命令。
    static func discover(reservedSlashCommands: Set<String>) -> [DeclarativeWorkflow] {
        var manifests: [String: DeclarativeWorkflow] = [:]  // slash -> workflow
        var loadErrors: [String] = []
        for root in skillRoots() {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                guard url.lastPathComponent == "workflow.yaml" else { continue }
                guard let data = try? Data(contentsOf: url),
                      let text = String(data: data, encoding: .utf8) else { continue }
                do {
                    let manifest = try UserWorkflowManifestParser.parse(
                        text,
                        sourceURL: url,
                        reservedSlashCommands: reservedSlashCommands
                    )
                    // 多个 root 撞到同一 slash 时,先发现的优先(扫描顺序是
                    // 主用户目录 > legacy > plugin > bundle),后来的直接忽略。
                    if manifests[manifest.slashCommand] == nil {
                        manifests[manifest.slashCommand] = DeclarativeWorkflow(manifest: manifest)
                    }
                } catch {
                    loadErrors.append("\(url.path): \(error.localizedDescription)")
                }
            }
        }
        recentErrors = loadErrors
        if !loadErrors.isEmpty {
            NSLog("[UserWorkflowRegistry] %d workflow.yaml 解析失败:\n%@",
                  loadErrors.count, loadErrors.joined(separator: "\n"))
        }
        return manifests.values.sorted { $0.name < $1.name }
    }

    /// 把最近的解析错误格式化成给用户看的提示。empty 表示没错。
    /// 注意:必须先调过 discover() —— 也就是 `WorkflowRegistry.all`
    /// 跑过一次后才有数据。slash 命令分发链路正好满足这个前置。
    static func errorBanner() -> String? {
        guard !recentErrors.isEmpty else { return nil }
        let head = "\(recentErrors.count) 个 workflow.yaml 解析失败,改完再触发会自动重读:"
        let body = recentErrors.prefix(3).joined(separator: "\n")
        let tail = recentErrors.count > 3 ? "\n…还有 \(recentErrors.count - 3) 个,见 Console.app 日志" : ""
        return head + "\n" + body + tail
    }

    /// 扫描根目录列表。复用 AgentSkillDirectory 已配置好的全套路径:
    /// 主用户(`~/.willdeep/skills/`) + legacy(`~/.codex/skills/`) +
    /// plugin cache(`~/.codex/plugins/cache/`) + bundle 内 BundledSkills/。
    private static func skillRoots() -> [URL] {
        AgentSkillDirectory.allSkillRootURLs()
    }
}
