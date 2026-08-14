//
//  AgentToolsJobs.swift
//  WillDeep
//
//  AgentToolRunner 的后台任务与队列类工具：lark_cli、list_jobs、get_job_output、
//  kill_job、list_queued_tasks，以及任务摘要格式化辅助。自 AgentTools.swift 拆出，行为不变。
//

import Foundation
import Darwin

extension AgentToolRunner {
    // MARK: list_jobs / get_job_output / kill_job

    // MARK: lark_cli

    static func larkCLI(
        arguments: [String: AgentJSONValue]
    ) async throws -> AgentToolResult {
        guard let cliArguments = arguments["arguments"]?.stringArrayValue() else {
            throw AgentToolError.missingArgument("arguments")
        }
        let normalized = AgentLarkCLI.normalizedArguments(cliArguments)
        guard !normalized.isEmpty else {
            throw AgentToolError.invalidArgument("arguments must include at least one lark-cli subcommand.")
        }
        return try await AgentLarkCLI.run(
            arguments: normalized,
            timeoutSeconds: arguments["timeout_seconds"]?.intValue()
        )
    }

    /// Snapshot of background jobs for the current runtime. Returns a
    /// stable text format (one job per line) so the model can quote
    /// handles back into `get_job_output` / `kill_job` without parsing
    /// JSON.
    static func listJobs(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        if let daemonBackend = context.daemonBackend {
            return try await daemonBackend.listJobs()
        }
        guard let registry = context.jobRegistry, let runtimeID = context.runtimeID else {
            return AgentToolResult(summary: "no jobs", payload: "Background job registry not available in this context.")
        }
        let onlyAlive = arguments["only_alive"]?.boolValue() ?? false
        let allJobs = await MainActor.run { registry.jobs(forRuntime: runtimeID) }
        let filtered = onlyAlive ? allJobs.filter { $0.isAlive } : allJobs
        guard !filtered.isEmpty else {
            return AgentToolResult(
                summary: "no jobs",
                payload: onlyAlive ? "No alive background jobs." : "No background jobs in this session."
            )
        }
        let lines = filtered.map { describe(job: $0) }
        let payload = lines.joined(separator: "\n")
        let aliveCount = filtered.filter { $0.isAlive }.count
        let summary = "\(filtered.count) job\(filtered.count == 1 ? "" : "s") (\(aliveCount) alive)"
        return AgentToolResult(summary: summary, payload: payload)
    }

