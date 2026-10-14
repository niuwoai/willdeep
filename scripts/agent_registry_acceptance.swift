import Foundation

/// Compiled with the application's actual package validator and HTTP transport.
@main struct AgentRegistryAcceptance {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else { fatalError("usage: runner operation golden.json") }
        let token = ProcessInfo.processInfo.environment["AGENT_ACCEPTANCE_TOKEN"] ?? ""
        let service = try AgentRegistryService(baseURL: "http://127.0.0.1:33317", token: token)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[2]))) as! [String: Any]
        let golden = try AgentPackageV1.decode(JSONSerialization.data(withJSONObject: (object["packages"] as! [[String: Any]])[0]))
        let identity = try await service.identity()
        let id = "user/mac-cross-client"
        var output: [String: Any] = ["operation": arguments[1], "identity_verified": !identity.user_id.isEmpty]
        switch arguments[1] {
        case "create":
            var definition = golden.definition
            definition.definition_id = id
            definition.name = ["en": "Mac cross-client reviewer", "zh-Hans": "跨端审查员"]
            let package = try AgentPackageV1.unsigned(definition)
            let item = try await service.upload(package, etag: nil)
            precondition(item.sha256 == package.sha256)
            output["revision"] = item.sha256
            output["version"] = item.version
        case "inspect":
            let list = try await service.list()
            let item = list.items.first { $0.definition_id == id }!
            output["revision"] = item.sha256
            output["version"] = item.version
            output["deleted"] = item.deleted
        case "conflict":
            let original = try await service.list().items.first { $0.definition_id == id }!
            var definition = original.package!.definition
            definition.version = "1.0.0-rc3"
            definition.instructions += "\nVerify the independently supplied example."
            let updated = try await service.upload(AgentPackageV1.unsigned(definition), etag: original.etag)
            definition.version = "1.0.0-rc4"
            definition.instructions += "\nStale edit must not replace current."
            do {
                _ = try await service.upload(AgentPackageV1.unsigned(definition), etag: original.etag)
                fatalError("stale update accepted")
            } catch AgentAssetError.conflict { output["stale_update_rejected"] = true }
            let current = try await service.list().items.first { $0.definition_id == id }!
            precondition(current.sha256 == updated.sha256)
            output["revision"] = current.sha256
        case "delete":
            let original = try await service.list().items.first { $0.definition_id == id }!
            let deleted = try await service.delete(id: id, etag: original.etag)
            precondition(deleted.deleted && deleted.package == nil)
            output["tombstone"] = true
        case "isolation":
            let list = try await service.list()
            precondition(list.items.allSatisfy { $0.definition_id != id })
            output["other_account_isolated"] = true
        case "official":
            let index = try await service.index()
            precondition(!index.items.isEmpty)
            let (package, keys) = try await service.official(index.items[0])
            try package.verify(keys: keys)
            precondition(package.sha256 == index.items[0].sha256)
            output["signed_official_revision"] = package.sha256
        default: fatalError("unknown acceptance operation")
        }
        output["ok"] = true
        print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
