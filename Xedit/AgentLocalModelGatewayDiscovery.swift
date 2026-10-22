//
//  AgentLocalModelGatewayDiscovery.swift
//  WillDeep
//
//  Finds well-known model gateways bound to this Mac. Probes are limited to
//  loopback addresses and use the shared proxy-free local session.
//

import Foundation

struct AgentDiscoveredLocalModelGateway: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let baseURL: String
    let apiKey: String
    let modelIDs: [String]
    let isMagpie: Bool

    var modelSummary: String {
        modelIDs.isEmpty ? "" : modelIDs.prefix(3).joined(separator: ", ")
    }
}

enum AgentLocalModelGatewayDiscovery {
    private struct Candidate: Sendable {
        let id: String
        let displayName: String
        let baseURL: String
        let port: Int
        let isMagpie: Bool
    }

    private static let magpieKey = "magpie-willdeep"
    private static let genericKey = "local-gateway"
    private static let standardCandidates: [Candidate] = [
        Candidate(id: "magpie", displayName: "Magpie", baseURL: "http://127.0.0.1:3425/v1", port: 3425, isMagpie: true),
        Candidate(id: "lm-studio", displayName: "LM Studio", baseURL: "http://127.0.0.1:1234/v1", port: 1234, isMagpie: false),
        Candidate(id: "jan", displayName: "Jan", baseURL: "http://127.0.0.1:1337/v1", port: 1337, isMagpie: false),
        Candidate(id: "localai", displayName: "LocalAI", baseURL: "http://127.0.0.1:8080/v1", port: 8080, isMagpie: false),
        Candidate(id: "vllm", displayName: "vLLM", baseURL: "http://127.0.0.1:8000/v1", port: 8000, isMagpie: false),
        Candidate(id: "litellm", displayName: "LiteLLM", baseURL: "http://127.0.0.1:4000/v1", port: 4000, isMagpie: false),
        Candidate(id: "ollama", displayName: "Ollama", baseURL: "http://127.0.0.1:11434/v1", port: 11434, isMagpie: false),
    ]

    static func discover() async -> [AgentDiscoveredLocalModelGateway] {
        let session = AgentNetworkSupport.loopbackSession(requestTimeout: 0.45, resourceTimeout: 1.0)
        defer { session.invalidateAndCancel() }
        var discovered: [AgentDiscoveredLocalModelGateway] = []

        for candidate in candidatesIncludingConfiguredMagpiePort() {
            if candidate.isMagpie,
               let magpie = await discoverMagpie(candidate, session: session) {
                discovered.append(magpie)
                continue
            }
            if let gateway = await discoverOpenAICompatible(candidate, session: session) {
                discovered.append(gateway)
            }
        }

        return discovered
    }

    private static func candidatesIncludingConfiguredMagpiePort() -> [Candidate] {
        guard let port = configuredMagpiePort(), port != 3425 else { return standardCandidates }
        let magpie = Candidate(
            id: "magpie-\(port)",
            displayName: "Magpie",
            baseURL: "http://127.0.0.1:\(port)/v1",
            port: port,
            isMagpie: true
        )
        return [magpie] + standardCandidates
    }

    private static func configuredMagpiePort() -> Int? {
        let fileManager = FileManager.default
        let configRoot = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        let settingsURL = configRoot.appendingPathComponent("magpie/settings.json", isDirectory: false)
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = settings["port"] as? Int,
              (1...65_535).contains(port) else { return nil }
        return port
    }

    private static func discoverMagpie(
        _ candidate: Candidate,
        session: URLSession
    ) async -> AgentDiscoveredLocalModelGateway? {
        guard let helloURL = URL(string: "http://127.0.0.1:\(candidate.port)/api/hello") else { return nil }
        var helloRequest = URLRequest(url: helloURL)
        helloRequest.httpMethod = "GET"
        AgentNetworkSupport.applyStandardHeaders(to: &helloRequest)

        do {
            let (data, response) = try await session.data(for: helloRequest)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["name"] as? String == "magpie" else { return nil }
            let models = await fetchModels(
                from: candidate.baseURL,
                apiKey: magpieKey,
                session: session
            ) ?? []
            return AgentDiscoveredLocalModelGateway(
                id: candidate.id,
                displayName: candidate.displayName,
                baseURL: candidate.baseURL,
                apiKey: magpieKey,
                modelIDs: models,
                isMagpie: true
            )
        } catch {
            // A closed or restarting local port is an ordinary discovery miss.
            return nil
        }
    }

    private static func discoverOpenAICompatible(
        _ candidate: Candidate,
        session: URLSession
    ) async -> AgentDiscoveredLocalModelGateway? {
        guard let models = await fetchModels(from: candidate.baseURL, apiKey: nil, session: session) else {
            return nil
        }
        return AgentDiscoveredLocalModelGateway(
            id: candidate.id,
            displayName: candidate.displayName,
            baseURL: candidate.baseURL,
            apiKey: genericKey,
            modelIDs: models,
            isMagpie: false
        )
    }

    private static func fetchModels(
        from baseURL: String,
        apiKey: String?,
        session: URLSession
    ) async -> [String]? {
        guard let url = try? AgentNetworkSupport.endpoint(from: baseURL, suffix: "models") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object["data"] as? [[String: Any]] else { return nil }
            let models = rows.compactMap { row in
                (row["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            return models.isEmpty ? nil : models
        } catch {
            // Probing unreachable loopback ports is expected during discovery.
            return nil
        }
    }
}