    static func getJobOutput(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        if let daemonBackend = context.daemonBackend {
            return try await daemonBackend.getJobOutput(arguments: arguments)
        }
        guard let registry = context.jobRegistry, let runtimeID = context.runtimeID else {
            throw AgentToolError.invalidArgument("Background job registry not available.")
        }
        guard let handle = arguments["job_id"]?.stringValue(),
              !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.missingArgument("job_id")
        }
        let tailLines = arguments["tail_lines"]?.intValue()
        let snapshot: (
            job: AgentBackgroundJob,
            output: String,
            events: [AgentExecutorEvent]
        )? = await MainActor.run {
            guard let job = registry.job(matchingHandle: handle, runtimeID: runtimeID) else { return nil }
            return (
                job,
                registry.output(id: job.id, tailLines: tailLines),
                registry.executorEvents(id: job.id)
            )
        }
        guard let snapshot else {
            throw AgentJobError.jobNotFound(handle)
        }
        let header = describe(job: snapshot.job)
        let structuredEvents = tailLines.map {
            Array(snapshot.events.suffix(max(1, $0)))
        } ?? snapshot.events
        let structuredBody = structuredEvents.map(structuredEventDescription).joined(separator: "\n")
        let body: String
        let outputLabel: String
        if snapshot.job.executor != nil, !structuredBody.isEmpty {
            body = structuredBody
            outputLabel = "events"
        } else {
            body = snapshot.output.isEmpty ? "(no output captured yet)" : snapshot.output
            outputLabel = "output"
        }
        return AgentToolResult(
            summary: "\(snapshot.job.displayHandle): \(snapshot.job.status.rawValue)",
            payload: "\(header)\n--- \(outputLabel) ---\n\(body)"
        )
    }

    nonisolated private static func structuredEventDescription(
        _ event: AgentExecutorEvent
    ) -> String {
        var fields = ["event=\(event.kind.rawValue)"]
        if let status = event.status {
            fields.append("status=\(status.rawValue)")
        }
        if let sessionID = event.sessionID {
            fields.append("session_id=\(sessionID)")
        }
        if let toolName = event.toolName {
            fields.append("tool=\(toolName)")
        }
        if let filePath = event.filePath {
            fields.append("file=\(filePath)")
        }
        if let detail = event.detail?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !detail.isEmpty {
            fields.append("detail=\(detail.replacingOccurrences(of: "\n", with: "\\n"))")
        }
        if let usage = event.usage {
            if let input = usage.inputTokens {
                fields.append("input_tokens=\(input)")
            }
            if let output = usage.outputTokens {
                fields.append("output_tokens=\(output)")
            }
        }
        return fields.joined(separator: " ")
    }

    static func killJob(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        if let daemonBackend = context.daemonBackend {
            return try await daemonBackend.killJob(arguments: arguments)
        }
        guard let registry = context.jobRegistry, let runtimeID = context.runtimeID else {
            throw AgentToolError.invalidArgument("Background job registry not available.")
        }
        guard let handle = arguments["job_id"]?.stringValue(),
              !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.missingArgument("job_id")
        }
        let result: (job: AgentBackgroundJob, didSignal: Bool)? = await MainActor.run {
            guard let job = registry.job(matchingHandle: handle, runtimeID: runtimeID) else { return nil }
            let signaled = registry.kill(id: job.id)
            return (job, signaled)
        }
        guard let result else {
            throw AgentJobError.jobNotFound(handle)
        }
        if result.didSignal {
            return AgentToolResult(
                summary: "\(result.job.displayHandle) killed",
                payload: "Sent SIGTERM to \(result.job.displayHandle) (pid \(result.job.pid)). A completion notice will arrive on the next turn."
            )
        } else {
            return AgentToolResult(
                summary: "\(result.job.displayHandle) not running",
                payload: "\(result.job.displayHandle) was already \(result.job.status.rawValue); nothing to kill."
            )
        }
    }

    static func listQueuedTasks(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        let includeFinished = arguments["include_finished"]?.boolValue() ?? false
        let queueSnapshot = await MainActor.run {
            context.sessionQueueSnapshotProvider?()
        } ?? AgentSessionQueueSnapshot(queuedMessages: [], pendingDispatches: [])

        let jobs: [AgentBackgroundJob] = await MainActor.run {
            guard let registry = context.jobRegistry, let runtimeID = context.runtimeID else { return [] }
            let scoped = registry.jobs(forRuntime: runtimeID)
            return includeFinished ? scoped : scoped.filter { $0.isAlive || $0.needsAttention }
        }
        let mediaTasks: [AgentMediaTask] = await MainActor.run {
            guard let registry = context.mediaTaskRegistry else { return [] }
            let scoped = registry.tasks(forRuntime: context.runtimeID)
            return includeFinished ? scoped : scoped.filter { $0.isActive || $0.needsAttention }
        }
        let buildQueue = projectBuildGuardQueueEntries(rootDirectory: context.rootDirectory)
        let shouldDeferHeavyActions = !queueSnapshot.queuedMessages.isEmpty || !queueSnapshot.pendingDispatches.isEmpty

        var lines: [String] = [
            "defer_heavy_actions_recommended: \(shouldDeferHeavyActions)",
            "reason: \(shouldDeferHeavyActions ? "The current session has queued user work or is waiting for a provider slot." : "No queued user messages or provider dispatch waits in the current session.")",
            "counts:",
            "- queued_user_messages: \(queueSnapshot.queuedMessages.count)",
            "- pending_provider_dispatches: \(queueSnapshot.pendingDispatches.count)",
            "- active_background_jobs: \(jobs.filter { $0.isAlive }.count)",
            "- active_media_tasks: \(mediaTasks.filter { $0.isActive }.count)",
            "- project_build_guard_queue_entries: \(buildQueue.count)"
        ]

        if !queueSnapshot.queuedMessages.isEmpty {
            lines.append("queued_user_messages:")
            for (offset, message) in queueSnapshot.queuedMessages.enumerated() {
                lines.append("- #\(offset + 1) \(message.id.uuidString): \(preview(message.text))\(attachmentSummary(images: message.images.count, textAttachments: message.textAttachments.count, skills: message.attachedSkills.count))")
            }
        }
        if !queueSnapshot.pendingDispatches.isEmpty {
            lines.append("pending_provider_dispatches:")
            for (offset, dispatch) in queueSnapshot.pendingDispatches.enumerated() {
                lines.append("- #\(offset + 1) provider=\(dispatch.providerID) queued_for=\(formatDuration(Date().timeIntervalSince(dispatch.enqueuedAt))) message_id=\(dispatch.userMessageID.uuidString): \(preview(dispatch.text))")
            }
        }
        if !jobs.isEmpty {
            lines.append("background_jobs:")
            lines.append(contentsOf: jobs.map { "- \(describe(job: $0))" })
        }
        if !mediaTasks.isEmpty {
            lines.append("media_tasks:")
            lines.append(contentsOf: mediaTasks.map { "- \(describe(mediaTask: $0))" })
        }
        if !buildQueue.isEmpty {
            lines.append("project_build_guard_queue:")
            lines.append(contentsOf: buildQueue.map { "- \($0.summaryLine)" })
        }

        let jsonObject: [String: Any] = [
            "defer_heavy_actions_recommended": shouldDeferHeavyActions,
            "queued_user_messages": queueSnapshot.queuedMessages.enumerated().map { offset, message in
                [
                    "position": offset + 1,
                    "id": message.id.uuidString,
                    "preview": preview(message.text),
                    "image_count": message.images.count,
                    "text_attachment_count": message.textAttachments.count,
                    "skill_count": message.attachedSkills.count,
                    "execution_agent": message.executionAgent.rawValue
                ] as [String: Any]
            },
            "pending_provider_dispatches": queueSnapshot.pendingDispatches.enumerated().map { offset, dispatch in
                [
                    "position": offset + 1,
                    "user_message_id": dispatch.userMessageID.uuidString,
                    "provider_id": dispatch.providerID,
                    "enqueued_at": isoString(dispatch.enqueuedAt),
                    "preview": preview(dispatch.text),
                    "image_count": dispatch.imageCount,
                    "text_attachment_count": dispatch.textAttachmentCount,
                    "skill_count": dispatch.skillCount
                ] as [String: Any]
            },
            "background_jobs": jobs.map { job in
                [
                    "id": job.id.uuidString,
                    "handle": job.displayHandle,
                    "status": job.status.rawValue,
                    "is_alive": job.isAlive,
                    "exit_code": job.exitCode.map { Int($0) } ?? NSNull(),
                    "started_at": isoString(job.startedAt),
                    "finished_at": job.finishedAt.map(isoString) ?? NSNull(),
                    "command": preview(job.command, limit: 180)
                ] as [String: Any]
            },
            "media_tasks": mediaTasks.map { task in
                [
                    "id": task.id.uuidString,
                    "handle": task.displayHandle,
                    "status": task.status.rawValue,
                    "provider": task.provider.rawValue,
                    "kind": task.kind.rawValue,
                    "title": preview(task.title, limit: 120),
                    "progress": task.progress ?? NSNull(),
                    "updated_at": isoString(task.updatedAt),
                    "artifact_count": task.artifacts.count
                ] as [String: Any]
            },
            "project_build_guard_queue": buildQueue.map(\.jsonObject)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            lines.append("json:")
            lines.append(json)
        }

        let activeCount = jobs.filter(\.isAlive).count + mediaTasks.filter(\.isActive).count + buildQueue.count
        let summary = shouldDeferHeavyActions
            ? "queued user work: \(queueSnapshot.queuedMessages.count)"
            : "no queued user work; \(activeCount) active tracked tasks"
        return AgentToolResult(summary: summary, payload: lines.joined(separator: "\n"))
    }

    private static func describe(job: AgentBackgroundJob) -> String {
        let exit = job.exitCode.map { "exit=\($0)" } ?? "exit=…"
        let durationText = formatDuration(job.duration)
        let trimmedCommand = job.command.count > 100
            ? String(job.command.prefix(100)) + "…"
            : job.command
        return "\(job.displayHandle) [\(job.status.rawValue)] \(exit) · \(durationText) · pid=\(job.pid) · \(trimmedCommand)"
    }

    private static func describe(mediaTask task: AgentMediaTask) -> String {
        let progress = task.progress.map { " progress=\(Int(($0 * 100).rounded()))%" } ?? ""
        let updated = formatDuration(Date().timeIntervalSince(task.updatedAt))
        let title = preview(task.title, limit: 80)
        return "\(task.displayHandle) [\(task.status.rawValue)] \(task.provider.displayName)/\(task.kind.rawValue)\(progress) · updated \(updated) ago · \(title)"
    }

    private struct ProjectBuildQueueEntry {
        let id: String
        let position: Int
        let pid: Int32?
        let name: String
        let kind: String
        let fingerprint: String
        let command: [String]
        let createdAt: Date?
        let createdAtISO: String?
        let processAlive: Bool

        var summaryLine: String {
            let pidText = pid.map { "pid=\($0)" } ?? "pid=unknown"
            let commandText = command.joined(separator: " ")
            let shortFingerprint = fingerprint.isEmpty ? "no-fingerprint" : String(fingerprint.prefix(12))
            return "#\(position) \(name) [\(kind)] \(pidText) alive=\(processAlive) fingerprint=\(shortFingerprint) · \(AgentToolRunner.preview(commandText, limit: 120))"
        }

        var jsonObject: [String: Any] {
            [
                "id": id,
                "position": position,
                "pid": pid.map { Int($0) } ?? NSNull(),
                "name": name,
                "kind": kind,
                "fingerprint": fingerprint,
                "command": command,
                "created_at": createdAt.map(AgentToolRunner.isoString) ?? NSNull(),
                "created_at_iso": createdAtISO ?? NSNull(),
                "process_alive": processAlive
            ]
        }
    }

    private static func projectBuildGuardQueueEntries(rootDirectory: URL?) -> [ProjectBuildQueueEntry] {
        guard let rootDirectory else { return [] }
        let localStateURL = rootDirectory
            .standardizedFileURL
            .appendingPathComponent(".codex-build", isDirectory: true)
        let coordinationURL = localStateURL.appendingPathComponent("coordination.json", isDirectory: false)
        let queueURL: URL
        if let data = try? Data(contentsOf: coordinationURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sharedQueuePath = object["queue_dir"] as? String,
           !sharedQueuePath.isEmpty {
            queueURL = URL(fileURLWithPath: sharedQueuePath, isDirectory: true).standardizedFileURL
        } else {
            queueURL = localStateURL.appendingPathComponent("queue", isDirectory: true)
        }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: queueURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoded: [(url: URL, object: [String: Any])] = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                return (url, object)
            }
            .sorted { lhs, rhs in
                let leftCreated = doubleValue(lhs.object["created_at"]) ?? 0
                let rightCreated = doubleValue(rhs.object["created_at"]) ?? 0
                if leftCreated != rightCreated { return leftCreated < rightCreated }
                return stringValue(lhs.object["id"]) < stringValue(rhs.object["id"])
            }

        return decoded.enumerated().map { offset, item in
            let object = item.object
            let pid = int32Value(object["pid"])
            let createdAt = doubleValue(object["created_at"]).map(Date.init(timeIntervalSince1970:))
            return ProjectBuildQueueEntry(
                id: stringValue(object["id"], fallback: item.url.deletingPathExtension().lastPathComponent),
                position: offset + 1,
                pid: pid,
                name: stringValue(object["name"], fallback: "build"),
                kind: stringValue(object["kind"], fallback: "build"),
                fingerprint: stringValue(object["fingerprint"]),
                command: stringArrayValue(object["command"]),
                createdAt: createdAt,
                createdAtISO: stringValue(object["created_at_iso"]).isEmpty ? nil : stringValue(object["created_at_iso"]),
                processAlive: pid.map(processAlive) ?? false
            )
        }
    }

    nonisolated private static func processAlive(pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private static func attachmentSummary(images: Int, textAttachments: Int, skills: Int) -> String {
        var parts: [String] = []
        if images > 0 { parts.append("images=\(images)") }
        if textAttachments > 0 { parts.append("attachments=\(textAttachments)") }
        if skills > 0 { parts.append("skills=\(skills)") }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    private static func preview(_ value: String, limit: Int = 160) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit)) + "…"
    }

    nonisolated private static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func stringValue(_ value: Any?, fallback: String = "") -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return fallback
        }
    }

    private static func stringArrayValue(_ value: Any?) -> [String] {
        switch value {
        case let strings as [String]:
            return strings
        case let array as [Any]:
            return array.map { stringValue($0) }.filter { !$0.isEmpty }
        default:
            return []
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let double as Double:
            return double
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private static func int32Value(_ value: Any?) -> Int32? {
        guard let double = doubleValue(value), double >= Double(Int32.min), double <= Double(Int32.max) else {
            return nil
        }
        return Int32(double)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let m = total / 60
        let s = total % 60
        if m < 60 { return "\(m)m\(s)s" }
        let h = m / 60
        let mm = m % 60
        return "\(h)h\(mm)m"
    }
}
