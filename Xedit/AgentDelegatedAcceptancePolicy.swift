//
//  AgentDelegatedAcceptancePolicy.swift
//  WillDeep
//
//  这条消息值不值得一份验收合同。
//
//  委派执行器打开时，此前**每一条**用户消息都会被套上一份四条款的验收
//  合同，不做任何判断。于是一句「hello」也会带着「列出改动文件、说明已做
//  验证、报告遗留风险」的要求交给 Claude Code，它老实去翻工作区，翻完发现
//  无可奉告，回了句问候就结束；验收层拿不到证据块，把四条全判成
//  inconclusive，凑出六条问题。用户看到的是：一句问候跑了五分半，然后报错。
//
//  所以这里加一道闸。判据刻意做窄：
//
//   · **只认明确的寒暄**——问候、道谢、道别、夸奖。命中白名单才算不是任务。
//   · **审批词一律算任务**。「好的」「收到」「可以」「嗯」在这个产品里
//     十有八九是「照你说的做」，把它们当闲聊放过去，等于把一次真正的
//     交付漏掉验收。同理「测试」「试试」也不算——它可能是让你跑测试。
//   · **带附件、多行、超长、含路径或代码围栏的，一律算任务。**
//
//  方向性错误的代价是不对称的：漏判只是多套一次合同（慢一点，结果照旧
//  正确），误判是把一次真改动放过了验收。所以拿不准就当任务。
//

import Foundation

nonisolated enum AgentDelegatedAcceptancePolicy {
    /// 超过这个字符数一律按任务处理。真正的寒暄没有长的，而这个上限也让
    /// 白名单不必去穷举各种加长写法。
    static let conversationalCharacterLimit = 16

    /// 明确不是任务的话头。只放进那些无论如何都不可能是「请你做一件事」
    /// 的说法。
    private static let conversationalStems: Set<String> = [
        // 问候
        "hi", "hello", "hey", "yo", "hiya", "howdy", "morning",
        "你好", "您好", "哈喽", "哈啰", "嗨", "在吗", "在么", "在不在",
        "早", "早上好", "中午好", "下午好", "晚上好",
        // 道谢
        "thanks", "thank", "thankyou", "thank you", "thx", "ty",
        "谢谢", "多谢", "感谢", "辛苦", "辛苦了",
        // 道别
        "bye", "goodbye", "seeyou", "see you", "goodnight",
        "再见", "拜拜", "晚安",
        // 夸奖
        "nice", "cool", "great", "awesome", "wow", "perfect",
        "厉害", "牛", "赞", "干得好", "漂亮",
    ]

    /// 出现任何一个就当任务，哪怕整句很短。这些是「这条消息指向工作区」
    /// 的硬信号。
    private static let taskMarkers = [
        "```", "/", "\\", "@", "#", "$", "http://", "https://",
    ]

    /// 只从**结尾**剥掉的语气词和称呼。「谢谢你」剥成「谢谢」，
    /// 「你好啊」剥成「你好」。不剥「吗」——「在吗」本身就在白名单里，
    /// 剥掉会把它变成「在」。
    private static let trailingParticles: Set<Character> = [
        "啊", "呀", "呢", "吧", "了", "哦", "喔", "噢", "的", "你", "您",
        "~", "～", "!", "！", "?", "？", "。", ".", ",", "，", " ",
    ]

    /// 这条消息是否需要验收合同。
    ///
    /// - Parameters:
    ///   - userText: 用户原文。
    ///   - hasAttachments: 带了图片、文本附件或技能。带附件说明有活要干。
    static func requiresAcceptance(userText: String, hasAttachments: Bool) -> Bool {
        guard !hasAttachments else { return true }

        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        // 多行几乎总是贴了日志、代码或一串要求。
        guard !trimmed.contains(where: \.isNewline) else { return true }
        guard trimmed.count <= conversationalCharacterLimit else { return true }
        guard !taskMarkers.contains(where: trimmed.contains) else { return true }

        var normalized = Substring(trimmed.lowercased())
        while let last = normalized.last, trailingParticles.contains(last) {
            normalized = normalized.dropLast()
        }
        guard !normalized.isEmpty else { return true }
        return !conversationalStems.contains(String(normalized))
    }
}
