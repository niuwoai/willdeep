//
//  SlashCommandInline.swift
//  WillDeep
//
//  写在正文中间 / 句尾的斜杠命令：`帮我升级 tokenhub /no-subagent`。
//
//  此前在句中选中命令会立刻执行，而「执行」对 `/no-subagent` 来说就是把
//  输入框里的内容当正文发出去——用户还在打字，半截话连同 `/no` 一起发了。
//  现在的约定：
//    - 句中选命令只补全这个词，不执行；回车时才连同正文一起处理。
//    - 句中只认「修饰这一轮怎么发」的命令（沙箱、委派开关）。`/clear`、
//      `/handoff` 这类会动数据或往外推东西的命令，只在消息开头才算命令，
//      否则正文里提一句「/clear 是干嘛的」就会被执行。
//    - 认出的命令词在输入框里高亮，回删时整个词一起删。
//

import Foundation

struct SlashCommandTokenMatch: Equatable {
    /// UTF-16 范围，直接给 NSTextView 用。
    let range: NSRange
    let commandID: String
}

extension SlashCommand {
    /// 可以写在正文任意位置的命令：只改变这一轮消息怎么发，正文照常发送。
    static let inlineModifierIDs: Set<String> = ["no-sandbox", "sandbox", "subagent", "no-subagent"]

    var isInlineModifier: Bool {
        Self.inlineModifierIDs.contains(id)
    }

    /// 光标所在的斜杠词不是整条消息的第一个词（句中、句尾，或开头命令串里的
    /// 后一个）。这时选中命令只补全这个词。
    static func isCompletingNonLeadingToken(input: String, currentToken: String) -> Bool {
        guard currentToken.hasPrefix("/") else { return false }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstToken = trimmed.prefix { !$0.isWhitespace }
        return firstToken != Substring(currentToken)
    }

    /// 输入框里被认成命令的词：开头连续的命令词（任何命令），以及其后任意
    /// 位置上的修饰类命令词。按出现顺序返回。
    static func recognizedTokens(in text: String, commands: [SlashCommand]) -> [SlashCommandTokenMatch] {
        var matches: [SlashCommandTokenMatch] = []
        var stillLeading = true
        for (range, word) in words(in: text) {
            let command = word.hasPrefix("/")
                ? commands.first { $0.answersTo(exactName: String(word.dropFirst())) }
                : nil
            if stillLeading, let command {
                matches.append(.init(range: range, commandID: command.id))
                continue
            }
            stillLeading = false
            if let command, command.isInlineModifier {
                matches.append(.init(range: range, commandID: command.id))
            }
        }
        return matches
    }

    /// 回车时要按命令处理的消息：开头串写多个命令、或正文里带修饰命令。
    /// 只有「开头恰好一个命令」时返回 nil，交给原有 `invocation` 路径（它还
    /// 负责缺参数时把命令留在输入框里）。
    static func composerChain(in text: String, commands: [SlashCommand]) -> SlashCommandChain? {
        let tokens = recognizedTokens(in: text, commands: commands)
        guard let first = tokens.first else { return nil }
        let startsWithCommand = words(in: text).first?.0 == first.range
        guard tokens.count >= 2 || !startsWithCommand else { return nil }
        let matched = tokens.compactMap { token in commands.first { $0.id == token.commandID } }
        return chain(matched: matched, text: removing(tokens.map(\.range), from: text))
    }

    /// 摘掉命令词，连带它前面的一个空白，避免正文里留下双空格。
    static func removing(_ ranges: [NSRange], from text: String) -> String {
        let mutable = NSMutableString(string: text)
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            var removal = range
            if removal.location > 0,
               let scalar = UnicodeScalar(mutable.character(at: removal.location - 1)),
               CharacterSet.whitespaces.contains(scalar) {
                removal = NSRange(location: removal.location - 1, length: removal.length + 1)
            }
            mutable.replaceCharacters(in: removal, with: "")
        }
        return (mutable as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 按空白切词，带 UTF-16 范围。
    private static func words(in text: String) -> [(NSRange, String)] {
        let ns = text as NSString
        var result: [(NSRange, String)] = []
        var start: Int?
        for index in 0...ns.length {
            let isSpace: Bool
            if index == ns.length {
                isSpace = true
            } else if let scalar = UnicodeScalar(ns.character(at: index)) {
                isSpace = CharacterSet.whitespacesAndNewlines.contains(scalar)
            } else {
                isSpace = false
            }
            if isSpace {
                if let begin = start {
                    let range = NSRange(location: begin, length: index - begin)
                    result.append((range, ns.substring(with: range)))
                    start = nil
                }
            } else if start == nil {
                start = index
            }
        }
        return result
    }
}
