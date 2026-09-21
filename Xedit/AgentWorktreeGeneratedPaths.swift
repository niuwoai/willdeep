//
//  AgentWorktreeGeneratedPaths.swift
//  WillDeep
//
//  Recognizes untracked build-cache files so worktree attribution does not
//  record them as the Agent's edits.
//

import Foundation

/// 写集归因的构建缓存识别。
///
/// 写集来自 `git status -uall` 的快照比对，没被 gitignore 的构建缓存会一个
/// 文件记一条：本机一个会话攒到 9966 条，其中 9500 多条是 `.tmp/gocache`、
/// `.buildtmp/cache`、`.tmp/go-cache-vet` 下的 Go 缓存。它们撑爆压缩检查点
/// （1.393.0-rc2 在检查点那头截了），也让 worktree 卡片把缓存算成 Agent 的改动。
///
/// 这些目录名是各项目自己起的，按名字认不全，所以主要靠目录里的标记文件：
/// - Go 构建缓存根目录必有一份 `README`，开头是固定的一句话；
/// - Cargo `target`、pytest、ruff 等遵循 CACHEDIR.TAG 约定的工具会放 `CACHEDIR.TAG`。
/// 名字只认两类：`AppState.hiddenCacheDirectoryNames` 里那批公认的隐藏缓存目录
/// 与依赖目录，以及 Go 的临时工作目录 `go-build<数字>`。
///
/// 刻意不认 `build` / `dist`：它们常是用户要的产物，这里宁可漏认也不误认。
/// 只对**未跟踪**文件生效：进了版本库的文件被改，就是真改动。
nonisolated enum AgentWorktreeGeneratedPaths {
    static let goCacheReadmePrefix = "This directory holds cached build artifacts from the Go build system."
    static let cacheDirectoryTagFilename = "CACHEDIR.TAG"
    static let generatedDirectoryNames: Set<String> = AppState.hiddenCacheDirectoryNames
        .union(["node_modules", "__pycache__", "deriveddata"])

    /// `status.entries` 里落在构建缓存目录下的未跟踪路径（仓库根相对路径）。
    static func untrackedGeneratedPaths(in status: GitRepositoryStatus) -> Set<String> {
        guard let root = status.repositoryRoot else { return [] }
        var directoryVerdicts: [String: Bool] = [:]
        return Set(status.entries.compactMap { path, kind in
            guard kind == .untracked,
                  isInsideGeneratedDirectory(path, root: root, verdicts: &directoryVerdicts) else {
                return nil
            }
            return path
        })
    }

    /// 由浅到深检查每一级祖先目录，命中即停。同一批路径共享祖先，判定结果
    /// 记在 `verdicts` 里，一万个缓存文件也只落几次磁盘。
    static func isInsideGeneratedDirectory(
        _ path: String,
        root: URL,
        verdicts: inout [String: Bool]
    ) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return false }
        var directory = ""
        for component in components.dropLast() {
            directory = directory.isEmpty ? component : directory + "/" + component
            if let verdict = verdicts[directory] {
                if verdict { return true }
                continue
            }
            let verdict = isGeneratedDirectory(named: component, at: root.appendingPathComponent(directory))
            verdicts[directory] = verdict
            if verdict { return true }
        }
        return false
    }

    static func isGeneratedDirectory(named name: String, at url: URL) -> Bool {
        let lowercased = name.lowercased()
        if generatedDirectoryNames.contains(lowercased) || isGoBuildWorkDirectory(lowercased) {
            return true
        }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(cacheDirectoryTagFilename).path) {
            return true
        }
        return hasGoCacheReadme(in: url)
    }

    /// `go build` 的临时工作目录：`go-build` 后面跟一串数字。
    static func isGoBuildWorkDirectory(_ lowercasedName: String) -> Bool {
        let prefix = "go-build"
        guard lowercasedName.hasPrefix(prefix), lowercasedName.count > prefix.count else { return false }
        return lowercasedName.dropFirst(prefix.count).allSatisfy(\.isASCIIDigit)
    }

    static func hasGoCacheReadme(in url: URL) -> Bool {
        let readme = url.appendingPathComponent("README")
        guard let handle = try? FileHandle(forReadingFrom: readme) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: goCacheReadmePrefix.utf8.count)) ?? Data()
        return String(decoding: head, as: UTF8.self) == goCacheReadmePrefix
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
