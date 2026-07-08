import CryptoKit
import Foundation

struct MobileRemotePushRegistration: Codable, Equatable {
    var provider: String
    var clientID: String
    var appID: String
    var updatedAt: Date
}

struct MobileRemoteAttentionPayload: Codable, Equatable {
    var targetType: String
    var targetID: String
    var sessionID: String?
    var title: String
    var summary: String
    var toolName: String?
    var inputPreview: String?
    var path: String?
    var kind: String?
    var requiresAnswer: Bool
    var requiresConfirmation: Bool

    enum CodingKeys: String, CodingKey {
        case targetType = "target_type"
        case targetID = "target_id"
        case sessionID = "session_id"
        case title
        case summary
        case toolName = "tool_name"
        case inputPreview = "input_preview"
        case path
        case kind
        case requiresAnswer = "requires_answer"
        case requiresConfirmation = "requires_confirmation"
    }

    var dedupeKey: String { "\(targetType):\(targetID)" }
}

@MainActor
final class MobileRemotePushNotifier {
    static let shared = MobileRemotePushNotifier()

    private var sentTargets: [String: Date] = [:]
    private let store = MobileRemotePushStore()
    private let sender = UmengRemotePushSender()
    private let dedupeTTL: TimeInterval = 24 * 60 * 60

    func register(provider: String, clientID: String, appID: String) {
        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedProvider == "umeng", !normalizedClientID.isEmpty else { return }
        store.save(
            MobileRemotePushRegistration(
                provider: normalizedProvider,
                clientID: normalizedClientID,
                appID: appID.trimmingCharacters(in: .whitespacesAndNewlines),
                updatedAt: Date()
            )
        )
    }

    func notifyIfNeeded(_ payload: MobileRemoteAttentionPayload, now: Date = Date()) {
        guard let registration = store.load(),
              registration.provider == "umeng",
              !registration.clientID.isEmpty else {
            return
        }
        if let sentAt = sentTargets[payload.dedupeKey], now.timeIntervalSince(sentAt) < dedupeTTL {
            return
        }
        sentTargets[payload.dedupeKey] = now
        sentTargets = sentTargets.filter { now.timeIntervalSince($0.value) < dedupeTTL }
        let sender = sender
        Task {
            do {
                try await sender.send(clientID: registration.clientID, payload: payload)
            } catch {
                NSLog("[MobileRemotePush] send failed target=%@ error=%@", payload.dedupeKey, error.localizedDescription)
            }
        }
    }
}

extension MobileRemoteAttentionPayload {
    init(_ approval: AgentMobileGatewayToolApprovalSnapshot) {
        self.init(
            targetType: "tool",
            targetID: approval.id,
            sessionID: approval.sessionID.uuidString,
            title: approval.title.isEmpty ? "WillDeep needs approval" : approval.title,
            summary: approval.summary.isEmpty ? approval.inputPreview : approval.summary,
            toolName: approval.toolName,
            inputPreview: approval.inputPreview,
            path: nil,
            kind: approval.toolName,
            requiresAnswer: approval.toolName.caseInsensitiveCompare("ask_user") == .orderedSame,
            requiresConfirmation: approval.requiresConfirmation
        )
    }

    init(_ proposal: AgentMobileGatewayPatchSnapshot) {
        self.init(
            targetType: "patch",
            targetID: proposal.id.uuidString,
            sessionID: proposal.sessionID.uuidString,
            title: proposal.title.isEmpty ? "WillDeep has a patch to review" : proposal.title,
            summary: proposal.summary,
            toolName: nil,
            inputPreview: proposal.path,
            path: proposal.path,
            kind: nil,
            requiresAnswer: false,
            requiresConfirmation: false
        )
    }
}

struct MobileRemotePushStore {
    private let key = "com.willdeep.mobileRemotePush.registration"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ registration: MobileRemotePushRegistration) {
        guard let data = try? JSONEncoder().encode(registration) else { return }
        defaults.set(data, forKey: key)
    }

    func load() -> MobileRemotePushRegistration? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(MobileRemotePushRegistration.self, from: data)
    }
}

struct MobileRemotePushConfig {
    var enabled: Bool
    var appKey: String
    var appMasterSecret: String
    var endpoint: String
    var productionMode: Bool

