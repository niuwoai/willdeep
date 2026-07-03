//
//  AgentGenericMediaStatusIntegration.swift
//  WillDeep
//
//  Provider-neutral polling for third-party async media jobs registered by
//  Ruby skills or external API scripts. This intentionally supports only
//  public or pre-signed status URLs; authenticated providers should use their
//  dedicated adapters or update tasks through import_media_manifest.
//

import Foundation

struct AgentGenericMediaStatusResponse: Equatable {
    var remoteTaskID: String?
    var status: String
    var statusURL: String?
    var cancelURL: String?
    var output: AgentJSONValue?
    var error: AgentJSONValue?
    var raw: AgentJSONValue
}

enum AgentGenericMediaStatusClient {
    static func canPoll(_ task: AgentMediaTask) -> Bool {
        guard task.isActive,
              task.provider != .replicate,
              task.provider != .someIM,
              let statusURL = clean(task.statusURL),
              let url = URL(string: statusURL),
              url.scheme?.lowercased() == "https" else {
            return false
        }
        return true
    }

    static func canCancel(_ task: AgentMediaTask) -> Bool {
        guard task.isActive,
              task.provider != .replicate,
              task.provider != .someIM,
              let cancelURL = clean(task.cancelURL),
              let url = URL(string: cancelURL),
              url.scheme?.lowercased() == "https" else {
            return false
        }
        return true
    }

    static func poll(task: AgentMediaTask, session: URLSession? = nil) async throws -> AgentGenericMediaStatusResponse {
        guard let statusURL = clean(task.statusURL),
              let url = URL(string: statusURL),
              url.scheme?.lowercased() == "https" else {
            throw AgentToolError.invalidArgument("通用媒体任务刷新需要 HTTPS status_url。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        AgentNetworkSupport.applyStandardHeaders(to: &request)

        let (data, response) = try await (session ?? AgentNetworkSupport.defaultSession()).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentToolError.invalidArgument("通用媒体任务状态接口返回了非 HTTP 响应。")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "<non-UTF8 response body>"
            throw AgentToolError.httpFailed(http.statusCode, AgentNetworkSupport.limitDebugText(text))
        }
        let raw = try AgentJSONValue.decode(from: data)
        return parse(raw, fallbackStatusURL: statusURL)
    }

    static func cancel(task: AgentMediaTask, session: URLSession? = nil) async throws -> AgentGenericMediaStatusResponse {
        guard let cancelURL = clean(task.cancelURL),
              let url = URL(string: cancelURL),
              url.scheme?.lowercased() == "https" else {
            throw AgentToolError.invalidArgument("通用媒体任务取消需要 HTTPS cancel_url。")
        }
        let activeSession = session ?? AgentNetworkSupport.defaultSession()
        let (data, response) = try await cancelRequest(url: url, method: "POST", session: activeSession)
        if response.statusCode == 405 {
            let fallback = try await cancelRequest(url: url, method: "DELETE", session: activeSession)
            return try parseCancelResponse(data: fallback.data, response: fallback.response, task: task, cancelURL: cancelURL)
        }
        return try parseCancelResponse(data: data, response: response, task: task, cancelURL: cancelURL)
    }

    static func downloadArtifacts(
        from response: AgentGenericMediaStatusResponse,
        title: String,
        session: URLSession? = nil
    ) async throws -> [AgentMediaArtifact] {
        let directory = ImageWorkflowSupport.outputDirectory(prefix: "WillDeep-GenericMedia")
        var artifacts: [AgentMediaArtifact] = []
        var base64Index = 1

        for value in outputValues(from: response) {
            if case .object(let dict) = value,
               let base64 = firstString(in: dict, keys: ["b64_json", "base64", "image_base64", "video_base64"]),
               let data = Data(base64Encoded: base64) {
                let ext = dict["mime_type"]?.stringValue().flatMap(fileExtension(forMimeType:)) ?? "png"
                let filename = "\(safeFileStem(title))-b64-\(String(format: "%02d", base64Index)).\(ext)"
                let fileURL = uniqueFileURL(in: directory, filename: filename)
                try data.write(to: fileURL, options: [.atomic])
                artifacts.append(
                    AgentMediaArtifact(
                        title: fileURL.lastPathComponent,
                        filePath: fileURL.path,
                        mimeType: dict["mime_type"]?.stringValue()
                    )
                )
                base64Index += 1
            }
        }

        for (index, remote) in collectOutputURLs(from: response).enumerated() {
            guard let remoteURL = URL(string: remote),
                  ["http", "https"].contains(remoteURL.scheme?.lowercased() ?? "") else {
                continue
            }
            let artifact = try await downloadRemoteArtifact(
                remoteURL: remoteURL,
                directory: directory,
                title: title,
                index: index + 1,
                session: session ?? AgentNetworkSupport.defaultSession()
            )
            artifacts.append(artifact)
        }
        return artifacts
    }

    private static func cancelRequest(
        url: URL,
        method: String,
        session: URLSession
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentToolError.invalidArgument("通用媒体任务取消接口返回了非 HTTP 响应。")
        }
        return (data, http)
    }

