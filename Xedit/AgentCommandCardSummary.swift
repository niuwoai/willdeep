//
//  AgentCommandCardSummary.swift
//  WillDeep
//
//  长命令的审批卡摘要。
//

import Foundation
import WillDeepCore

/// 审批卡上摆一段 20 多行的 shell，等于没摆。
///
/// 用户的原话是「那么长的，我也看不明白啊」——而卡片存在的意义，是让人在
/// 十几秒内判断要不要放行。判断依据从来不是逐字读完脚本，而是两件事：
/// **它要动几处**，以及**其中哪几处会改东西**。
///
/// 所以这里不试图“解释”命令，只做一件事：把命令链拆开数一数，给出一行
/// 可核对的结构摘要。数不清楚就返回 nil，由调用方退回原样显示——绝不编一个
/// 听起来很确定的概括出来。
nonisolated enum AgentCommandCardSummary {
    /// 短命令一眼就能看完，加摘要只是噪声。
    static let minimumCharactersForSummary = 120

    /// 或者行数够多：三行以内的命令再长也还能扫一眼。
    static let minimumLinesForSummary = 3

    /// 或者步数够多：两步的短命令一眼看得完，三步起就值得数一数。
    static let minimumStepsForSummary = 3

    static func summary(for command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let chain = AgentShellCommandParser.parse(trimmed),
              !chain.segments.isEmpty else {
            return nil
        }

        let steps = chain.segments.count
        guard steps > 1 else { return nil }

        // 门槛不能只看长度。`echo start; kubectl get pods; rm -rf /tmp/x; echo done`
        // 才 90 个字符，却有一步会删东西——这种最需要在卡上点出来。所以够长、
        // 够多行、或者步数够多，任一成立就给摘要；只有两步的短命令才省掉。
        let lineCount = trimmed.split(whereSeparator: \.isNewline).count
        let deservesSummary = trimmed.count >= minimumCharactersForSummary
            || lineCount >= minimumLinesForSummary
            || steps >= minimumStepsForSummary
        guard deservesSummary else { return nil }

        var writing = 0
        var unknown = 0
        for segment in chain.segments {
            switch SafeCommand.classify(command: segment.text) {
            case .alwaysSafe:
                continue
            case .alwaysDangerous:
                writing += 1
            case .needsJudgment:
                unknown += 1
            }
        }

        var parts = ["共 \(steps) 步"]
        if writing > 0 {
            parts.append("\(writing) 步会改动或删除")
        }
        if unknown > 0 {
            parts.append("\(unknown) 步需要核对")
        }
        if writing == 0 && unknown == 0 {
            parts.append("全部是只读检查")
        }
        return parts.joined(separator: "，")
    }

    /// 卡片正文里的命令预览：长脚本只摆前几行，剩下的折叠成一句交代。
    /// 用户要读全文时展开的是原命令，这里只负责第一眼。
    static let previewLineLimit = 6

    static func preview(for command: String) -> String {
        let lines = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
        guard lines.count > previewLineLimit else { return command }
        let head = lines.prefix(previewLineLimit).joined(separator: "\n")
        return head + "\n… 另有 \(lines.count - previewLineLimit) 行"
    }
}
