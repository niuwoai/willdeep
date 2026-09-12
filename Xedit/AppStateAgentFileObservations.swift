//
//  AppStateAgentFileObservations.swift
//  WillDeep
//
//  台账的登记与查账。设计见 docs/FILE_CHANGE_PROVENANCE_DESIGN.md。
//
//  登记挂在主循环的每工具收尾处（AppStateAgentLoop 里 toolCalls 落
//  status = .succeeded 之后），因为那里 runtime 和参数都在手上，不用改
//  AgentToolContext 的结构与它所有构造点。代价是子代理自己那条工具分发
//  路径不过这里——首版不覆盖，文档里记着。
//

import WillDeepCore
import Foundation

extension AppState {
    /// 会让 Agent 看到文件内容的工具。
    ///
    /// `list_directory` / `glob` 只回名字不回内容，不算读取，登记它们只会把
    /// 台账挤满而没有任何证据价值。
    nonisolated static let fileReadingToolNames: Set<String> = [
        "read_file", "grep_files", "search_files"
    ]

    /// 会改文件的工具。写入后要把台账更新成「我写成这样」，否则下一次写入
    /// 会把自己刚写的内容当成外部漂移报出来。
    nonisolated static let fileWritingToolNames: Set<String> = [
        "edit_file", "create_file", "apply_patch", "write_file"
    ]

    /// 记一次工具调用观察到的文件。
    func recordFileObservations(
        for runtime: AgentRuntime,
        toolName: String,
        arguments: [String: AgentJSONValue],
        result: AgentToolResult
    ) {
        let isRead = Self.fileReadingToolNames.contains(toolName)
        let isWrite = Self.fileWritingToolNames.contains(toolName)
        guard isRead || isWrite else { return }
        // 远程工作区首版不登记：远程读拿不到 stat，为此多一次 SSH 往返不值。
        guard let root = rootDirectory
            ?? runtime.workspaceLocation?.localPath.map({ URL(fileURLWithPath: $0) })
            ?? runtime.workspaceRootPath.map({ URL(fileURLWithPath: $0) }) else { return }

        let paths = Self.observedPaths(toolName: toolName, arguments: arguments, result: result)
        guard !paths.isEmpty else { return }

        var ledger = runtime.fileObservations
        for path in paths.prefix(AgentFileObservationLedger.maximumEntries) {
            let absolute = path.hasPrefix("/")
                ? path
                : root.appendingPathComponent(path).standardizedFileURL.path
            guard let metadata = AppState.fileSignatureMetadata(atPath: absolute) else { continue }
            // 打开的那个 tab 一律记成 buffer。read_file 优先读它的内存内容，
            // 拿磁盘 mtime 去比那份内容必然误报；判错方向也只是少报一次漂移，
            // 不会凭空造一条。
            let isOpenTab = openedFileURL?.standardizedFileURL.path == absolute
            ledger = AgentFileObservationLedger.recording(
                ledger,
                path: AgentFileObservationLedger.normalize(
                    absolute.hasPrefix(root.path + "/")
                        ? String(absolute.dropFirst(root.path.count + 1))
                        : absolute
                ),
                observation: AgentFileObservation(
                    sizeBytes: metadata.size,
                    modifiedAt: Date(timeIntervalSince1970: metadata.modified),
                    source: isOpenTab ? .buffer : .disk,
                    kind: isWrite ? .write : .read
                )
            )
        }
        runtime.fileObservations = ledger
    }

    /// 这次调用观察到了哪些路径。
    ///
    /// 搜索类工具的路径要从结果正文里捞：ripgrep 那条路只回 `path:line: 片段`，
    /// 参数里根本没有具体文件名。
    nonisolated static func observedPaths(
        toolName: String,
        arguments: [String: AgentJSONValue],
        result: AgentToolResult
    ) -> [String] {
        if let path = arguments["path"]?.stringValue(), !path.trimmingCharacters(in: .whitespaces).isEmpty {
            return [path]
        }
        guard toolName == "grep_files" || toolName == "search_files" else { return [] }
        var seen: [String] = []
        var known = Set<String>()
        for line in result.payload.split(separator: "\n", omittingEmptySubsequences: true) {
            // `path:line: 片段`。只取第一个冒号之前的那一段，片段里的冒号不
            // 参与——按最后一个冒号切会把正文当路径。
            guard let colon = line.firstIndex(of: ":") else { continue }
            let candidate = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty, !candidate.hasPrefix("("), known.insert(candidate).inserted else { continue }
            seen.append(candidate)
            if seen.count >= 200 { break }
        }
        return seen
    }

    /// 写入这个路径之前查一次账。返回一句给模型看的话，没有漂移时返回 nil。
    ///
    /// 只告知，不阻断（不可让渡的不变量，见设计文档 §5）：台账误报时最坏是
    /// 模型多看一句话，不是用户改不了文件。
    func fileDriftNotice(for runtime: AgentRuntime, absolutePath: String) -> String? {
        guard let root = rootDirectory
            ?? runtime.workspaceRootPath.map({ URL(fileURLWithPath: $0) }) else { return nil }
        let relative = absolutePath.hasPrefix(root.path + "/")
            ? String(absolutePath.dropFirst(root.path.count + 1))
            : absolutePath
        guard let metadata = AppState.fileSignatureMetadata(atPath: absolutePath) else { return nil }
        guard let drift = AgentFileObservationLedger.drift(
            for: relative,
            in: runtime.fileObservations,
            currentSizeBytes: metadata.size,
            currentModifiedAt: Date(timeIntervalSince1970: metadata.modified)
        ) else { return nil }
        return AgentFileObservationLedger.driftNotice(drift)
    }
}