    private static func parseCancelResponse(
        data: Data,
        response: HTTPURLResponse,
        task: AgentMediaTask,
        cancelURL: String
    ) throws -> AgentGenericMediaStatusResponse {
        guard (200..<300).contains(response.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "<non-UTF8 response body>"
            throw AgentToolError.httpFailed(response.statusCode, AgentNetworkSupport.limitDebugText(text))
        }
        guard !data.isEmpty else {
            return AgentGenericMediaStatusResponse(
                remoteTaskID: task.remoteTaskID,
                status: "canceled",
                statusURL: task.statusURL,
                cancelURL: cancelURL,
                output: nil,
                error: nil,
                raw: .object(["status": .string("canceled")])
            )
        }
        let raw = AgentJSONValue.decode(from: String(data: data, encoding: .utf8) ?? "")
        guard case .object = raw else {
            return AgentGenericMediaStatusResponse(
                remoteTaskID: task.remoteTaskID,
                status: "canceled",
                statusURL: task.statusURL,
                cancelURL: cancelURL,
                output: nil,
                error: raw,
                raw: raw
            )
        }
        return parse(raw, fallbackStatusURL: task.statusURL ?? cancelURL)
    }

    static func status(from rawStatus: String) -> AgentMediaTaskStatus {
        switch normalized(rawStatus) {
        case "queued", "created", "pending", "waiting": return .queued
        case "submitted", "accepted": return .submitted
        case "starting", "started", "initializing": return .starting
        case "processing", "running", "in_progress", "generating", "working": return .processing
        case "succeeded", "success", "completed", "complete", "done", "finished": return .succeeded
        case "failed", "failure", "error", "errored", "timeout": return .failed
        case "canceled", "cancelled", "cancelled_by_user": return .canceled
        default: return .submitted
        }
    }

    static func statusMessage(for response: AgentGenericMediaStatusResponse) -> String {
        if let error = response.error, error != .null {
            return "第三方媒体任务 \(response.status): \(error.displaySummary)"
        }
        return "第三方媒体任务 \(response.status)"
    }

    private static func parse(_ raw: AgentJSONValue, fallbackStatusURL: String) -> AgentGenericMediaStatusResponse {
        guard case .object(let object) = raw else {
            return AgentGenericMediaStatusResponse(
                remoteTaskID: nil,
                status: "succeeded",
                statusURL: fallbackStatusURL,
                cancelURL: nil,
                output: raw,
                error: nil,
                raw: raw
            )
        }
        let status = firstString(in: object, keys: ["status", "state", "task_status", "phase"])
            ?? (hasInlineOutput(object) ? "succeeded" : "submitted")
        let output = firstOutputValue(in: object)
        return AgentGenericMediaStatusResponse(
            remoteTaskID: firstString(in: object, keys: ["id", "task_id", "taskId", "request_id", "job_id", "prediction_id"]),
            status: status,
            statusURL: firstString(in: object, keys: ["status_url", "statusUrl", "poll_url", "pollUrl"]) ?? nestedString(in: object["urls"], keys: ["get", "status", "poll"]) ?? fallbackStatusURL,
            cancelURL: firstString(in: object, keys: ["cancel_url", "cancelUrl"]) ?? nestedString(in: object["urls"], keys: ["cancel"]),
            output: output,
            error: object["error"] ?? object["message"],
            raw: raw
        )
    }

