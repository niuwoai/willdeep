//
//  SomeIMIntegration.swift
//  WillDeep
//
//  Settings, model discovery, and generation helpers for Rocky's
//  some.im relay. The API key stays in Keychain; non-secret routing
//  preferences live in UserDefaults.
//

import Foundation
import AppKit
import SwiftUI

enum SomeIMGenerationKind: String, Codable, CaseIterable, Identifiable {
    case image
    case video
    case text
    case unknown

    var id: String { rawValue }
}

enum SomeIMRelayRegion: String, CaseIterable, Identifiable {
    case china
    case international
    case custom

    static let chinaBaseURL = "https://api.niuwoai.com/v1"
    static let internationalBaseURL = "https://some.im/v1"

    var id: String { rawValue }

    var baseURL: String? {
        switch self {
        case .china:
            return Self.chinaBaseURL
        case .international:
            return Self.internationalBaseURL
        case .custom:
            return nil
        }
    }

    static func resolved(for baseURL: String) -> SomeIMRelayRegion {
        switch baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case chinaBaseURL.lowercased():
            return .china
        case internationalBaseURL.lowercased(), "":
            return .international
        default:
            return .custom
        }
    }
}

struct SomeIMModel: Identifiable, Codable, Equatable {
    var id: String { model }
    var model: String
    var kinds: [SomeIMGenerationKind]
    var isHot: Bool = false
    var isNew: Bool = false

    var supportsImageGeneration: Bool { kinds.contains(.image) || model.localizedCaseInsensitiveContains("image") }
    var supportsVideoGeneration: Bool { kinds.contains(.video) || model.localizedCaseInsensitiveContains("video") }
    var agentDiscovery: AgentModelDiscovery {
        AgentModelDiscovery(id: model, isHot: isHot, isNew: isNew)
    }
}

struct SomeIMIntegrationSettings: Codable, Equatable {
    static let defaultBaseURL = SomeIMRelayRegion.internationalBaseURL
    static let defaultImageModel = "gpt-image-2"
    static let defaultTextModel = "someim-auto-flash"
    static let defaultVisionModel = "qwen3-vl-plus"

    var enabled: Bool
    var baseURL: String
    var preferredImageModel: String
    var preferredImageModels: [String]
    var preferredVideoModel: String
    var preferredVideoModels: [String]

