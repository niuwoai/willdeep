//
//  SomeIMAsyncMediaIntegration.swift
//  WillDeep
//
//  Async media task adapter for some.im-compatible relays. some.im is
//  OpenAI-compatible for many endpoints, but async image/video providers
//  commonly vary their envelope shape; this adapter accepts the usual
//  id/status/url/data/output fields and lets the tool specify endpoint
//  suffixes when the relay exposes a custom route.
//

import Foundation

struct SomeIMAsyncMediaResponse: Equatable {
    var id: String?
    var status: String
    var statusURL: String?
    var cancelURL: String?
    var output: AgentJSONValue?
    var error: AgentJSONValue?
    var raw: AgentJSONValue
}

struct SomeIMMediaArtifact: Equatable {
    var title: String
    var fileURL: URL
    var mimeType: String?
    var remoteURL: String?

    var mediaArtifact: AgentMediaArtifact {
        AgentMediaArtifact(
            title: title,
            filePath: fileURL.path,
            mimeType: mimeType,
            remoteURL: remoteURL
        )
    }
}

enum SomeIMAsyncMediaClient {
    static func submit(
        endpointSuffix: String,
        body: [String: Any],
        settings: SomeIMIntegrationSettings,
        apiKey: String,
        session: URLSession? = nil
    ) async throws -> SomeIMAsyncMediaResponse {
        let normalized = settings.normalized
        guard normalized.enabled else {
            throw AgentToolError.invalidArgument("some.im integration is disabled.")
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentClientError.missingAPIKey
        }
        let endpoint = try AgentNetworkSupport.endpoint(from: normalized.baseURL, suffix: cleanedSuffix(endpointSuffix))
        return try await sendJSON(
            url: endpoint,
            method: "POST",
            body: body,
            apiKey: apiKey,
            session: session ?? AgentNetworkSupport.defaultSession()
        )
    }

    static func poll(
        idOrURL: String,
        endpointSuffix: String?,
        settings: SomeIMIntegrationSettings,
        apiKey: String,
        session: URLSession? = nil
    ) async throws -> SomeIMAsyncMediaResponse {
        let normalized = settings.normalized
        guard normalized.enabled else {
            throw AgentToolError.invalidArgument("some.im integration is disabled.")
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentClientError.missingAPIKey
        }
        let url = try taskURL(idOrURL: idOrURL, endpointSuffix: endpointSuffix, baseURL: normalized.baseURL)
        return try await sendJSON(
            url: url,
            method: "GET",
            body: nil,
            apiKey: apiKey,
            session: session ?? AgentNetworkSupport.defaultSession()
        )
    }

    static func cancel(
        idOrURL: String,
        endpointSuffix: String?,
        settings: SomeIMIntegrationSettings,
        apiKey: String,
        session: URLSession? = nil
    ) async throws -> SomeIMAsyncMediaResponse {
        let normalized = settings.normalized
        guard normalized.enabled else {
            throw AgentToolError.invalidArgument("some.im integration is disabled.")
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentClientError.missingAPIKey
        }
        let url = try taskURL(idOrURL: idOrURL, endpointSuffix: endpointSuffix, baseURL: normalized.baseURL)
        return try await sendJSON(
            url: url,
            method: "POST",
            body: nil,
            apiKey: apiKey,
            session: session ?? AgentNetworkSupport.defaultSession()
        )
    }

