//
//  AgentJobOutputLog.swift
//  WillDeep
//
//  后台 shell 作业的完整输出落盘（合同 docs/BACKGROUND_TASK_CONTRACT.md 第一节）。
//  内存里的 collector 只留尾部 64KB 给 UI 与通知；完整日志追加写到
//  `<Application Support>/WillDeep/background-jobs/<job handle>/output.log`，
//  模型要全量就拿 `output_path` 自己 `rg` / `sed -n`。
//
//  与 CLI 的差异：Mac 写盘的是 collector 已经替换过注入密钥值的字节
//  （`AgentSecretStore.redact`），不是进程原文——注入的密钥本来就不该出现在
//  任何宿主产物里。通用凭据形态的脱敏（`KEY=...`、Bearer）仍在读出时做。
//

import Foundation

/// 单个作业的追加写日志。所有写入由持有它的 collector 在自己的锁内串行调用。
nonisolated final class AgentJobOutputLogSink: @unchecked Sendable {
    /// 单个作业日志硬上限。超过后停止追加、记下省略字节数；内存尾部照常滚动。
    static let maximumBytes: UInt64 = 256 * 1024 * 1024
    static let logFileName = "output.log"
    static let tailSidecarName = "output.log.tail"
    static let droppedSidecarName = "output.log.dropped"
    private static let directoryPermissions = 0o700
    private static let filePermissions = 0o600

    /// 进程内仍在写的作业目录名。清理时一律跳过——同一进程可能有多个窗口各自
    /// 持有 registry，别的窗口里还在跑的作业不能被这个窗口的启动清理删掉。
    private static let activeLock = NSLock()
    nonisolated(unsafe) private static var activeDirectoryNames: Set<String> = []

    let directory: URL
    let logURL: URL
    private var handle: FileHandle?
    private var writtenBytes: UInt64 = 0
    private(set) var droppedBytes: UInt64 = 0
    private var didReportWriteFailure = false

    /// 创建目录与空日志文件。失败时返回 nil 并记日志：落盘是增强，不能让作业因此起不来。
    init?(rootDirectory: URL, jobHandle: String) {
        directory = rootDirectory.appendingPathComponent(jobHandle, isDirectory: true)
        logURL = directory.appendingPathComponent(Self.logFileName)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: Self.directoryPermissions]
            )
            try fileManager.setAttributes([.posixPermissions: Self.directoryPermissions], ofItemAtPath: directory.path)
            // 句柄只有 6 位十六进制，跨启动可能撞上一个早已结束的旧目录：
            // 旧日志与侧车一并作废，不能把两次作业的输出拼在一起。
            for sidecar in [Self.tailSidecarName, Self.droppedSidecarName] {
                let url = directory.appendingPathComponent(sidecar)
                if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            }
            guard fileManager.createFile(
                atPath: logURL.path,
                contents: nil,
                attributes: [.posixPermissions: Self.filePermissions]
            ) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: logURL.path])
            }
            handle = try FileHandle(forWritingTo: logURL)
        } catch {
            NSLog("Background job log unavailable for %@ at %@: %@",
                  jobHandle, directory.path, error.localizedDescription)
            return nil
        }
        Self.activeLock.lock()
        Self.activeDirectoryNames.insert(jobHandle)
        Self.activeLock.unlock()
    }

    deinit {
        try? handle?.close()
        Self.activeLock.lock()
        Self.activeDirectoryNames.remove(directory.lastPathComponent)
        Self.activeLock.unlock()
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let handle else {
            droppedBytes += UInt64(data.count)
            return
        }
        let remaining = Self.maximumBytes > writtenBytes ? Self.maximumBytes - writtenBytes : 0
        let accepted = Int(min(UInt64(data.count), remaining))
        droppedBytes += UInt64(data.count - accepted)
        guard accepted > 0 else { return }
        do {
            try handle.write(contentsOf: data.prefix(accepted))
            writtenBytes += UInt64(accepted)
        } catch {
            droppedBytes += UInt64(accepted)
            reportWriteFailure(error)
        }
    }

    /// 作业结束：写尾部与省略字节数侧车文件。文件句柄保持打开到释放，
    /// 迟到的管道残余仍能追加进日志。
    func finish(tail: Data) {
        do {
            try writeSidecar(Self.tailSidecarName, contents: tail)
            if droppedBytes > 0 {
                try writeSidecar(Self.droppedSidecarName, contents: Data("\(droppedBytes)\n".utf8))
            }
        } catch {
            reportWriteFailure(error)
        }
        Self.activeLock.lock()
        Self.activeDirectoryNames.remove(directory.lastPathComponent)
        Self.activeLock.unlock()
    }

    private func writeSidecar(_ name: String, contents: Data) throws {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: Self.filePermissions], ofItemAtPath: url.path)
    }

    private func reportWriteFailure(_ error: Error) {
        guard !didReportWriteFailure else { return }
        didReportWriteFailure = true
        NSLog("Background job log write failed at %@: %@", logURL.path, error.localizedDescription)
    }

    // MARK: - Retention

    /// 作业结束 7 天后，或同一根目录下超过 200 个作业时清理最旧的；进程内
    /// 仍在写的作业一律跳过。
    static let retentionAge: TimeInterval = 7 * 24 * 60 * 60
    static let retentionCount = 200

    static var defaultRootDirectory: URL {
        AgentSessionStore.directory
            .deletingLastPathComponent()
            .appendingPathComponent("background-jobs", isDirectory: true)
    }

    @discardableResult
    static func prune(rootDirectory: URL, now: Date = Date(), excluding alive: Set<String> = []) -> [URL] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        activeLock.lock()
        let skipped = alive.union(activeDirectoryNames)
        activeLock.unlock()
        let candidates = entries.compactMap { url -> (URL, Date)? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  !skipped.contains(url.lastPathComponent) else { return nil }
            let directoryDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let logDate = (try? url.appendingPathComponent(logFileName)
                .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (url, max(directoryDate, logDate))
        }.sorted { $0.1 > $1.1 }
        var removed: [URL] = []
        for (index, candidate) in candidates.enumerated()
        where index >= retentionCount || now.timeIntervalSince(candidate.1) > retentionAge {
            do {
                try fileManager.removeItem(at: candidate.0)
                removed.append(candidate.0)
            } catch {
                NSLog("Background job log prune failed at %@: %@", candidate.0.path, error.localizedDescription)
            }
        }
        return removed
    }
}
