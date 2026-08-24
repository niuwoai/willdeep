//
//  AgentErrorModels.swift
//  WillDeep
//
//  Agent patch / client / provider error models split out of AgentModels.swift.
//

import Foundation

enum AgentPatchError: LocalizedError {
    case emptyDiff
    case unsupportedDiff
    case noWorkspace
    case pathOutsideWorkspace(String)
    case missingFile(String)
    case hunkDidNotMatch(String)
    case targetAlreadyExists(String)
    case duplicateTarget(String)
    case writeVerificationFailed(String)
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyDiff:
            return L10n.AgentPatchError.emptyDiff
        case .unsupportedDiff:
            return L10n.AgentPatchError.unsupportedDiff
        case .noWorkspace:
            return L10n.AgentPatchError.noWorkspace
        case .pathOutsideWorkspace(let path):
            return L10n.AgentPatchError.pathOutsideWorkspace(path)
        case .missingFile(let path):
            return L10n.AgentPatchError.missingFile(path)
        case .hunkDidNotMatch(let path):
            return L10n.AgentPatchError.hunkDidNotMatch(path)
        case .targetAlreadyExists(let path):
            return L10n.AgentPatchError.targetAlreadyExists(path)
        case .duplicateTarget(let path):
            return L10n.AgentPatchError.duplicateTarget(path)
        case .writeVerificationFailed(let path):
            return L10n.AgentPatchError.writeVerificationFailed(path)
        case .rollbackFailed(let path):
            return L10n.AgentPatchError.rollbackFailed(path)
        }
    }
}

enum AgentClientError: LocalizedError {
    case missingAPIKey
    case invalidBaseURL
    case invalidResponse
    case serverStatus(AgentProviderHTTPError)
    /// A dedicated vision-model preflight failed before the text-only main
    /// model was called. Keeping this separate prevents the error banner from
    /// implying that the main chat model received the image.
    case imageDescriptionServerStatus(AgentProviderHTTPError)
    /// The provider accepted the request (HTTP 2xx) but the SSE stream
    /// closed without emitting a single meaningful event — no text, no
    /// reasoning, no tool call, not even a finish_reason. A relay whose
    /// token has expired (or an upstream hiccup / rate-limit expressed as
    /// an empty body) shows up exactly like this. Without this case the
    /// turn would be treated as a silent success: placeholder dropped, no
    /// card, no reply — the user sees nothing happen.
    case emptyStream(providerID: String, model: String)
    /// Thrown when `AgentClient` is asked to talk to a provider whose
    /// transport-protocol family has no adapter wired up yet. Only
    /// expected during the multi-provider rollout — once Anthropic /
    /// Gemini / Responses adapters land this should become unreachable.
    case unsupportedProviderKind(AgentProviderKind)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an API key in Settings before sending an agent request."
        case .invalidBaseURL:
            return "The agent base URL is invalid."
        case .invalidResponse:
            return "The model provider returned an invalid response."
        case .serverStatus(let error):
            return "The model provider returned HTTP \(error.statusCode)."
        case .imageDescriptionServerStatus(let error):
            return "The vision model \(error.model) returned HTTP \(error.statusCode)."
        case .emptyStream(let providerID, let model):
            return "The provider \(providerID) (\(model)) returned an empty stream."
        case .unsupportedProviderKind(let kind):
            return "Support for the \(kind.rawValue) protocol is not enabled in this build yet."
        }
    }
}

/// Replaces Foundation's opaque "data format is incorrect" decoding error
/// with a compact description of the broken field and the payload shape that
/// was actually returned. The response preview intentionally reports only JSON
/// structure (or the body type), never raw response values.
struct AgentModelListResponseFormatError: LocalizedError {
    let decodingIssue: String
    let payloadShape: String
    let expectedSchema: String

    var errorDescription: String? {
        L10n.Settings.Provider.modelListInvalidFormat(
            decodingIssue,
            payloadShape,
            expectedSchema
        )
    }

    static func wrapping(
        _ error: Error,
        data: Data,
        expectedSchema: String
    ) -> AgentModelListResponseFormatError {
        AgentModelListResponseFormatError(
            decodingIssue: decodingIssue(for: error),
            payloadShape: payloadShape(for: data),
            expectedSchema: expectedSchema
        )
    }

    private static func decodingIssue(for error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return String(describing: error)
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "missing required key \"\(key.stringValue)\" at \(path(context.codingPath))"
        case .typeMismatch(let type, let context):
            return "\(path(context.codingPath)) has the wrong value type (expected \(type))"
        case .valueNotFound(let type, let context):
            return "\(path(context.codingPath)) is null or missing (expected \(type))"
        case .dataCorrupted(let context):
            return "invalid JSON value at \(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return String(describing: decodingError)
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "the top level" }
        return codingPath.reduce(into: "$") { result, key in
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                result += ".\(key.stringValue)"
            }
        }
    }

    private static func payloadShape(for data: Data) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return "not valid JSON"
        }
        switch value {
        case let object as [String: Any]:
            let keys = object.keys.sorted().prefix(8).map { "\"\($0)\"" }.joined(separator: ", ")
            return keys.isEmpty ? "an empty JSON object" : "a JSON object with keys [\(keys)]"
        case let array as [Any]:
            return "a top-level JSON array with \(array.count) item(s)"
        case is String:
            return "a top-level JSON string"
        case is NSNumber:
            return "a top-level JSON number or boolean"
        case is NSNull:
            return "JSON null"
        default:
            return "an unsupported JSON value"
        }
    }
}

