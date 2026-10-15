import Foundation
import Testing
@testable import WillDeep

/// Real localhost HTTP plus the independently built Rust CLI. This does not
/// claim GUI account switching or production-account verification.
@Suite(.serialized) @MainActor struct AgentRegistryCrossClientTests {
    private var repository: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private enum Failure: Error { case check(String), process(String, Int32), timeout }

    @Test func realClientsResolveBothDirectionsAndKeepAccountsSeparate() async throws {
        let configuration = repository.appendingPathComponent("build/rsi-service-acceptance.json")
        guard FileManager.default.fileExists(atPath: configuration.path) else { return }
        let config = try AgentRSIContract.raw(Data(contentsOf: configuration))
        guard let binaryPath = config["registry_binary"].text else { return }
        let receiptPath = try #require(config["receipt_path"].text)
        let receipt = try AgentRSIContract.raw(Data(contentsOf: URL(fileURLWithPath: receiptPath)))
        let origin = try #require(receipt["origin"].text)
        let url = try #require(URL(string: origin))
        try require(receipt["mock_only"] == .bool(true) && url.scheme == "http"
                    && ["127.0.0.1", "localhost"].contains(url.host ?? ""), "isolated mock fixture only")
        let binary = URL(fileURLWithPath: binaryPath)
        let binarySHA = try AgentPackageV1.hash(Data(contentsOf: binary))
        let directory = repository.appendingPathComponent("build/rsi-registry-interop/" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let home = directory.appendingPathComponent("rust-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let suite = "willdeep-rsi-interop-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = AgentDefinitionLibrary(root: directory.appendingPathComponent("mac-library"), defaults: defaults)
        let token = try #require(receipt["tokens"]["a"].text)
        let service = try AgentRegistryService(baseURL: origin, token: token)
        let identity = try await service.identity()
        try writeSession(identity: identity, origin: origin, token: token, home: home)
        let account = identity.account(origin: service.origin)
        let id = "user/rsi-sync-" + UUID().uuidString.lowercased()
        let first = try package(id: id, version: 1, instructions: "Read-only initial fixture.")
        var checks: [String] = []
        let cli = Client(binary: binary, home: home, directory: directory)
        try await cli.install(first)
        _ = try await cli.call(["share", id]); _ = try await cli.call(["sync"])
        _ = try await AgentRegistrySync(library: library, service: service).synchronize()
        try require(try installation(library, id: id, account: account).selected == first.sha256, "Rust to Mac initial download")
        checks.append("Rust upload / Mac native download")

        // Each side resolves both choices. The other side retains an independent
        // dirty revision before the winner is published, so this is a conflict,
        // rather than two successive uncontested writes.
        for round in 0..<4 {
            let version = round * 2 + 2
            let rust = try package(id: id, version: version, instructions: "Read-only Rust edit \(round).")
            let mac = try package(id: id, version: version, instructions: "Read-only Mac edit \(round).")
            try await cli.install(rust)
            _ = try library.install(mac, source: .private, account: account)
            if round == 0 || round == 3 {
                _ = try await cli.call(["sync"])
                _ = try await AgentRegistrySync(library: library, service: service).synchronize()
                let conflict = try installation(library, id: id, account: account)
                try require(conflict.selected == mac.sha256 && conflict.conflict?.sha256 == rust.sha256, "Mac conflict preserves both revisions")
                try require(try library.package(revision: conflict.selected, account: account).sha256 == mac.sha256, "Mac local package preserved")
                let keep = round == 0
                if keep { try library.resolve(conflict, keepLocal: true, newVersion: "1.0.0-rc\(version + 1)") }
                else { try library.resolve(conflict, keepLocal: false) }
                _ = try await AgentRegistrySync(library: library, service: service).synchronize()
                _ = try await cli.call(["sync"])
                let expected = keep ? try package(id: id, version: version + 1, instructions: mac.definition.instructions).sha256 : rust.sha256
                try await assertConverged(expected, id: id, library: library, account: account, cli: cli)
                checks.append(keep ? "Mac keep-local CAS / Rust receive" : "Mac use-cloud / Rust unchanged")
            } else {
                _ = try await AgentRegistrySync(library: library, service: service).synchronize()
                let response = try await cli.call(["sync"])
                let detail = try #require(response["conflict_details"].elements.first { $0["definition_id"].text == id })
                try require(detail["expected_local_revision"].text == rust.sha256 && detail["remote_revision"].text == mac.sha256,
                            "Rust conflict preserves both revisions")
                let keep = round == 2
                var arguments = ["resolve", id, "--choice", keep ? "keep-local" : "use-cloud",
                    "--expected-local-revision", rust.sha256,
                    "--expected-remote-etag", try #require(detail["expected_remote_etag"].text)]
                if keep { arguments += ["--new-version", "1.0.0-rc\(version + 1)"] }
                _ = try await cli.call(arguments)
                _ = try await AgentRegistrySync(library: library, service: service).synchronize()
                let expected = keep ? try package(id: id, version: version + 1, instructions: rust.definition.instructions).sha256 : mac.sha256
                try await assertConverged(expected, id: id, library: library, account: account, cli: cli)
                checks.append(keep ? "Rust keep-local CAS / Mac receive" : "Rust use-cloud / Mac unchanged")
            }
        }
        // Pin/rollback is another actual HTTP conflict, not a permission to
        // replace the running snapshot or silently upload an old revision.
        let latest = try installation(library, id: id, account: account)
        try library.select(first.sha256, installation: latest)
        let afterPin = try package(id: id, version: 10, instructions: "Read-only cloud update after native pin.")
        try await cli.install(afterPin); _ = try await cli.call(["sync"])
        _ = try await AgentRegistrySync(library: library, service: service).synchronize()
        let rolledBack = try installation(library, id: id, account: account)
        try require(rolledBack.selected == first.sha256 && rolledBack.pinned == true && rolledBack.conflict != nil, "pinned rollback retains cloud conflict")
        try library.resolve(rolledBack, keepLocal: false)
        var unpinned = try installation(library, id: id, account: account)
        unpinned.pinned = false; try library.update(unpinned)
        checks.append("Mac pinned historical rollback does not silently replace cloud")

        // Same storage, different authenticated customers and tenants. Local
        // public definitions intentionally remain local; private scope must not.
        for key in ["other_user", "other_tenant"] {
            let otherToken = try #require(receipt["tokens"][key].text)
            let other = try AgentRegistryService(baseURL: origin, token: otherToken)
            let otherIdentity = try await other.identity()
            _ = try await AgentRegistrySync(library: library, service: other).synchronize()
            try require(!(try library.visibleInstallations()).contains { $0.definitionID == id }, "Mac private account isolation")
            let remote = try await other.list()
            try require(!remote.items.contains { $0.definition_id == id }, "server private account isolation")
            try writeSession(identity: otherIdentity, origin: origin, token: otherToken, home: home)
            let list = try await cli.call(["list"])
            try require(!list["items"].elements.contains { $0["scope"].text == "private" && $0["package"]["definition"]["definition_id"].text == id }, "Rust private account isolation")
            checks.append("Cross-client private isolation: " + key)
        }
        try writeSession(identity: identity, origin: origin, token: token, home: home)
        _ = try await AgentRegistrySync(library: library, service: service).synchronize()
        let restored = try installation(library, id: id, account: account)
        try require(library.activeAccount == account && restored.conflict == nil, "account restoration retains revision")
        let active = library.activeAccount
        do {
            _ = try await AgentRegistrySync(library: library, service: service, sessionStillCurrent: { false }).synchronize()
            throw Failure.check("switched session accepted")
        } catch AgentAssetError.authentication { }
        try require(library.activeAccount == active, "stale session does not activate data")
        checks.append("Restore customer and reject stale in-flight session")

        // Remove only this freshly generated synthetic asset, then prove its
        // cloud tombstone is consumed by the other client and stays deleted.
        _ = try await cli.call(["delete", id]); _ = try await cli.call(["sync"])
        _ = try await AgentRegistrySync(library: library, service: service).synchronize()
        try require(try installation(library, id: id, account: account).deleted, "native receives Rust tombstone")
        _ = try await AgentRegistrySync(library: library, service: service).synchronize()
        try require(try installation(library, id: id, account: account).deleted, "idempotent sync does not resurrect tombstone")
        checks.append("Rust delete / Mac tombstone / idempotent no resurrection")
        try require(try AgentPackageV1.hash(Data(contentsOf: binary)) == binarySHA, "frozen Rust binary")
        let report = AgentCanonicalJSON.object(["schema": .string("willdeep.agent-registry.cross-client-acceptance.v1"),
            "passed": .bool(true), "scope": .string("real_clients_isolated_http_synthetic_accounts_no_gui"),
            "paid_provider_requests": .integer(0), "definition_id": .string(id), "rust_binary_sha256": .string(binarySHA),
            "checks": .array(checks.map(AgentCanonicalJSON.string))])
        try report.bytes.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        let markdown = "# 双端注册表隔离验收\n\n通过：true\n\n真实 Mac 服务层与 Rust CLI / localhost HTTP / 合成账号；未操作 GUI 或生产账号。付费模型请求：0。\n\n" + checks.map { "- " + $0 }.joined(separator: "\n") + "\n"
        try Data(markdown.utf8).write(to: directory.appendingPathComponent("report.md"), options: .atomic)
    }

    private func require(_ condition: @autoclosure () throws -> Bool, _ stage: String) throws {
        guard try condition() else { throw Failure.check(stage) }
    }
    private func installation(_ library: AgentDefinitionLibrary, id: String, account: String) throws -> AgentDefinitionLibrary.Installation {
        try #require(library.state().installations.first { $0.definitionID == id && $0.account == account })
    }
    private func package(id: String, version: Int, instructions: String) throws -> AgentPackageV1 {
        try .unsigned(.init(schema: AgentDefinitionV1.schemaID, definition_id: id, version: "1.0.0-rc\(version)",
            name: ["en": "Synthetic RSI sync"], purpose: "Read-only isolated sync acceptance", base_role: "reviewer",
            instructions: instructions, input_modalities: ["text"], tools: ["workspace.read"], skills: [], forked_from: nil))
    }
    private func writeSession(identity: AgentRegistryIdentity, origin: String, token: String, home: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: ["origin": origin, "token": token,
            "user_id": identity.user_id, "tenant_id": identity.tenant_id])
        try data.write(to: home.appendingPathComponent("agent-session.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.appendingPathComponent("agent-session.json").path)
    }
    private func assertConverged(_ sha: String, id: String, library: AgentDefinitionLibrary, account: String, cli: Client) async throws {
        let mac = try installation(library, id: id, account: account)
        try require(mac.selected == sha && mac.conflict == nil && !mac.dirty, "native resolved head")
        let file = cli.directory.appendingPathComponent("export-" + UUID().uuidString + ".json")
        _ = try await cli.call(["export", id, file.path])
        try require(try AgentPackageV1.decode(Data(contentsOf: file)).sha256 == sha, "Rust resolved head")
    }

    private nonisolated struct Client: Sendable {
        let binary: URL
        let home: URL
        let directory: URL
        func install(_ package: AgentPackageV1) async throws {
            let file = directory.appendingPathComponent("import-" + package.sha256 + ".json")
            try package.encoded().write(to: file, options: .atomic)
            _ = try await call(["import", file.path])
        }
        func call(_ arguments: [String]) async throws -> AgentCanonicalJSON {
            try await Task.detached {
                let process = Process()
                process.executableURL = binary; process.arguments = ["agents"] + arguments
                process.currentDirectoryURL = directory
                var environment = ProcessInfo.processInfo.environment
                for key in ["WILLDEEP_CONFIG", "WILLDEEP_API_KEY", "WILLDEEP_MODEL", "OPENAI_API_KEY", "ANTHROPIC_API_KEY"] { environment.removeValue(forKey: key) }
                environment["WILLDEEP_HOME"] = home.path; environment["WILLDEEP_TELEMETRY_DISABLED"] = "1"
                process.environment = environment
                let output = directory.appendingPathComponent(".cli-" + UUID().uuidString)
                FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let handle = try FileHandle(forWritingTo: output)
                defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
                process.standardOutput = handle; process.standardError = FileHandle.nullDevice
                try process.run()
                let deadline = Date().addingTimeInterval(45)
                while process.isRunning {
                    if Date() >= deadline || Task.isCancelled { process.terminate(); throw Failure.timeout }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard process.terminationStatus == 0 else { throw Failure.process(arguments.first ?? "unknown", process.terminationStatus) }
                try handle.synchronize()
                return try AgentRSIContract.raw(Data(contentsOf: output))
            }.value
        }
    }
}
