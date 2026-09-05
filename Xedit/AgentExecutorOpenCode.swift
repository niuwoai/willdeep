//
//  AgentExecutorOpenCode.swift
//  WillDeep
//
//  opencode CLI 的启动参数与事件解码。
//
//  opencode 归到结构化执行器（与 Claude Code、Codex 同级）而不是普通 shell
//  工具，是因为 `opencode run --format json` 吐的是一条定义清楚的 NDJSON
//  事件流，每条都带 sessionID，可以用 `-s` 续接。信息量足够撑起工具调用
//  卡片和 token 计数，没必要退化成「只看得到一坨文本」。
//
//  与另外两个结构化执行器的唯一差别：提示词走 argv 位置参数
//  (`opencode run <message>`)，它不读 stdin。所以 capabilities 里
//  `stdin: false`。用 Process 的 arguments 数组传递，不经过 shell，也就没有
//  引号转义的问题。
//
//  事件形状是实抓的，不是照文档猜的；样本存在
//  `XeditTests/Fixtures/opencode-stream.jsonl`，解码器用例直接读它。
//

import Foundation

extension AgentExecutorProcessFactory {
    static func openCode(
        executable: String,
        prompt: String,
        permissionMode: String,
        model: String?,
        sessionID: String? = nil,
        workspacePath: String?,
        imagePaths: [String],
        workingDirectory: URL?,
        additionalWorkspaceRoots: [URL] = [],
        environment: [String: String],
        sandboxMode: AgentSandboxMode
    ) -> AgentExecutorProcessSpecification {
        var arguments = ["run", "--format", "json"]
        if let workspacePath, !workspacePath.isEmpty {
            arguments += ["--dir", workspacePath]
        }
        // 只有明确要求放行时才给 `--auto`。opencode 对它的说明是
        // "auto-approve permissions that are not explicitly denied
        // (dangerous!)"，默认逐条询问。
        if permissionMode == "auto" {
            arguments.append("--auto")
        }
        if let sessionID, !sessionID.isEmpty {
            arguments += ["--session", sessionID]
        }
        if let model, !model.isEmpty {
            arguments += ["--model", model]
        }
        for path in imagePaths {
            arguments += ["--file", path]
        }
        // 提示词必须是最后一个位置参数，而且要在所有选项之后——否则以
        // `-` 开头的正文会被当成选项。
        arguments.append(prompt)
        return AgentExecutorProcessSpecification(
            executor: .openCode,
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            workingDirectory: workingDirectory,
            additionalWorkspaceRoots: additionalWorkspaceRoots,
            environment: environment,
            // 提示词走 argv，stdin 保持空。留着不关会让 opencode 在某些
            // 终端形态下等输入。
            standardInput: Data(),
            sandboxMode: sandboxMode,
            displayCommand: "opencode",
            decoder: OpenCodeStreamEventDecoder()
        )
    }
}

