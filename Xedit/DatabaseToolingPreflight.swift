//
//  DatabaseToolingPreflight.swift
//  WillDeep
//
//  1.81.0-rc3 BI workflow 前置检查。按 connection target 类型检查对应
//  CLI 工具是否可用：
//    - CSV / Parquet / JSON  → `duckdb`
//    - postgres://…          → `psql`
//    - mysql://… / mariadb…  → `mysql`
//    - sqlite:///…  /  .db    → `sqlite3`
//    - duckdb:///…  /  .duckdb→ `duckdb`
//  同样借鉴 [[GitHubCLIPreflight]] —— 一两秒同步跑 `<tool> --version`，
//  没装 / 版本太老直接抛带 fix hint 的 LocalizedError，省 LLM 调用。
//

import Foundation

enum DatabaseToolingPreflight {
    enum Target {
        case csvOrParquet(path: String)
        case duckdb(path: String)
        case sqlite(path: String)
        case postgres(connection: String)
        case mysql(connection: String)
    }

    enum Failure: Error, LocalizedError {
        case missingTool(name: String, install: String)
        case missingFile(path: String)
        case unparseableConnection(String)

        var errorDescription: String? {
            switch self {
            case .missingTool(let name, let install):
                return "Required CLI tool `\(name)` is not installed or not on PATH. Install it with: `\(install)`"
            case .missingFile(let path):
                return "File not found: `\(path)`. Check the path or pass an absolute one."
            case .unparseableConnection(let raw):
                return "Couldn't recognize connection target `\(raw)`. Use a file path (.csv/.parquet/.sqlite/.duckdb) or a URI (postgres://… / mysql://… / sqlite:///…)."
            }
        }
    }

    /// 从用户 args 第一个 token 推 Target。失败抛 unparseableConnection。
    static func parseTarget(_ raw: String) throws -> Target {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw Failure.unparseableConnection(raw)
        }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("postgres://") || lower.hasPrefix("postgresql://") {
            return .postgres(connection: trimmed)
        }
        if lower.hasPrefix("mysql://") || lower.hasPrefix("mariadb://") {
            return .mysql(connection: trimmed)
        }
        if lower.hasPrefix("sqlite:///") {
            let path = String(trimmed.dropFirst("sqlite:///".count))
            return .sqlite(path: "/" + path)
        }
        if lower.hasPrefix("duckdb:///") {
            let path = String(trimmed.dropFirst("duckdb:///".count))
            return .duckdb(path: "/" + path)
        }
        // Bare path —— 按扩展名识别。
        if lower.hasSuffix(".csv") || lower.hasSuffix(".tsv")
            || lower.hasSuffix(".parquet") || lower.hasSuffix(".jsonl")
            || lower.hasSuffix(".ndjson") {
            return .csvOrParquet(path: trimmed)
        }
        if lower.hasSuffix(".duckdb") || lower.hasSuffix(".ddb") {
            return .duckdb(path: trimmed)
        }
        if lower.hasSuffix(".sqlite") || lower.hasSuffix(".sqlite3")
            || lower.hasSuffix(".db") {
            return .sqlite(path: trimmed)
        }

        throw Failure.unparseableConnection(raw)
    }

    /// 对一个 Target 同步跑相应 CLI 的 `--version` 检测；对文件型 target
    /// 顺便检查文件存在。
    static func check(_ target: Target) throws {
        switch target {
        case .csvOrParquet(let path), .duckdb(let path):
            try requireFile(path)
            try requireTool(name: "duckdb",
                            install: "brew install duckdb",
                            probeArgs: ["--version"])
        case .sqlite(let path):
            try requireFile(path)
            try requireTool(name: "sqlite3",
                            install: "comes with macOS — check $PATH",
                            probeArgs: ["--version"])
        case .postgres:
            try requireTool(name: "psql",
                            install: "brew install libpq && brew link --force libpq",
                            probeArgs: ["--version"])
        case .mysql:
            try requireTool(name: "mysql",
                            install: "brew install mysql-client",
                            probeArgs: ["--version"])
        }
    }

    /// 工具是否可用（用户友好的 boolean 接口，给 UI / 文档用）。
    static func isAvailable(toolName: String) -> Bool {
        let result = run("/usr/bin/env", ["-S", toolName, "--version"])
        return result.exitCode == 0
    }

    /// Best-effort 去掉 connection string 里的密码，用 `****` 替换。
    /// 用于卡片显示和 workflow.args echo —— 不影响 workflow 内部仍用
    /// 原 string 调 CLI。识别模式：`scheme://user:password@host/…`。
    static func maskConnection(_ raw: String) -> String {
        // 截 `user:password@` 这一段。允许 `:` 出现在 password 里，所以
        // 从尾巴往前找最后一个 `@`，再从这段 prefix 里找第一个 `:`。
        guard let schemeEnd = raw.range(of: "://") else { return raw }
        let after = raw[schemeEnd.upperBound...]
        guard let atIdx = after.firstIndex(of: "@") else { return raw }
        let creds = after[..<atIdx]
        guard let colonIdx = creds.firstIndex(of: ":") else { return raw }
        let user = creds[..<colonIdx]
        let masked = raw[..<schemeEnd.upperBound] + user + ":****" + after[atIdx...]
        return String(masked)
    }

    // MARK: - Internals

    private static func requireFile(_ path: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw Failure.missingFile(path: path)
        }
    }

    private static func requireTool(name: String, install: String, probeArgs: [String]) throws {
        let result = run("/usr/bin/env", ["-S", name] + probeArgs)
        guard result.exitCode == 0 else {
            throw Failure.missingTool(name: name, install: install)
        }
    }

    private struct RunResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> RunResult {
        let process = Process()
        process.launchPath = launchPath
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return RunResult(exitCode: -1, stdout: "", stderr: "Failed to launch: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return RunResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