    init(
        enabled: Bool = false,
        baseURL: String = defaultBaseURL,
        preferredImageModel: String = defaultImageModel,
        preferredImageModels: [String] = [defaultImageModel],
        preferredVideoModel: String = "",
        preferredVideoModels: [String] = []
    ) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.preferredImageModel = preferredImageModel
        self.preferredImageModels = Self.cleanList(preferredImageModels, ensuringFirst: preferredImageModel)
        self.preferredVideoModel = preferredVideoModel
        self.preferredVideoModels = Self.cleanList(preferredVideoModels, ensuringFirst: preferredVideoModel)
    }

    var normalized: SomeIMIntegrationSettings {
        SomeIMIntegrationSettings(
            enabled: enabled,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? Self.defaultBaseURL,
            preferredImageModel: preferredImageModel.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? Self.defaultImageModel,
            preferredImageModels: preferredImageModels,
            preferredVideoModel: preferredVideoModel.trimmingCharacters(in: .whitespacesAndNewlines),
            preferredVideoModels: preferredVideoModels
        )
    }

    private static func cleanList(_ list: [String], ensuringFirst primary: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let head = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !head.isEmpty, seen.insert(head).inserted {
            result.append(head)
        }
        for item in list {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}

enum SomeIMIntegrationStore {
    static let accountDidChangeNotification = Notification.Name("com.willdeep.someIM.accountDidChange")

    private static let settingsKey = "com.willdeep.someIM.integrationSettings.v1"
    private static let accountKey = "com.willdeep.someIM.account.v1"
    private static let apiKeyAccount = "some-im/api-key"
    private static let sessionTokenAccount = "some-im/customer-session"

    static func loadSettings() -> SomeIMIntegrationSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode(SomeIMIntegrationSettings.self, from: data) else {
            return SomeIMIntegrationSettings()
        }
        return decoded.normalized
    }

    static func saveSettings(_ settings: SomeIMIntegrationSettings) {
        let normalized = settings.normalized
        if let data = try? JSONEncoder().encode(normalized) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    static func loadAccount() -> SomeIMAccount? {
        guard let data = UserDefaults.standard.data(forKey: accountKey) else { return nil }
        return try? JSONDecoder().decode(SomeIMAccount.self, from: data)
    }

    static func saveAccount(_ account: SomeIMAccount?) {
        if let account, let data = try? JSONEncoder().encode(account) {
            UserDefaults.standard.set(data, forKey: accountKey)
        } else {
            UserDefaults.standard.removeObject(forKey: accountKey)
        }
        NotificationCenter.default.post(name: accountDidChangeNotification, object: nil)
    }

    static func loadAPIKey() -> String {
        AgentCredentialStore.load(account: apiKeyAccount)
    }

    static func saveAPIKey(_ apiKey: String) {
        AgentCredentialStore.save(apiKey, account: apiKeyAccount)
    }

    static func loadSessionToken() -> String {
        AgentCredentialStore.load(account: sessionTokenAccount)
    }

    static func saveSessionToken(_ token: String) {
        AgentCredentialStore.save(token, account: sessionTokenAccount)
    }

    static func loadClientLoginSecret() -> String {
        let env = ProcessInfo.processInfo.environment["WILLDEEP_CLIENT_LOGIN_SECRET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !env.isEmpty { return env }
        let info = (Bundle.main.object(forInfoDictionaryKey: "WillDeepSomeIMClientLoginSecret") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if info.hasPrefix("$(") { return "" }
        return info
    }

    static var isConfigured: Bool {
        loadSettings().enabled && !loadAPIKey().isEmpty
    }
}

struct SomeIMAccount: Codable, Equatable {
    var email: String
    var tenantID: String?
    var balanceUSD: String
    var credits: String
    var creditsPerUSD: Int
    var defaultModel: String
    var lastUpdatedAt: Date

    var displayCredits: String {
        guard let value = Int64(credits) else { return credits }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}

struct SomeIMGeneratedImage: Equatable, Sendable {
    let fileURL: URL
    let model: String
}

enum SomeIMClient {
    private static let willDeepClientID = "willdeep"

    static func sendClientLoginCode(
        email: String,
        settings: SomeIMIntegrationSettings
    ) async throws {
        try await sendClientLoginCode(
            email: email,
            settings: settings,
            session: AgentNetworkSupport.defaultSession()
        )
    }

    static func sendClientLoginCode(
        email: String,
        settings: SomeIMIntegrationSettings,
        session: URLSession
    ) async throws {
        let endpoint = try publicAPIEndpoint(from: settings.normalized.baseURL, suffix: "public/client-login/email/send")
        var request = jsonRequest(url: endpoint, method: "POST")
        applyClientLoginSecret(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "client_id": willDeepClientID
        ], options: [.sortedKeys])
        let data = try await send(request, session: session)
        _ = try decodeEnvelope(ClientLoginSendData.self, from: data)
    }

    static func verifyClientLoginCode(
        email: String,
        code: String,
        settings: SomeIMIntegrationSettings
    ) async throws -> SomeIMAccount {
        try await verifyClientLoginCode(
            email: email,
            code: code,
            settings: settings,
            session: AgentNetworkSupport.defaultSession()
        )
    }

    static func verifyClientLoginCode(
        email: String,
        code: String,
        settings: SomeIMIntegrationSettings,
        session: URLSession
    ) async throws -> SomeIMAccount {
        let normalized = settings.normalized
        let endpoint = try publicAPIEndpoint(from: normalized.baseURL, suffix: "public/client-login/email/verify")
        var request = jsonRequest(url: endpoint, method: "POST")
        applyClientLoginSecret(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "code": code.trimmingCharacters(in: .whitespacesAndNewlines),
            "client_id": willDeepClientID
        ], options: [.sortedKeys])
        let data = try await send(request, session: session)
        let decoded = try decodeEnvelope(ClientLoginVerifyData.self, from: data)
        let account = decoded.account.account(
            fallbackEmail: email,
            fallbackModel: decoded.default_model.nonEmpty ?? SomeIMIntegrationSettings.defaultTextModel
        )
        SomeIMIntegrationStore.saveAPIKey(decoded.api_key)
        if let token = decoded.token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            SomeIMIntegrationStore.saveSessionToken(token)
        }
        SomeIMIntegrationStore.saveAccount(account)
        var nextSettings = normalized
        nextSettings.enabled = true
        SomeIMIntegrationStore.saveSettings(nextSettings)
        return account
    }

    static func fetchAccountBalance() async throws -> SomeIMAccount {
        try await fetchAccountBalance(
            settings: SomeIMIntegrationStore.loadSettings(),
            apiKey: SomeIMIntegrationStore.loadAPIKey(),
            session: AgentNetworkSupport.defaultSession()
        )
    }

    static func fetchAccountBalance(
        settings: SomeIMIntegrationSettings,
        apiKey: String,
        session: URLSession
    ) async throws -> SomeIMAccount {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw AgentClientError.missingAPIKey }
        let endpoint = try AgentNetworkSupport.endpoint(from: settings.normalized.baseURL, suffix: "account/balance")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        let data = try await send(request, session: session)
        let decoded = try JSONDecoder().decode(AccountBalanceData.self, from: data)
        let previous = SomeIMIntegrationStore.loadAccount()
        let balance = decoded.balance.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = SomeIMAccount(
            email: previous?.email ?? "",
            tenantID: decoded.tenant_id.nonEmpty ?? previous?.tenantID,
            balanceUSD: balance,
            credits: credits(fromUSD: balance),
            creditsPerUSD: 100000,
            defaultModel: previous?.defaultModel ?? SomeIMIntegrationSettings.defaultTextModel,
            lastUpdatedAt: Date()
        )
        SomeIMIntegrationStore.saveAccount(account)
        return account
    }

    static func fetchHandoffLoginURL() async throws -> URL {
        try await fetchHandoffLoginURL(
            settings: SomeIMIntegrationStore.loadSettings(),
            sessionToken: SomeIMIntegrationStore.loadSessionToken(),
            session: AgentNetworkSupport.defaultSession()
        )
    }

    static func fetchHandoffLoginURL(
        settings: SomeIMIntegrationSettings,
        sessionToken: String,
        session: URLSession
    ) async throws -> URL {
        let token = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw AgentToolError.invalidArgument("some.im session token is missing. Reconnect your account.")
        }
        let endpoint = try publicAPIEndpoint(from: settings.normalized.baseURL, suffix: "public/client-login/handoff-link")
        var request = jsonRequest(url: endpoint, method: "POST")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        applyClientLoginSecret(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["next": "/customer"], options: [.sortedKeys])
        let data = try await send(request, session: session)
        let decoded = try decodeEnvelope(HandoffLinkData.self, from: data)
        guard let url = URL(string: decoded.login_url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw AgentToolError.invalidArgument("some.im returned an invalid login URL.")
        }
        return url
    }

    static func fetchModels(
        settings: SomeIMIntegrationSettings,
        apiKey: String,
        session: URLSession
    ) async throws -> [SomeIMModel] {
        do {
            let models = try await fetchPricingModels(settings: settings.normalized, apiKey: apiKey, session: session)
            if !models.isEmpty { return models }
        } catch {
            // Fall through to OpenAI-compatible /models below. some.im
            // deployments may expose only one of these endpoints.
        }
        return try await fetchOpenAIModels(settings: settings.normalized, apiKey: apiKey, session: session)
    }

    static func fetchModels(
        settings: SomeIMIntegrationSettings,
        apiKey: String
    ) async throws -> [SomeIMModel] {
        try await fetchModels(settings: settings, apiKey: apiKey, session: AgentNetworkSupport.defaultSession())
    }

    static func generateImage(
        prompt: String,
        size: String = "1024x1024",
        model overrideModel: String? = nil
    ) async throws -> SomeIMGeneratedImage {
        try await generateImage(
            prompt: prompt,
            size: size,
            model: overrideModel,
            settings: SomeIMIntegrationStore.loadSettings(),
            apiKey: SomeIMIntegrationStore.loadAPIKey(),
            session: AgentNetworkSupport.defaultSession()
        )
    }

    static func generateImage(
        prompt: String,
        size: String,
        model overrideModel: String?,
        settings: SomeIMIntegrationSettings,
        apiKey: String,
        session: URLSession
    ) async throws -> SomeIMGeneratedImage {
        let normalized = settings.normalized
        guard normalized.enabled else {
            throw AgentToolError.invalidArgument("some.im integration is disabled.")
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentClientError.missingAPIKey
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw AgentToolError.missingArgument("prompt")
        }
        let model = overrideModel?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? normalized.preferredImageModel
        let endpoint = try AgentNetworkSupport.endpoint(from: normalized.baseURL, suffix: "images/generations")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = AgentNetworkSupport.resourceTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        let body: [String: Any] = [
            "model": model,
            "prompt": trimmedPrompt,
            "size": size,
            "response_format": "b64_json"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentToolError.httpFailed(http.statusCode, String(data: data, encoding: .utf8) ?? "<non-UTF8 response body>")
        }
        let decoded = try JSONDecoder().decode(ImageGenerationResponse.self, from: data)
        guard let first = decoded.data.first else {
            throw AgentToolError.invalidArgument("some.im returned no image data.")
        }
        let imageData: Data
        let fileExtension: String
        if let base64 = first.b64_json, let data = Data(base64Encoded: base64) {
            imageData = data
            fileExtension = "png"
        } else if let urlString = first.url, let url = URL(string: urlString) {
            let downloaded = try await session.data(from: url).0
            imageData = downloaded
            fileExtension = url.pathExtension.nonEmpty ?? "png"
        } else {
            throw AgentToolError.invalidArgument("some.im image response did not include b64_json or url.")
        }
        let fileURL = outputURL(fileExtension: fileExtension)
        try imageData.write(to: fileURL, options: [.atomic])
        return SomeIMGeneratedImage(fileURL: fileURL, model: model)
    }

    private static func fetchPricingModels(
        settings: SomeIMIntegrationSettings,
        apiKey: String,
        session: URLSession
    ) async throws -> [SomeIMModel] {
        guard let endpoint = publicPricingEndpoint(from: settings.baseURL) else {
            return []
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AgentClientError.invalidResponse
        }
        let decoded = try JSONDecoder().decode(PricingResponse.self, from: data)
        return decoded.items.map { item in
            SomeIMModel(model: item.model, kinds: item.detectedKinds, isHot: item.is_hot ?? false, isNew: item.is_new ?? false)
        }
    }

    private static func fetchOpenAIModels(
        settings: SomeIMIntegrationSettings,
        apiKey: String,
        session: URLSession
    ) async throws -> [SomeIMModel] {
        let configuration = AgentConfiguration(
            providerID: "some-im",
            baseURL: settings.baseURL,
            model: settings.preferredImageModel,
            apiKey: apiKey
        )
        return try await AgentClient(configuration: configuration, session: session)
            .fetchModelDiscoveries()
            .map { discovery in
                SomeIMModel(
                    model: discovery.id,
                    kinds: detectKinds(model: discovery.id, words: []),
                    isHot: discovery.isHot,
                    isNew: discovery.isNew
                )
            }
    }

    private static func publicPricingEndpoint(from baseURL: String) -> URL? {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        components.path = "/api/v1/public/model-pricing"
        components.query = nil
        return components.url
    }

    private static func publicAPIEndpoint(from baseURL: String, suffix: String) throws -> URL {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AgentClientError.invalidResponse
        }
        let cleaned = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/api/v1/\(cleaned)"
        components.query = nil
        guard let url = components.url else { throw AgentClientError.invalidResponse }
        return url
    }

    private static func jsonRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = AgentNetworkSupport.resourceTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        return request
    }

    private static func applyClientLoginSecret(to request: inout URLRequest) {
        let secret = SomeIMIntegrationStore.loadClientLoginSecret()
        guard !secret.isEmpty else { return }
        request.setValue(secret, forHTTPHeaderField: "X-WillDeep-Client-Secret")
    }

    private static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentToolError.httpFailed(http.statusCode, AgentNetworkSupport.limitDebugText(String(data: data, encoding: .utf8) ?? "<non-UTF8 response body>"))
        }
        return data
    }

    private static func decodeEnvelope<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if let direct = try? JSONDecoder().decode(T.self, from: data) {
            return direct
        }
        return try JSONDecoder().decode(APIEnvelope<T>.self, from: data).data
    }

    private static func credits(fromUSD usd: String) -> String {
        let decimal = Decimal(string: usd.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let credits = decimal * Decimal(100000)
        return max(Int64(0), NSDecimalNumber(decimal: credits).int64Value).description
    }

    private static func outputURL(fileExtension: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "willdeep-generated-image-\(formatter.string(from: Date())).\(fileExtension)"
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent(filename)
    }

    private static func detectKinds(model: String, words: [String]) -> [SomeIMGenerationKind] {
        let haystack = ([model] + words).joined(separator: " ").lowercased()
        var kinds: [SomeIMGenerationKind] = []
        if haystack.contains("image") || haystack.contains("vision") || haystack.contains("图") {
            kinds.append(.image)
        }
        if haystack.contains("video") || haystack.contains("视频") {
            kinds.append(.video)
        }
        if haystack.contains("llm") || haystack.contains("chat") || haystack.contains("text") {
            kinds.append(.text)
        }
        return kinds.isEmpty ? [.unknown] : kinds
    }

    private struct PricingResponse: Decodable {
        let items: [PricingItem]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let direct = try? container.decode([PricingItem].self, forKey: .items) {
                items = direct
                return
            }
            let wrapped = try? container.decode(DataWrapper.self, forKey: .data)
            items = wrapped?.items ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case items
            case data
        }

        private struct DataWrapper: Decodable {
            let items: [PricingItem]
        }
    }

    private struct PricingItem: Decodable {
        let model: String
        let capability_kinds: [String]?
        let generation_task_types: [String]?
        let input_modalities: [String]?
        let output_modalities: [String]?
        let catalog_tags: [String]?
        let is_hot: Bool?
        let is_new: Bool?

        var detectedKinds: [SomeIMGenerationKind] {
            detectKinds(model: model, words: [
                capability_kinds,
                generation_task_types,
                input_modalities,
                output_modalities,
                catalog_tags
            ].compactMap { $0 }.flatMap { $0 })
        }
    }

    private struct ImageGenerationResponse: Decodable {
        let data: [ImageDatum]

        struct ImageDatum: Decodable {
            let b64_json: String?
            let url: String?
        }
    }

    private struct APIEnvelope<T: Decodable>: Decodable {
        let data: T
    }

    private struct ClientLoginSendData: Decodable {
        let ok: Bool?
    }

    private struct ClientLoginVerifyData: Decodable {
        let api_key: String
        let default_model: String
        let token: String?
        let account: AccountData
    }

    private struct AccountData: Decodable {
        let email: String?
        let tenant_id: String?
        let balance_usd: String?
        let credits: String?
        let credits_per_usd: Int?
        let default_model: String?

        func account(fallbackEmail: String, fallbackModel: String) -> SomeIMAccount {
            let balance = balance_usd?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "0"
            return SomeIMAccount(
                email: email?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? fallbackEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                tenantID: tenant_id?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                balanceUSD: balance,
                credits: credits?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? SomeIMClient.credits(fromUSD: balance),
                creditsPerUSD: credits_per_usd ?? 100000,
                defaultModel: default_model?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? fallbackModel,
                lastUpdatedAt: Date()
            )
        }
    }

    private struct AccountBalanceData: Decodable {
        let tenant_id: String
        let currency: String
        let balance: String
    }

    private struct HandoffLinkData: Decodable {
        let login_url: String
        let expires_in: Int?
    }
}

