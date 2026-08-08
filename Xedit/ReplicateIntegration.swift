//
//  ReplicateIntegration.swift
//  WillDeep
//
//  Minimal Replicate prediction adapter used by Agent tools. The UI
//  observes jobs through AgentMediaTaskRegistry; this file only owns the
//  provider protocol details and local artifact download.
//

import Foundation
import SwiftUI

struct ReplicateWorkflowSettings: Codable, Equatable {
    var upscaleVersion: String = ""
    var eraseVersion: String = ""
    var inpaintVersion: String = ""

    var normalized: ReplicateWorkflowSettings {
        ReplicateWorkflowSettings(
            upscaleVersion: upscaleVersion.trimmingCharacters(in: .whitespacesAndNewlines),
            eraseVersion: eraseVersion.trimmingCharacters(in: .whitespacesAndNewlines),
            inpaintVersion: inpaintVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

enum ReplicateIntegrationStore {
    private static let apiTokenAccount = "replicate-api-token"
    private static let workflowSettingsKey = "com.willdeep.replicate.workflowSettings.v1"

    static func loadSavedAPIToken() -> String {
        AgentCredentialStore.load(account: apiTokenAccount)
    }

    static func loadAPIToken() -> String {
        let stored = loadSavedAPIToken()
        if !stored.isEmpty { return stored }
        return ProcessInfo.processInfo.environment["REPLICATE_API_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func saveAPIToken(_ token: String) {
        AgentCredentialStore.save(token, account: apiTokenAccount)
    }

    static func loadWorkflowSettings() -> ReplicateWorkflowSettings {
        guard let data = UserDefaults.standard.data(forKey: workflowSettingsKey),
              let settings = try? JSONDecoder().decode(ReplicateWorkflowSettings.self, from: data) else {
            return ReplicateWorkflowSettings()
        }
        return settings.normalized
    }

    static func saveWorkflowSettings(_ settings: ReplicateWorkflowSettings) {
        let normalized = settings.normalized
        if let data = try? JSONEncoder().encode(normalized) {
            UserDefaults.standard.set(data, forKey: workflowSettingsKey)
        }
    }

    static var isConfigured: Bool {
        !loadAPIToken().isEmpty
    }

    static var isConfiguredByEnvironment: Bool {
        loadSavedAPIToken().isEmpty
            && !(ProcessInfo.processInfo.environment["REPLICATE_API_TOKEN"]?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

struct ReplicateIntegrationSettingsView: View {
    var body: some View {
        Form {
            ReplicateIntegrationSettingsSections()
        }
        .formStyle(.grouped)
    }
}

/// Replicate's settings sections without the enclosing Form, so the
/// connectors hub can embed them next to the collaboration platforms.
struct ReplicateIntegrationSettingsSections: View {
    @State private var apiToken = ReplicateIntegrationStore.loadSavedAPIToken()
    @State private var workflowSettings = ReplicateIntegrationStore.loadWorkflowSettings()
    @State private var status = ""

    var body: some View {
        Group {
            Section("Replicate") {
                LabeledContent("API Token") {
                    RevealableSecretField(text: $apiToken, placeholder: "", onCommit: save)
                }

                HStack {
                    Button(L10n.Settings.buttonSave) {
                        save()
                    }
                    Button("清除") {
                        apiToken = ""
                        save()
                    }
                    .disabled(apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !ReplicateIntegrationStore.isConfigured)

                    if !status.isEmpty {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if ReplicateIntegrationStore.isConfiguredByEnvironment {
                    Label("已通过 REPLICATE_API_TOKEN 环境变量配置", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label(ReplicateIntegrationStore.isConfigured ? "Replicate 已配置" : "Replicate 未配置", systemImage: ReplicateIntegrationStore.isConfigured ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("用于 Replicate 图片放大、擦除、蒙版重绘和视频/图片预测任务。Token 存入 Keychain；不会写入聊天、日志或提交内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("默认 Workflow Versions") {
                LabeledContent("图片放大") {
                    TextField("Replicate version hash", text: $workflowSettings.upscaleVersion)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("图片擦除") {
                    TextField("Replicate version hash", text: $workflowSettings.eraseVersion)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("蒙版重绘") {
                    TextField("Replicate version hash", text: $workflowSettings.inpaintVersion)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button(L10n.Settings.buttonSave) {
                        save()
                    }
                    if !status.isEmpty {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("填写常用 Replicate model version hash 后，媒体任务图片缩略图可直接发起放大；图片编辑面板也可复用蒙版重绘默认 version。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        ReplicateIntegrationStore.saveAPIToken(apiToken.trimmingCharacters(in: .whitespacesAndNewlines))
        workflowSettings = workflowSettings.normalized
        ReplicateIntegrationStore.saveWorkflowSettings(workflowSettings)
        status = L10n.Settings.savedStatus
    }
}

struct ReplicatePrediction: Decodable, Equatable {
    struct URLs: Decodable, Equatable {
        var get: String?
        var cancel: String?
        var stream: String?
    }

    var id: String
    var status: String
    var version: String?
    var output: AgentJSONValue?
    var error: AgentJSONValue?
    var urls: URLs?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case version
        case output
        case error
        case urls
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decode(String.self, forKey: .status)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        urls = try container.decodeIfPresent(URLs.self, forKey: .urls)
        output = try container.decodeIfPresent(ReplicateJSONBox.self, forKey: .output)?.value
        error = try container.decodeIfPresent(ReplicateJSONBox.self, forKey: .error)?.value
    }
}

struct ReplicateArtifact: Equatable {
    var title: String
    var fileURL: URL
    var mimeType: String?
    var remoteURL: String

    var mediaArtifact: AgentMediaArtifact {
        AgentMediaArtifact(
            title: title,
            filePath: fileURL.path,
            mimeType: mimeType,
            remoteURL: remoteURL
        )
    }
}

enum ReplicateClient {
    nonisolated static let defaultBaseURL = "https://api.replicate.com/v1"

    static func createPrediction(
        version: String,
        inputJSON: String,
        webhook: String? = nil,
        baseURL: String = defaultBaseURL,
        session: URLSession? = nil
    ) async throws -> ReplicatePrediction {
        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVersion.isEmpty else {
            throw AgentToolError.missingArgument("version")
        }
        let input = try parseInputObject(inputJSON)
        let url = try AgentNetworkSupport.endpoint(from: baseURL, suffix: "predictions")
        var body: [String: Any] = [
            "version": trimmedVersion,
            "input": input,
        ]
        if let webhook = clean(webhook) {
            body["webhook"] = webhook
        }
        return try await sendJSON(
            url: url,
            method: "POST",
            body: body,
            session: session ?? AgentNetworkSupport.defaultSession()
        )
    }

    static func getPrediction(
        idOrURL: String,
        baseURL: String = defaultBaseURL,
        session: URLSession? = nil
    ) async throws -> ReplicatePrediction {
        let url = try predictionURL(idOrURL: idOrURL, baseURL: baseURL)
        return try await sendJSON(url: url, method: "GET", body: nil, session: session ?? AgentNetworkSupport.defaultSession())
    }

    static func cancelPrediction(
        idOrURL: String,
        baseURL: String = defaultBaseURL,
        session: URLSession? = nil
    ) async throws -> ReplicatePrediction {
        let base = try predictionURL(idOrURL: idOrURL, baseURL: baseURL)
        let url = base.absoluteString.hasSuffix("/cancel")
            ? base
            : base.appendingPathComponent("cancel")
        return try await sendJSON(url: url, method: "POST", body: nil, session: session ?? AgentNetworkSupport.defaultSession())
    }

    static func downloadArtifacts(
        from prediction: ReplicatePrediction,
        title: String,
        session: URLSession? = nil
    ) async throws -> [ReplicateArtifact] {
        let urls = collectOutputURLs(from: prediction.output)
        guard !urls.isEmpty else { return [] }

        let directory = ImageWorkflowSupport.outputDirectory(prefix: "WillDeep-Replicate")
        var artifacts: [ReplicateArtifact] = []
        for (index, remote) in urls.enumerated() {
            guard let url = URL(string: remote), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                continue
            }
            let downloaded = try await downloadArtifact(
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

    static func status(from replicateStatus: String) -> AgentMediaTaskStatus {
        switch normalized(replicateStatus) {
        case "starting": return .starting
        case "processing": return .processing
        case "succeeded": return .succeeded
        case "failed": return .failed
        case "canceled", "cancelled": return .canceled
        default: return .submitted
        }
    }

    static func statusMessage(for prediction: ReplicatePrediction) -> String {
        if let error = prediction.error, error != .null {
            return "Replicate \(prediction.status): \(error.displaySummary)"
        }
        return "Replicate \(prediction.status)"
    }

    static func collectOutputURLs(from value: AgentJSONValue?) -> [String] {
        guard let value else { return [] }
        var result: [String] = []
        collectOutputURLs(from: value, into: &result)
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    private static func collectOutputURLs(from value: AgentJSONValue, into result: inout [String]) {
        switch value {
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                result.append(trimmed)
            }
        case .array(let values):
            for value in values {
                collectOutputURLs(from: value, into: &result)
            }
        case .object(let dict):
            for value in dict.values {
                collectOutputURLs(from: value, into: &result)
            }
        case .null, .bool, .number:
            break
        }
    }

    private static func sendJSON<T: Decodable>(
        url: URL,
        method: String,
        body: [String: Any]?,
        session: URLSession
    ) async throws -> T {
        let token = ReplicateIntegrationStore.loadAPIToken()
        guard !token.isEmpty else {
            throw AgentToolError.invalidArgument("Replicate API token is not configured. Set REPLICATE_API_TOKEN or save a Replicate token in Keychain.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        AgentNetworkSupport.applyStandardHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentToolError.invalidArgument("Replicate returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "<non-UTF8 response body>"
            throw AgentToolError.httpFailed(http.statusCode, AgentNetworkSupport.limitDebugText(text))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AgentToolError.invalidArgument("Could not parse Replicate response: \(error.localizedDescription)")
        }
    }

    private static func downloadArtifact(
        remoteURL: URL,
        directory: URL,
        title: String,
        index: Int,
        session: URLSession
    ) async throws -> ReplicateArtifact {
        let token = ReplicateIntegrationStore.loadAPIToken()
        var request = URLRequest(url: remoteURL)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentToolError.invalidArgument("Replicate output download returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let data = (try? Data(contentsOf: temporaryURL)) ?? Data()
            let text = String(data: data.prefix(64 * 1024), encoding: .utf8) ?? "<non-UTF8 response body>"
            try? FileManager.default.removeItem(at: temporaryURL)
            throw AgentToolError.httpFailed(http.statusCode, AgentNetworkSupport.limitDebugText(text))
        }

        let ext = fileExtension(for: remoteURL, mimeType: http.mimeType)
        let safeStem = safeFileStem(title.isEmpty ? "replicate-output" : title)
        let filename = "\(safeStem)-\(String(format: "%02d", index)).\(ext)"
        let fileURL = uniqueFileURL(in: directory, filename: filename)
        try AgentNetworkSupport.moveDownloadedFile(from: temporaryURL, to: fileURL)
        return ReplicateArtifact(
            title: fileURL.lastPathComponent,
            fileURL: fileURL,
            mimeType: http.mimeType,
            remoteURL: remoteURL.absoluteString
        )
    }

    private static func parseInputObject(_ inputJSON: String) throws -> [String: Any] {
        let trimmed = inputJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentToolError.missingArgument("input_json")
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw AgentToolError.invalidArgument("input_json is not UTF-8.")
        }
        let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let object = parsed as? [String: Any] else {
            throw AgentToolError.invalidArgument("input_json must be a JSON object.")
        }
        return object
    }

    private static func predictionURL(idOrURL: String, baseURL: String) throws -> URL {
        let raw = idOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw AgentToolError.missingArgument("prediction_id")
        }
        if let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return url
        }
        let base = try AgentNetworkSupport.endpoint(from: baseURL, suffix: "predictions")
        return base.appendingPathComponent(raw)
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
        case "application/json": return "json"
        default: return "bin"
        }
    }

    private static func safeFileStem(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return collapsed.isEmpty ? "replicate-output" : String(collapsed.prefix(48))
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

    private static func clean(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}

private struct ReplicateJSONBox: Decodable {
    let value: AgentJSONValue

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = .null
        } else if let boolean = try? container.decode(Bool.self) {
            value = .bool(boolean)
        } else if let number = try? container.decode(Double.self) {
            value = .number(number)
        } else if let string = try? container.decode(String.self) {
            value = .string(string)
        } else if let array = try? container.decode([ReplicateJSONBox].self) {
            value = .array(array.map(\.value))
        } else if let object = try? container.decode([String: ReplicateJSONBox].self) {
            var converted: [String: AgentJSONValue] = [:]
            for (key, box) in object {
                converted[key] = box.value
            }
            value = .object(converted)
        } else {
            value = .null
        }
    }
}
