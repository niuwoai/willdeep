//
//  AgentLearningSuggestionDeduplicator.swift
//  WillDeep
//
//  回合末的自学习建议要先跟本地已有的东西比一遍：已经存过的记忆、已经装好
//  的技能，不要再建议一次。
//
//  `AgentSelfLearning.dedupedNewEvents` 只做会话内去重（同一条建议在一个会话
//  里不重复弹），管不到「上周已经存过这条记忆」的情况——用户看到的仍是同一
//  句话反复来敲门。这里补的是与落盘状态的比对。
//
//  判定刻意保守：宁可漏掉一次去重（用户多看一条建议），也不要把一条真正的新
//  建议误判成重复吞掉。
//

import Foundation

nonisolated enum AgentLearningSuggestionDeduplicator {
    /// 记忆：句子长、措辞会变，阈值低一点才拦得住"同一件事换个说法"。
    static let memorySimilarityThreshold = 0.62
    /// 技能：名字和描述都短，用同样的阈值容易误伤，收严一档。
    static let skillSimilarityThreshold = 0.7
    /// 短文本的 token 太少，交集比例波动大，低于这个 token 数只认完全相同。
    private static let minimumTokensForFuzzyMatch = 3

    // MARK: - 相似度

    /// 0…1。1 表示规范化后完全相同，或短的一方被长的一方整句包含。
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = normalized(lhs)
        let right = normalized(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }

        let leftTokens = tokens(left)
        let rightTokens = tokens(right)
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return 0 }

        // 「已存的记忆更详细，新建议是它的一句摘录」也算重复。
        let shorter = left.count <= right.count ? left : right
        let longer = left.count <= right.count ? right : left
        let shorterTokens = leftTokens.count <= rightTokens.count ? leftTokens : rightTokens
        if shorterTokens.count >= minimumTokensForFuzzyMatch, longer.contains(shorter) {
            return 1
        }

        let intersection = leftTokens.intersection(rightTokens).count
        let union = leftTokens.union(rightTokens).count
        guard union > 0 else { return 0 }
        let jaccard = Double(intersection) / Double(union)

        // token 太少时 Jaccard 噪声大：两条各三个词、撞一个词就 0.2，
        // 反过来撞两个词就 0.5，不足以支撑判断。这里只信完全相同。
        if min(leftTokens.count, rightTokens.count) < minimumTokensForFuzzyMatch {
            return jaccard >= 1 ? 1 : 0
        }
        return jaccard
    }

    static func isDuplicate(
        _ candidate: String,
        among existing: [String],
        threshold: Double
    ) -> Bool {
        existing.contains { similarity(candidate, $0) >= threshold }
    }

    // MARK: - 记忆

    /// 去掉与已有记忆重复的草稿。返回空数组表示这批建议整批都是旧的，
    /// 调用方应该连事件都不要产生。
    static func newMemoryDrafts(
        _ drafts: [AgentMemoryDraft],
        existingMemoryContents: [String],
        threshold: Double = memorySimilarityThreshold
    ) -> [AgentMemoryDraft] {
        guard !drafts.isEmpty else { return [] }
        var seen = existingMemoryContents
        var fresh: [AgentMemoryDraft] = []
        for draft in drafts {
            guard !isDuplicate(draft.content, among: seen, threshold: threshold) else { continue }
            // 同一批里的重复也一起收掉。
            seen.append(draft.content)
            fresh.append(draft)
        }
        return fresh
    }

    // MARK: - 技能

    struct ExistingSkill: Equatable, Sendable {
        let name: String
        let description: String

        init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }

    /// 已经装了同一件事的技能时返回 true。先比名字（slug 相同即同一个技能），
    /// 再比「名字 + 描述」的整体相似度。
    static func isKnownSkill(
        name: String,
        description: String,
        existing: [ExistingSkill],
        threshold: Double = skillSimilarityThreshold
    ) -> Bool {
        let candidateSlug = slug(name)
        if !candidateSlug.isEmpty, existing.contains(where: { slug($0.name) == candidateSlug }) {
            return true
        }
        let candidate = "\(name) \(description)"
        return existing.contains { similarity(candidate, "\($0.name) \($0.description)") >= threshold }
    }

    // MARK: - 文本处理

    static func slug(_ text: String) -> String {
        normalized(text).replacingOccurrences(of: " ", with: "-")
    }

    /// 小写、去标点、压空白。CJK 字符之间补空格，方便后面切 bigram。
    private static func normalized(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out.append(" ")
            }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    /// 英文按词，中文按相邻两字。中文单字做 token 会让任意两句中文都高度相似。
    private static func tokens(_ normalizedText: String) -> Set<String> {
        var result: Set<String> = []
        for word in normalizedText.split(separator: " ") {
            let characters = Array(word)
            if characters.contains(where: isCJK) {
                if characters.count == 1 {
                    result.insert(String(characters[0]))
                    continue
                }
                for index in 0..<(characters.count - 1) {
                    result.insert(String(characters[index...(index + 1)]))
                }
            } else if characters.count >= 2 {
                result.insert(String(word))
            }
        }
        return result
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}