/// 把 `opencode run --format json` 的 NDJSON 翻成宿主的事件模型。
///
/// 实抓到的类型只有四种，每条的形状都是 `{type, timestamp, sessionID, part}`：
///
///  · `step_start`   —— 一个回合开始，用它认领 sessionID
///  · `tool_use`     —— `part.tool` 工具名，`part.state` 里有 status/input/output
///  · `text`         —— `part.text` 是助手正文
///  · `step_finish`  —— `part.tokens` 与 `part.cost`，`part.reason` 说明为何收尾
///
/// 认不出来的行一律走 `.raw`，原文保留。宁可在界面上多出一条原始行，也
/// 不能把它悄悄吞掉——执行器换版本加了新事件时，那条原始行是唯一的线索。
nonisolated final class OpenCodeStreamEventDecoder: AgentExecutorEventDecoding, @unchecked Sendable {
    func decode(line: String) -> [AgentExecutorEvent] {
        guard let object = AgentExecutorJSON.object(from: line),
              let type = object["type"] as? String else {
            return [AgentExecutorJSON.rawEvent(line)]
        }
        let sessionID = AgentExecutorJSON.string(object["sessionID"])
        let part = object["part"] as? [String: Any] ?? [:]

        switch type {
        case "step_start":
            return [AgentExecutorEvent(
                kind: .sessionStarted,
                sessionID: sessionID,
                itemID: AgentExecutorJSON.string(part["id"]),
                status: .running,
                rawJSON: line
            )]
        case "text":
            guard let text = AgentExecutorJSON.string(part["text"]), !text.isEmpty else {
                return [AgentExecutorJSON.rawEvent(line)]
            }
            return [AgentExecutorEvent(
                kind: .message,
                sessionID: sessionID,
                itemID: AgentExecutorJSON.string(part["id"]),
                detail: text,
                rawJSON: line
            )]
        case "tool_use":
            return [toolEvent(part: part, sessionID: sessionID, line: line)]
        case "step_finish":
            return [finishEvent(part: part, sessionID: sessionID, line: line)]
        default:
            return [AgentExecutorJSON.rawEvent(line)]
        }
    }

    private func toolEvent(
        part: [String: Any],
        sessionID: String?,
        line: String
    ) -> AgentExecutorEvent {
        let state = part["state"] as? [String: Any] ?? [:]
        let rawStatus = AgentExecutorJSON.string(state["status"])
        let status = Self.status(for: rawStatus)
        let toolName = AgentExecutorJSON.string(part["tool"])
        let input = state["input"] as? [String: Any] ?? [:]
        // 文件类工具在 input 里给的键名各不相同，挨个试；取不到就算了，
        // 文件路径只影响卡片上的一行副标题。
        let filePath = ["filePath", "path", "file"]
            .lazy
            .compactMap { AgentExecutorJSON.string(input[$0]) }
            .first
        return AgentExecutorEvent(
            // 还在跑的工具算 started，收尾了算 updated——宿主据此决定是新开
            // 一张卡片还是更新已有的那张。
            kind: status == .running ? .toolStarted : .toolUpdated,
            sessionID: sessionID,
            itemID: AgentExecutorJSON.string(part["callID"]),
            title: AgentExecutorJSON.string(state["title"]) ?? toolName,
            detail: AgentExecutorJSON.string(state["output"]),
            status: status,
            toolName: toolName,
            filePath: filePath,
            rawJSON: line
        )
    }

    private func finishEvent(
        part: [String: Any],
        sessionID: String?,
        line: String
    ) -> AgentExecutorEvent {
        let tokens = part["tokens"] as? [String: Any] ?? [:]
        let cache = tokens["cache"] as? [String: Any] ?? [:]
        let usage = AgentExecutorUsage(
            inputTokens: AgentExecutorJSON.int(tokens["input"]),
            cachedInputTokens: AgentExecutorJSON.int(cache["read"]),
            outputTokens: AgentExecutorJSON.int(tokens["output"]),
            costUSD: AgentExecutorJSON.double(part["cost"])
        )
        let reason = AgentExecutorJSON.string(part["reason"])
        // `reason == "tool-calls"` 是「这一步停下来去调工具了」，回合还没
        // 结束。把它当 finished 会让宿主提前收尾，后面的正文就没人接了。
        let isTurnEnd = reason != "tool-calls"
        return AgentExecutorEvent(
            kind: isTurnEnd ? .finished : .usage,
            sessionID: sessionID,
            itemID: AgentExecutorJSON.string(part["id"]),
            detail: reason,
            status: isTurnEnd ? .completed : .running,
            usage: usage.isEmpty ? nil : usage,
            rawJSON: line
        )
    }

    private static func status(for raw: String?) -> AgentExecutorEventStatus {
        switch raw {
        case "completed": return .completed
        case "error", "failed": return .failed
        case "pending": return .pending
        default: return .running
        }
    }
}