    private static func outputValues(from response: AgentGenericMediaStatusResponse) -> [AgentJSONValue] {
        var values: [AgentJSONValue] = []
        if let output = response.output {
            values.append(output)
        }
        if case .object(let object) = response.raw {
            for key in outputValueKeys {
                if let value = object[key] {
                    values.append(value)
                }
            }
            if let b64 = object["b64_json"] {
                values.append(.object(["b64_json": b64]))
            }
        }
        return values
    }

    private static func collectOutputURLs(from response: AgentGenericMediaStatusResponse) -> [String] {
        var result: [String] = []
        for value in outputValues(from: response) {
            collectURLs(from: value, into: &result)
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    private static func collectURLs(from value: AgentJSONValue, into result: inout [String]) {
        switch value {
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                result.append(trimmed)
            }
        case .array(let values):
            for value in values {
                collectURLs(from: value, into: &result)
            }
        case .object(let dict):
            for value in dict.values {
                collectURLs(from: value, into: &result)
            }
        case .null, .bool, .number:
            break
        }
    }

    private static func downloadRemoteArtifact(
        remoteURL: URL,
        directory: URL,
        title: String,
        index: Int,
        session: URLSession
    ) async throws -> AgentMediaArtifact {
        var request = URLRequest(url: remoteURL)
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentToolError.invalidArgument("第三方媒体输出下载返回了非 HTTP 响应。")
        }
        guard (200..<300).contains(http.statusCode) else {
            let data = (try? Data(contentsOf: temporaryURL)) ?? Data()
            let text = String(data: data.prefix(64 * 1024), encoding: .utf8) ?? "<non-UTF8 response body>"
            try? FileManager.default.removeItem(at: temporaryURL)
            throw AgentToolError.httpFailed(http.statusCode, AgentNetworkSupport.limitDebugText(text))
        }
        let ext = fileExtension(for: remoteURL, mimeType: http.mimeType)
        let filename = "\(safeFileStem(title))-\(String(format: "%02d", index)).\(ext)"
        let fileURL = uniqueFileURL(in: directory, filename: filename)
        try AgentNetworkSupport.moveDownloadedFile(from: temporaryURL, to: fileURL)
        return AgentMediaArtifact(title: fileURL.lastPathComponent, filePath: fileURL.path, mimeType: http.mimeType, remoteURL: remoteURL.absoluteString)
    }

    private static func firstString(in object: [String: AgentJSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key]?.stringValue()?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func nestedString(in value: AgentJSONValue?, keys: [String]) -> String? {
        guard case .object(let object) = value else { return nil }
        return firstString(in: object, keys: keys)
    }

    private static func hasInlineOutput(_ object: [String: AgentJSONValue]) -> Bool {
        firstOutputValue(in: object) != nil
    }

    private static func firstOutputValue(in object: [String: AgentJSONValue]) -> AgentJSONValue? {
        for key in outputValueKeys {
            if let value = object[key] {
                return value
            }
        }
        return nil
    }

    private static let outputValueKeys = [
        "output",
        "outputs",
        "result",
        "results",
        "data",
        "url",
        "media_url",
        "result_url",
        "output_url",
        "image_url",
        "video_url",
        "download_url",
        "artifact_url",
        "file_url",
        "media",
        "images",
        "videos",
        "artifacts",
        "files",
        "b64_json",
        "image_base64",
        "video_base64"
    ]

    private static func fileExtension(for url: URL, mimeType: String?) -> String {
        let pathExt = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !pathExt.isEmpty { return ImageWorkflowSupport.normalizedExtension(pathExt) }
        return mimeType.flatMap(fileExtension(forMimeType:)) ?? "bin"
    }

    nonisolated private static func fileExtension(forMimeType mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "video/mp4": return "mp4"
        case "video/webm": return "webm"
        case "video/quicktime": return "mov"
        default: return "bin"
        }
    }

    private static func safeFileStem(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return collapsed.isEmpty ? "generic-media-output" : String(collapsed.prefix(48))
    }

    private static func uniqueFileURL(in directory: URL, filename: String) -> URL {
        let original = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: original.path) else {
            return original
        }
        let ext = original.pathExtension
        let stem = original.deletingPathExtension().lastPathComponent
        var counter = 2
        while true {
            let nextName = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            let nextURL = directory.appendingPathComponent(nextName)
            if !FileManager.default.fileExists(atPath: nextURL.path) {
                return nextURL
            }
            counter += 1
        }
    }

    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func clean(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