struct SomeIMIntegrationSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var settings = SomeIMIntegrationStore.loadSettings()
    @State private var apiKey = SomeIMIntegrationStore.loadAPIKey()
    @State private var account = SomeIMIntegrationStore.loadAccount()
    @State private var accountEmail = SomeIMIntegrationStore.loadAccount()?.email ?? ""
    @State private var verificationCode = ""
    @State private var fetchedModels: [SomeIMModel] = []
    @State private var isFetching = false
    @State private var isSendingCode = false
    @State private var isVerifyingCode = false
    @State private var isRefreshingBalance = false
    @State private var status = ""

    private var imageModels: [SomeIMModel] {
        fetchedModels.filter(\.supportsImageGeneration)
    }

    private var videoModels: [SomeIMModel] {
        fetchedModels.filter(\.supportsVideoGeneration)
    }

    var body: some View {
        Form {
            Section(L10n.Settings.SomeIM.accountSection) {
                if let account {
                    LabeledContent(L10n.Settings.SomeIM.accountConnected) {
                        Text(L10n.Settings.SomeIM.accountSummary(account.email, account.displayCredits))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(L10n.Settings.SomeIM.defaultModelLabel) {
                        Text(account.defaultModel)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(isRefreshingBalance ? L10n.Settings.SomeIM.fetchingModels : L10n.Settings.SomeIM.refreshBalance) {
                            refreshBalance()
                        }
                        .disabled(isRefreshingBalance)
                        Button(L10n.Settings.SomeIM.openSomeIM) {
                            openSomeIM()
                        }
                    }
                } else {
                    Text(L10n.Settings.SomeIM.accountNotConnected)
                        .foregroundStyle(.secondary)
                }
                LabeledContent(L10n.Settings.SomeIM.emailLabel) {
                    TextField("", text: $accountEmail)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }
                LabeledContent(L10n.Settings.SomeIM.emailCodeLabel) {
                    TextField("", text: $verificationCode)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }
                HStack {
                    Button(isSendingCode ? L10n.Settings.SomeIM.sendingCode : L10n.Settings.SomeIM.sendCode) {
                        sendCode()
                    }
                    .disabled(isSendingCode || accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(isVerifyingCode ? L10n.Settings.SomeIM.verifyingCode : L10n.Settings.SomeIM.verifyCode) {
                        verifyCode()
                    }
                    .disabled(isVerifyingCode
                        || accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || verificationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section(L10n.Settings.SomeIM.connectionSection) {
                Toggle(L10n.Settings.SomeIM.enabledToggle, isOn: $settings.enabled)
                LabeledContent(L10n.Settings.SomeIM.regionLabel) {
                    Picker("", selection: relayRegionBinding) {
                        ForEach(SomeIMRelayRegion.allCases) { region in
                            Text(L10n.Settings.SomeIM.regionName(region)).tag(region)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                LabeledContent(L10n.Settings.SomeIM.baseURLLabel) {
                    TextField("", text: $settings.baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent(L10n.Settings.SomeIM.apiKeyLabel) {
                    RevealableSecretField(text: $apiKey, placeholder: "", onCommit: save)
                }
                HStack {
                    Button(L10n.Settings.buttonSave) { save() }
                    Button(isFetching ? L10n.Settings.SomeIM.fetchingModels : L10n.Settings.SomeIM.fetchModels) {
                        fetchModels()
                    }
                    .disabled(isFetching)
                    if !status.isEmpty {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(L10n.Settings.SomeIM.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Settings.SomeIM.imageSection) {
                modelPicker(
                    L10n.Settings.SomeIM.imageModelLabel,
                    selection: $settings.preferredImageModel,
                    candidates: imageModels,
                    fallbackModels: settings.preferredImageModels
                )
                TextField(L10n.Settings.SomeIM.priorityPlaceholder, text: priorityImageModelsBinding)
                    .textFieldStyle(.roundedBorder)
                Text(L10n.Settings.SomeIM.imageHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Settings.SomeIM.videoSection) {
                modelPicker(
                    L10n.Settings.SomeIM.videoModelLabel,
                    selection: $settings.preferredVideoModel,
                    candidates: videoModels,
                    fallbackModels: settings.preferredVideoModels
                )
                TextField(L10n.Settings.SomeIM.priorityPlaceholder, text: priorityVideoModelsBinding)
                    .textFieldStyle(.roundedBorder)
                Text(L10n.Settings.SomeIM.videoHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var relayRegionBinding: Binding<SomeIMRelayRegion> {
        Binding {
            SomeIMRelayRegion.resolved(for: settings.baseURL)
        } set: { region in
            if let baseURL = region.baseURL {
                settings.baseURL = baseURL
            }
        }
    }

    private func modelPicker(
        _ title: String,
        selection: Binding<String>,
        candidates: [SomeIMModel],
        fallbackModels: [String]
    ) -> some View {
        LabeledContent(title) {
            HStack {
                TextField("", text: selection)
                    .textFieldStyle(.roundedBorder)
                let ids = candidateIDs(candidates: candidates, fallbackModels: fallbackModels)
                if !ids.isEmpty {
                    Picker("", selection: selection) {
                        ForEach(ids, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
        }
    }

    private func candidateIDs(candidates: [SomeIMModel], fallbackModels: [String]) -> [String] {
        var seen = Set<String>()
        return (candidates.map(\.model) + fallbackModels)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private var priorityImageModelsBinding: Binding<String> {
        Binding {
            settings.preferredImageModels.joined(separator: ", ")
        } set: { value in
            settings.preferredImageModels = splitPriorityModels(value)
            if settings.preferredImageModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let first = settings.preferredImageModels.first {
                settings.preferredImageModel = first
            }
        }
    }

    private var priorityVideoModelsBinding: Binding<String> {
        Binding {
            settings.preferredVideoModels.joined(separator: ", ")
        } set: { value in
            settings.preferredVideoModels = splitPriorityModels(value)
            if settings.preferredVideoModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let first = settings.preferredVideoModels.first {
                settings.preferredVideoModel = first
            }
        }
    }

    private func splitPriorityModels(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func save() {
        let normalized = settings.normalized
        settings = normalized
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        SomeIMIntegrationStore.saveSettings(normalized)
        SomeIMIntegrationStore.saveAPIKey(trimmedKey)
        appState.syncSomeIMProvider(settings: normalized, apiKey: trimmedKey)
        status = L10n.Settings.savedStatus
    }

    private func sendCode() {
        isSendingCode = true
        status = ""
        let email = accountEmail
        let currentSettings = settings.normalized
        Task {
            let result: Result<Void, Error>
            do {
                try await SomeIMClient.sendClientLoginCode(email: email, settings: currentSettings)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                isSendingCode = false
                switch result {
                case .success:
                    status = L10n.Settings.SomeIM.codeSent
                case .failure(let error):
                    status = error.localizedDescription
                }
            }
        }
    }

    private func verifyCode() {
        isVerifyingCode = true
        status = ""
        let email = accountEmail
        let code = verificationCode
        let currentSettings = settings.normalized
        Task {
            let result: Result<SomeIMAccount, Error>
            do {
                result = .success(try await SomeIMClient.verifyClientLoginCode(email: email, code: code, settings: currentSettings))
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                isVerifyingCode = false
                switch result {
                case .success(let linked):
                    account = linked
                    accountEmail = linked.email
                    apiKey = SomeIMIntegrationStore.loadAPIKey()
                    settings = SomeIMIntegrationStore.loadSettings()
                    appState.syncSomeIMProvider(settings: settings, apiKey: apiKey)
                    appState.syncSomeIMImageUnderstanding(apiKey: apiKey)
                    status = L10n.Settings.SomeIM.connected
                case .failure(let error):
                    status = error.localizedDescription
                }
            }
        }
    }

    private func refreshBalance() {
        isRefreshingBalance = true
        status = ""
        Task {
            let result: Result<SomeIMAccount, Error>
            do {
                result = .success(try await SomeIMClient.fetchAccountBalance())
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                isRefreshingBalance = false
                switch result {
                case .success(let refreshed):
                    account = refreshed
                    status = L10n.Settings.savedStatus
                case .failure(let error):
                    status = error.localizedDescription
                }
            }
        }
    }

    private func openSomeIM() {
        Task {
            do {
                let url = try await SomeIMClient.fetchHandoffLoginURL()
                await MainActor.run {
                    _ = NSWorkspace.shared.open(url)
                }
            } catch {
                await MainActor.run {
                    status = error.localizedDescription
                }
            }
        }
    }

    private func fetchModels() {
        isFetching = true
        status = ""
        let currentSettings = settings.normalized
        let currentKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let result: Result<[SomeIMModel], Error>
            do {
                result = .success(try await SomeIMClient.fetchModels(settings: currentSettings, apiKey: currentKey))
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                isFetching = false
                switch result {
                case .success(let models):
                    fetchedModels = models
                    appState.recordFetchedAgentModelDiscoveries(models.map(\.agentDiscovery))
                    adoptFetchedDefaults(models)
                    status = L10n.Settings.SomeIM.fetchedModels("\(models.count)")
                case .failure(let error):
                    fetchedModels = []
                    status = error.localizedDescription
                }
            }
        }
    }

    private func adoptFetchedDefaults(_ models: [SomeIMModel]) {
        let imageIDs = models.filter(\.supportsImageGeneration).map(\.model)
        let videoIDs = models.filter(\.supportsVideoGeneration).map(\.model)
        if let gptImage = imageIDs.first(where: { $0 == SomeIMIntegrationSettings.defaultImageModel }) {
            settings.preferredImageModel = gptImage
        } else if settings.preferredImageModel.isEmpty, let first = imageIDs.first {
            settings.preferredImageModel = first
        }
        settings.preferredImageModels = mergePriority(primary: settings.preferredImageModel, existing: settings.preferredImageModels, fetched: imageIDs)
        if settings.preferredVideoModel.isEmpty, let first = videoIDs.first {
            settings.preferredVideoModel = first
        }
        settings.preferredVideoModels = mergePriority(primary: settings.preferredVideoModel, existing: settings.preferredVideoModels, fetched: videoIDs)
    }

    private func mergePriority(primary: String, existing: [String], fetched: [String]) -> [String] {
        var seen = Set<String>()
        return ([primary] + existing + fetched)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