struct AgentProviderBaseURLV1Candidate: Equatable {
    enum Adjustment: Equatable {
        case append
        case remove
    }

    let baseURL: String
    let adjustment: Adjustment
}

/// Conservative `/v1` recovery for OpenAI-compatible endpoints. We only use
/// the opposite candidate after the original model-list request returned HTTP
/// 404, and Settings still requires an explicit user click before persisting it.
struct AgentProviderBaseURLV1Probe {
    static func candidate(
        baseURL: String,
        providerKind: AgentProviderKind
    ) -> AgentProviderBaseURLV1Candidate? {
        guard providerKind == .openAIChat || providerKind == .openAIResponses else {
            return nil
        }
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else {
            return nil
        }
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            return nil
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let lowercasedPath = path.lowercased()
        guard !lowercasedPath.hasSuffix("chat/completions"),
              !lowercasedPath.hasSuffix("responses"),
              !lowercasedPath.hasSuffix("models") else {
            return nil
        }
        let segments = path.split(separator: "/").map(String.init)
        let adjustment: AgentProviderBaseURLV1Candidate.Adjustment
        if segments.last?.lowercased() == "v1" {
            let parent = segments.dropLast().joined(separator: "/")
            components.path = parent.isEmpty ? "" : "/\(parent)"
            adjustment = .remove
        } else {
            components.path = path.isEmpty ? "/v1" : "/\(path)/v1"
            adjustment = .append
        }
        guard let candidate = components.url?.absoluteString else { return nil }
        return AgentProviderBaseURLV1Candidate(baseURL: candidate, adjustment: adjustment)
    }

    static func shouldRetry(after error: Error) -> Bool {
        guard case AgentClientError.serverStatus(let httpError) = error else {
            return false
        }
        return httpError.statusCode == 404
    }
}

struct AgentProviderHTTPError: Equatable {
    let statusCode: Int
    let method: String
    let url: String
    let providerID: String
    let model: String
    let requestSummary: String
    let requestBody: String
    let responseBody: String
}

struct AgentErrorDetails: Equatable, Identifiable {
    let id = UUID()
    let sections: [Section]

    struct Section: Equatable, Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }
}

/// The last turn that ended without an assistant reply, persisted alongside
/// the conversation.
///
/// `AgentRuntime`'s error banner is `@Published` state that dies with the
/// process. That is fine for a human sitting in front of the chat, but a
/// scheduled routine that fails at 22:00 leaves nothing behind: the empty
/// assistant message is dropped by the turn loop, the banner disappears with
/// the app, and the reopened conversation reads as "message sent, never
/// answered". Persisting the failure lets the transcript re-show the same
/// error card — with its 重试 button — after a relaunch.
///
/// Detail sections are stored pre-truncated (see
/// `AppState.persistableDetailSections`): the live payload can carry an entire
/// provider request body, which has no business bloating every session file.
nonisolated struct AgentTurnFailure: Codable, Equatable, Sendable {
    nonisolated struct DetailSection: Codable, Equatable, Sendable {
        var title: String
        var text: String

        init(title: String, text: String) {
            self.title = title
            self.text = text
        }
    }

    var message: String
    var detailSections: [DetailSection]
    /// Mirrors `AgentRuntime.errorRequiresSomeIMLogin` so a restored card keeps
    /// offering "去登录 some.im" instead of a retry that cannot succeed.
    var requiresSomeIMLogin: Bool
    var occurredAt: Date

    init(
        message: String,
        detailSections: [DetailSection] = [],
        requiresSomeIMLogin: Bool = false,
        occurredAt: Date = Date()
    ) {
        self.message = message
        self.detailSections = detailSections
        self.requiresSomeIMLogin = requiresSomeIMLogin
        self.occurredAt = occurredAt
    }

    enum CodingKeys: String, CodingKey {
        case message, detailSections, requiresSomeIMLogin, occurredAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.message = try c.decode(String.self, forKey: .message)
        self.detailSections = try c.decodeIfPresent([DetailSection].self, forKey: .detailSections) ?? []
        self.requiresSomeIMLogin = try c.decodeIfPresent(Bool.self, forKey: .requiresSomeIMLogin) ?? false
        self.occurredAt = try c.decodeIfPresent(Date.self, forKey: .occurredAt) ?? Date()
    }
}

extension AgentErrorDetails {
    /// Rebuild the expandable "详情" payload from a persisted failure. Nil when
    /// the failure carried no sections, matching the live path where
    /// `AppState.details(for:)` returns nil for errors with nothing to show.
    init?(_ failure: AgentTurnFailure) {
        guard !failure.detailSections.isEmpty else { return nil }
        self.init(sections: failure.detailSections.map {
            Section(title: $0.title, text: $0.text)
        })
    }
}