    var isUsable: Bool {
        enabled && !appKey.isEmpty && !appMasterSecret.isEmpty && !endpoint.isEmpty
    }

    static func load() -> MobileRemotePushConfig {
        var values = Self.localProperties()
        ProcessInfo.processInfo.environment.forEach { values[$0.key] = $0.value }
        return MobileRemotePushConfig(
            enabled: Self.boolValue(values, keys: ["UMENG_PUSH_ENABLED", "WILLDEEP_MOBILE_PUSH_ENABLED"], fallback: false),
            appKey: Self.firstValue(values, keys: ["UMENG_APPKEY", "UMENG_APP_KEY"]),
            appMasterSecret: Self.firstValue(values, keys: ["UMENG_APP_MASTER_SECRET", "UMENG_MASTER_SECRET", "UMENG_MESSAGE_SECRET"]),
            endpoint: Self.firstValue(values, keys: ["UMENG_PUSH_ENDPOINT"], fallback: "https://msgapi.umeng.com/api/send"),
            productionMode: Self.boolValue(values, keys: ["UMENG_PRODUCTION_MODE"], fallback: false)
        )
    }

    private static func localProperties() -> [String: String] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var urls: [URL] = []
        urls.append(URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("local.properties"))
        urls.append(home.appendingPathComponent("local.properties"))
        urls.append(home.appendingPathComponent("Sites/Xedit/local.properties"))
        var values: [String: String] = [:]
        for url in urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                      let separator = trimmed.firstIndex(of: "=") else {
                    continue
                }
                let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rawValue = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                values[key] = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return values
    }

    private static func firstValue(_ values: [String: String], keys: [String], fallback: String = "") -> String {
        for key in keys {
            let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return value }
        }
        return fallback
    }

    private static func boolValue(_ values: [String: String], keys: [String], fallback: Bool) -> Bool {
        for key in keys {
            switch values[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: continue
            }
        }
        return fallback
    }
}

struct UmengRemotePushSender {
    func send(clientID: String, payload: MobileRemoteAttentionPayload) async throws {
        let config = MobileRemotePushConfig.load()
        guard config.isUsable else { return }
        let customData = try JSONEncoder().encode(payload)
        guard let custom = String(data: customData, encoding: .utf8) else { return }
        let body = UmengPushRequest(
            appkey: config.appKey,
            timestamp: "\(Int(Date().timeIntervalSince1970))",
            type: "unicast",
            deviceTokens: clientID,
            payload: UmengPushPayload(
                displayType: "message",
                body: UmengPushBody(custom: custom)
            ),
            productionMode: config.productionMode ? "true" : "false",
            description: "WillDeep mobile attention"
        )
        let requestBody = try JSONEncoder().encode(body)
        let sign = Self.sign(method: "POST", endpoint: config.endpoint, body: requestBody, secret: config.appMasterSecret)
        guard let url = URL(string: "\(config.endpoint)?sign=\(sign)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: data.prefix(512), encoding: .utf8) ?? ""
            throw NSError(domain: "MobileRemotePush", code: 1, userInfo: [NSLocalizedDescriptionKey: "Umeng request failed: \(text)"])
        }
    }

    private static func sign(method: String, endpoint: String, body: Data, secret: String) -> String {
        var bytes = Data()
        bytes.append(Data(method.utf8))
        bytes.append(Data(endpoint.utf8))
        bytes.append(body)
        bytes.append(Data(secret.utf8))
        return Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

private struct UmengPushRequest: Encodable {
    var appkey: String
    var timestamp: String
    var type: String
    var deviceTokens: String
    var payload: UmengPushPayload
    var productionMode: String
    var description: String

    enum CodingKeys: String, CodingKey {
        case appkey
        case timestamp
        case type
        case deviceTokens = "device_tokens"
        case payload
        case productionMode = "production_mode"
        case description
    }
}

private struct UmengPushPayload: Encodable {
    var displayType: String
    var body: UmengPushBody

    enum CodingKeys: String, CodingKey {
        case displayType = "display_type"
        case body
    }
}

private struct UmengPushBody: Encodable {
    var custom: String
}