    static func downloadArtifacts(
        from response: SomeIMAsyncMediaResponse,
        title: String,
        session: URLSession? = nil
    ) async throws -> [SomeIMMediaArtifact] {
        let directory = ImageWorkflowSupport.outputDirectory(prefix: "WillDeep-someIM")
        var artifacts: [SomeIMMediaArtifact] = []
        let values = outputValues(from: response)

        var base64Index = 1
        for value in values {
            if case .object(let dict) = value,
               let base64 = dict["b64_json"]?.stringValue(),
               let data = Data(base64Encoded: base64) {
                let filename = "\(safeFileStem(title))-b64-\(String(format: "%02d", base64Index)).png"
                let fileURL = uniqueFileURL(in: directory, filename: filename)
                try data.write(to: fileURL, options: [.atomic])
                artifacts.append(SomeIMMediaArtifact(title: fileURL.lastPathComponent, fileURL: fileURL, mimeType: "image/png", remoteURL: nil))
                base64Index += 1
            }
        }

        let urls = collectOutputURLs(from: response)
        for (index, remote) in urls.enumerated() {
            guard let url = URL(string: remote), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                continue
            }
            let downloaded = try await downloadRemoteArtifact(
                remoteURL: url,
                directory: directory,
                title: title,
                index: index + 1,
                session: session ?? AgentNetworkSupport.defaultSession()
            )
            artifacts.append(downloaded)
        }
        return artifacts
    }

    static func status(from rawStatus: String) -> AgentMediaTaskStatus {
        switch normalized(rawStatus) {
        case "queued", "created", "pending": return .queued
        case "submitted": return .submitted
        case "starting": return .starting
        case "processing", "running", "in_progress", "generating": return .processing
        case "succeeded", "success", "completed", "complete", "done": return .succeeded
        case "failed", "failure", "error": return .failed
        case "canceled", "cancelled", "cancelled_by_user": return .canceled
        default: return .submitted
        }
    }

    static func statusMessage(for response: SomeIMAsyncMediaResponse) -> String {
        if let error = response.error, error != .null {
            return "some.im \(response.status): \(error.displaySummary)"
        }
        return "some.im \(response.status)"
    }

    static func collectOutputURLs(from response: SomeIMAsyncMediaResponse) -> [String] {
        var result: [String] = []
        for value in outputValues(from: response) {
            collectURLs(from: value, into: &result)
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    static func defaultEndpointSuffix(for kind: AgentMediaTaskKind) -> String {
        switch kind {
        case .videoGeneration:
            return "videos/generations"
        case .imageGeneration, .imageEdit, .imageUpscale, .imageErase, .imageInpaint, .shortDrama, .unknown:
            return "images/generations"
        }
    }

    static func defaultModel(for kind: AgentMediaTaskKind, settings: SomeIMIntegrationSettings) -> String {
        let normalized = settings.normalized
        if kind == .videoGeneration, !normalized.preferredVideoModel.isEmpty {
            return normalized.preferredVideoModel
        }
        return normalized.preferredImageModel
    }

    private static func sendJSON(
        url: URL,
        method: String,
        body: [String: Any]?,
        apiKey: String,
        session: URLSession
    ) async throws -> SomeIMAsyncMediaResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        AgentNetworkSupport.applyStandardHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentToolError.invalidArgument("some.im returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "<non-UTF8 response body>"
            throw AgentToolError.httpFailed(http.statusCode, AgentNetworkSupport.limitDebugText(text))
        }
        let raw = try AgentJSONValue.decode(from: data)
        return parse(raw)
    }

    private static func parse(_ raw: AgentJSONValue) -> SomeIMAsyncMediaResponse {
        guard case .object(let object) = raw else {
            return SomeIMAsyncMediaResponse(id: nil, status: "succeeded", statusURL: nil, cancelURL: nil, output: raw, error: nil, raw: raw)
        }
        let id = firstString(in: object, keys: ["id", "task_id", "taskId", "request_id", "job_id", "prediction_id"])
        let status = firstString(in: object, keys: ["status", "state", "task_status"]) ?? (hasInlineOutput(object) ? "succeeded" : "submitted")
        let statusURL = firstString(in: object, keys: ["status_url", "statusUrl", "poll_url", "pollUrl"])
            ?? nestedString(in: object["urls"], keys: ["get", "status", "poll"])
        let cancelURL = firstString(in: object, keys: ["cancel_url", "cancelUrl"])
            ?? nestedString(in: object["urls"], keys: ["cancel"])
        let output = object["output"] ?? object["data"] ?? object["result"] ?? object["results"] ?? object["url"] ?? object["b64_json"]
        let error = object["error"] ?? object["message"]
        return SomeIMAsyncMediaResponse(
            id: id,
            status: status,
            statusURL: statusURL,
            cancelURL: cancelURL,
            output: output,
            error: error,
            raw: raw
        )
    }

    private static func outputValues(from response: SomeIMAsyncMediaResponse) -> [AgentJSONValue] {
        var values: [AgentJSONValue] = []
        if let output = response.output {
            values.append(output)
        }
        if case .object(let rawObject) = response.raw {
            if let data = rawObject["data"] {
                values.append(data)
            }
            if let url = rawObject["url"] {
                values.append(url)
            }
            if let b64 = rawObject["b64_json"] {
                values.append(.object(["b64_json": b64]))
            }
        }
        return values
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
    ) async throws -> SomeIMMediaArtifact {
        var request = URLRequest(url: remoteURL)
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentToolError.invalidArgument("some.im output download returned a non-HTTP response.")
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
        return SomeIMMediaArtifact(title: fileURL.lastPathComponent, fileURL: fileURL, mimeType: http.mimeType, remoteURL: remoteURL.absoluteString)
    }

    private static func taskURL(idOrURL: String, endpointSuffix: String?, baseURL: String) throws -> URL {
        let raw = idOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw AgentToolError.missingArgument("task_id")
        }
        if let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return url
        }
        guard let endpointSuffix, !endpointSuffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.invalidArgument("Provide status_url/cancel_url from the task, or pass a polling/cancel endpoint suffix.")
        }
        let endpoint = try AgentNetworkSupport.endpoint(from: baseURL, suffix: cleanedSuffix(endpointSuffix))
        return endpoint.appendingPathComponent(raw)
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
        object["data"] != nil || object["output"] != nil || object["url"] != nil || object["b64_json"] != nil
    }

    private static func cleanedSuffix(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t"))
    }

    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func fileExtension(for url: URL, mimeType: String?) -> String {
        let pathExt = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !pathExt.isEmpty { return ImageWorkflowSupport.normalizedExtension(pathExt) }
        switch mimeType?.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "video/mp4": return "mp4"
        case "video/webm": return "webm"
        default: return "bin"
        }
    }

    private static func safeFileStem(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return collapsed.isEmpty ? "someim-output" : String(collapsed.prefix(48))
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
}
