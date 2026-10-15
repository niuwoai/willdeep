import Foundation

nonisolated struct AgentRegistryIdentity: Codable, Equatable, Sendable {
    var user_id: String
    var tenant_id: String
    func account(origin: URL) -> String {
        AgentPackageV1.hash(Data((origin.absoluteString + "\n" + user_id + "\n" + tenant_id).utf8))
    }
}
nonisolated struct AgentRegistryItem: Codable, Equatable, Sendable {
    var definition_id: String
    var sha256: String
    var version: String
    var deleted: Bool
    var etag: String
    var package: AgentPackageV1?
}
nonisolated struct AgentRegistryIndex: Codable, Sendable {
    struct Item: Codable, Identifiable, Sendable {
        var definition_id: String
        var version: String
        var sha256: String
        var name: [String: String]
        var purpose: String
        var base_role: String
        var id: String { definition_id + ":" + sha256 }
    }
    var items: [Item]
}
nonisolated struct AgentRegistryList: Codable, Sendable { var items: [AgentRegistryItem]; var cursor: String }
nonisolated private struct AgentRegistryEnvelope<T: Decodable>: Decodable { let data: T }

/// A separate session never redirects bearer tokens or changes the trusted origin.
nonisolated final class AgentRegistryRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
nonisolated struct AgentRegistryService: Sendable {
    let origin: URL
    let token: String
    let session: URLSession
    /// Distribution and customer identity share the login control plane;
    /// the selected model relay may only expose inference routes.
    @MainActor static func controlPlane(token: String = "", session: URLSession? = nil) throws -> Self {
        try Self(baseURL: SomeIMClient.controlPlaneOrigin, token: token, session: session)
    }
    init(baseURL: String, token: String = "", session: URLSession? = nil) throws {
        guard var components = URLComponents(string: baseURL),
              components.user == nil, components.password == nil,
              let host = components.host, !host.isEmpty,
              components.scheme == "https" || (components.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else { throw AgentAssetError.server }
        components.path = ""; components.query = nil; components.fragment = nil
        guard let origin = components.url else { throw AgentAssetError.server }
        self.origin = origin; self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration, delegate: AgentRegistryRedirectPolicy(), delegateQueue: nil)
    }
    func request(_ route: String, method: String = "GET", id: String? = nil,
                 revision: String? = nil, body: Data? = nil, etag: String? = nil, encodedPath: Bool = false) async throws -> Data {
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        if encodedPath { components.percentEncodedPath = "/api/v1/" + route }
        else { components.path = "/api/v1/" + route }
        var query: [URLQueryItem] = []
        if let id { query.append(URLQueryItem(name: "definition_id", value: id)) }
        if let revision { query.append(URLQueryItem(name: "revision", value: revision)) }
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if route.hasPrefix("customer/") {
            guard !token.isEmpty else { throw AgentAssetError.authentication }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let identity = [origin.absoluteString, AgentPackageV1.hash(Data(token.utf8)), method, id ?? "",
                            etag ?? "create", AgentPackageV1.hash(body ?? Data())].joined(separator: "\n")
            request.setValue("agent-" + AgentPackageV1.hash(Data(identity.utf8)), forHTTPHeaderField: "Idempotency-Key")
            if let etag { request.setValue(etag, forHTTPHeaderField: "If-Match") }
            else { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentAssetError.server }
        if [409, 412].contains(http.statusCode) { throw AgentAssetError.conflict }
        if [401, 403].contains(http.statusCode) { throw AgentAssetError.authentication }
        guard (200...299).contains(http.statusCode), data.count <= 40 * 1024 * 1024 else { throw AgentAssetError.server }
        return data
    }
    func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        let value = try businessValue(data)
        return try JSONDecoder().decode(T.self, from: value.bytes)
    }
    func businessValue(_ data: Data) throws -> AgentCanonicalJSON {
        var parser = AgentCanonicalJSON.Parser(data: data, allowNumbers: true)
        guard case .object(let envelope) = try parser.parse(), let value = envelope["data"] else { throw AgentAssetError.server }
        return value
    }
    func identity() async throws -> AgentRegistryIdentity {
        try decode(AgentRegistryIdentity.self, data: await request("customer/agent-identity"))
    }
    func index() async throws -> AgentRegistryIndex {
        try decode(AgentRegistryIndex.self, data: await request("public/agents/index"))
    }
    func official(_ item: AgentRegistryIndex.Item) async throws -> (AgentPackageV1, [String: String]) {
        struct Keys: Decodable { var keys: [String: String] }
        let keys = try decode(Keys.self, data: await request("public/agents/keys")).keys
        let data = try await request("public/agents/package", id: item.definition_id, revision: item.sha256)
        let package = try AgentPackageV1.decode(businessValue(data).bytes)
        guard package.sha256 == item.sha256, package.definition.definition_id == item.definition_id,
              package.definition.version == item.version else { throw AgentAssetError.invalidHash }
        try package.verify(keys: keys)
        return (package, keys)
    }
    func list() async throws -> AgentRegistryList {
        let data = try await request("customer/agents")
        let value = try businessValue(data)
        if case .object(let fields) = value, case .array(let items) = fields["items"] {
            for item in items {
                if case .object(let fields) = item, let package = fields["package"], package != .null {
                    _ = try AgentPackageV1.decode(package.bytes)
                }
            }
        }
        let list = try JSONDecoder().decode(AgentRegistryList.self, from: value.bytes)
        guard list.items.count <= 128, Set(list.items.map(\.definition_id)).count == list.items.count else { throw AgentAssetError.server }
        for item in list.items { try validate(item) }
        return list
    }
    func validate(_ item: AgentRegistryItem) throws {
        guard item.definition_id.hasPrefix("user/"), !item.etag.isEmpty, AgentPackageV1.isHash(item.sha256) else { throw AgentAssetError.server }
        if item.deleted { guard item.package == nil else { throw AgentAssetError.server }; return }
        guard let package = item.package, package.signature == nil else { throw AgentAssetError.server }
        let validated = try AgentPackageV1.decode(package.encoded())
        guard validated.sha256 == item.sha256, validated.definition.definition_id == item.definition_id,
              validated.definition.version == item.version else { throw AgentAssetError.invalidHash }
    }
    func upload(_ package: AgentPackageV1, etag: String?) async throws -> AgentRegistryItem {
        let data = try await request("customer/agents", method: "PUT", id: package.definition.definition_id,
                                     body: package.encoded(), etag: etag)
        let item = try decodeItem(data)
        guard item.definition_id == package.definition.definition_id, item.sha256 == package.sha256,
              item.version == package.definition.version, !item.deleted else { throw AgentAssetError.server }
        return item
    }
    func delete(id: String, etag: String) async throws -> AgentRegistryItem {
        let data = try await request("customer/agents", method: "DELETE", id: id, etag: etag)
        let item = try decodeItem(data)
        guard item.definition_id == id, item.deleted else { throw AgentAssetError.server }
        return item
    }
    func decodeItem(_ data: Data) throws -> AgentRegistryItem {
        let value = try businessValue(data)
        if case .object(let fields) = value, let package = fields["package"], package != .null {
            _ = try AgentPackageV1.decode(package.bytes)
        }
        let item = try JSONDecoder().decode(AgentRegistryItem.self, from: value.bytes)
        try validate(item); return item
    }
}
