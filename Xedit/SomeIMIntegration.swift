//
//  SomeIMIntegration.swift
//  WillDeep
//
//  Settings, model discovery, and generation helpers for Rocky's
//  some.im relay. The API key stays in Keychain; non-secret routing
//  preferences live in UserDefaults.
//

import Foundation
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
    private static let settingsKey = "com.willdeep.someIM.integrationSettings.v1"
    private static let apiKeyAccount = "some-im/api-key"

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

    static func loadAPIKey() -> String {
        AgentCredentialStore.load(account: apiKeyAccount)
    }

    static func saveAPIKey(_ apiKey: String) {
        AgentCredentialStore.save(apiKey, account: apiKeyAccount)
    }

    static var isConfigured: Bool {
        loadSettings().enabled && !loadAPIKey().isEmpty
    }
}

struct SomeIMGeneratedImage: Equatable, Sendable {
    let fileURL: URL
    let model: String
}

enum SomeIMClient {
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
}

struct SomeIMIntegrationSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var settings = SomeIMIntegrationStore.loadSettings()
    @State private var apiKey = SomeIMIntegrationStore.loadAPIKey()
    @State private var fetchedModels: [SomeIMModel] = []
    @State private var isFetching = false
    @State private var status = ""

    private var imageModels: [SomeIMModel] {
        fetchedModels.filter(\.supportsImageGeneration)
    }

    private var videoModels: [SomeIMModel] {
        fetchedModels.filter(\.supportsVideoGeneration)
    }

    var body: some View {
        Form {
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
                .disabled(true)
                TextField(L10n.Settings.SomeIM.priorityPlaceholder, text: priorityVideoModelsBinding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
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
