import Foundation
import CryptoKit
import SwiftUI
import AppKit
import Testing
@testable import WillDeep

@Suite(.serialized) @MainActor struct AgentDefinitionRegistryTests {
    func definition(id: String = "user/reviewer") -> AgentDefinitionV1 {
        AgentDefinitionV1(schema: AgentDefinitionV1.schemaID, definition_id: id, version: "1.0.0-rc1",
            name: ["en": "Reviewer", "zh-Hans": "审查员"], purpose: "Review defects.", base_role: "reviewer",
            instructions: "Find reproducible defects.", input_modalities: ["text"], tools: ["workspace.read", "repository.inspect"],
            skills: [], forked_from: nil)
    }
    func sandbox() throws -> (AgentDefinitionLibrary, URL, UserDefaults, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "willdeep-profiles-registry-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        return (AgentDefinitionLibrary(root: root, defaults: defaults), root, defaults, name)
    }
    func itemEnvelope(_ item: AgentRegistryItem) throws -> Data {
        let encoded = try JSONEncoder().encode(item)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        if let package = item.package { object["package"] = try JSONSerialization.jsonObject(with: package.encoded()) }
        else { object["package"] = NSNull() }
        return try JSONSerialization.data(withJSONObject: ["code": 0, "data": object])
    }
    func listEnvelope(_ items: [AgentRegistryItem]) throws -> Data {
        let values = try items.map { item in
            let encoded = try itemEnvelope(item)
            let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            return try #require(object?["data"])
        }
        return try JSONSerialization.data(withJSONObject: ["data": ["items": values, "cursor": "fixture"]])
    }
    @Test func strictJSONRejectsDuplicateUnknownAndNumbers() throws {
        let package = try AgentPackageV1.unsigned(definition())
        let encoded = String(decoding: try package.encoded(), as: UTF8.self)
        #expect(throws: (any Error).self) { try AgentPackageV1.decode(Data(encoded.replacingOccurrences(of: "\"signature\":null", with: "\"signature\":null,\"signature\":null").utf8)) }
        #expect(throws: (any Error).self) { try AgentPackageV1.decode(Data(encoded.replacingOccurrences(of: "\"signature\":null", with: "\"signature\":null,\"extra\":null").utf8)) }
        #expect(throws: (any Error).self) { try AgentPackageV1.fromDefinitionData(Data("{\"maxRounds\":99}".utf8)) }
        #expect(throws: (any Error).self) { try AgentPackageV1.decode(Data(encoded.replacingOccurrences(of: "Find reproducible defects.", with: "different").utf8)) }
        var credentialDefinition = definition(); credentialDefinition.instructions = "sk-" + String(repeating: "x", count: 24)
        #expect(throws: (any Error).self) { try AgentPackageV1.unsigned(credentialDefinition) }
    }
    @Test func officialSignatureCannotBeSelfTrusted() throws {
        let key = Curve25519.Signing.PrivateKey()
        var package = try AgentPackageV1.unsigned(definition(id: "official/reviewer"))
        package.signature = .init(key_id: "test", value: try key.signature(for: Data(("willdeep.agent-package.v1\n" + package.sha256).utf8)).map { String(format: "%02x", $0) }.joined())
        #expect(throws: (any Error).self) { try package.verify(keys: [:]) }
        let keys = ["test": key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()]
        try package.verify(keys: keys)
        package.sha256 = String(repeating: "0", count: 64)
        #expect(throws: (any Error).self) { try package.verify(keys: keys) }
    }
    @Test func incompatibleOfficialCandidateAndTrustConflictCannotReplaceInstalledEnvelope() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicHex = key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        func signed(_ definition: AgentDefinitionV1, key: Curve25519.Signing.PrivateKey) throws -> AgentPackageV1 {
            var package = try AgentPackageV1.unsigned(definition)
            package.signature = .init(key_id: "test", value: try key.signature(for: Data(("willdeep.agent-package.v1\n" + package.sha256).utf8)).map { String(format: "%02x", $0) }.joined())
            return package
        }
        for pinned in [false, true] {
            let (library, root, defaults, suite) = try sandbox()
            defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
            let first = try signed(definition(id: "official/reviewer"), key: key)
            var installation = try library.install(first, source: .official, keys: ["test": publicHex])
            installation.enabled = false; installation.pinned = pinned
            installation.binding.model = "fixture-model"; try library.update(installation)
            var imageDefinition = first.definition; imageDefinition.version = "1.0.0-rc2"; imageDefinition.input_modalities = ["text", "image"]
            let candidate = try signed(imageDefinition, key: key)
            #expect(throws: (any Error).self) { try library.install(candidate, source: .official, keys: ["test": publicHex]) }
            #expect(try library.state().installations.first == installation)
            #expect(throws: (any Error).self) { try library.package(revision: candidate.sha256) }
            let replacementKey = Curve25519.Signing.PrivateKey()
            let replacement = try signed(first.definition, key: replacementKey)
            let replacementPublic = replacementKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
            #expect(throws: (any Error).self) { try library.install(replacement, source: .official, keys: ["test": replacementPublic]) }
            #expect(try library.package(revision: first.sha256) == first)
            #expect(try library.state().installations.first == installation)
        }
    }
    @Test func revisionsRollbackAndRunSnapshotRemainImmutable() throws {
        let (library, root, defaults, suite) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let first = try AgentPackageV1.unsigned(definition())
        var installation = try library.install(first, source: .local)
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        #expect(directoryPermissions?.intValue == 0o700)
        let statePermissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("installations.json").path)[.posixPermissions] as? NSNumber
        #expect(statePermissions?.intValue == 0o600)
        let running = try #require(library.profiles().first?.asSubagentProfile())
        var secondDefinition = first.definition; secondDefinition.instructions = "Updated instructions."
        #expect(throws: (any Error).self) { try library.install(.unsigned(secondDefinition), source: .local) }
        secondDefinition.version = "1.0.0-rc2"
        installation = try library.install(.unsigned(secondDefinition), source: .local)
        #expect(running.registrySnapshot?.revision == first.sha256)
        #expect(running.capabilityPromptSection.contains("Find reproducible defects."))
        try library.select(first.sha256, installation: installation)
        #expect(try library.profiles().first?.registrySnapshot?.revision == first.sha256)
        var disabled = try #require(library.visibleInstallations().first); disabled.enabled = false; try library.update(disabled)
        #expect(try library.profiles().isEmpty)
        _ = try library.install(.unsigned(secondDefinition), source: .local)
        #expect(try library.profiles().isEmpty)
        #expect(try library.visibleInstallations().first?.pinned == true)
    }
    @Test func exactRoleProjectionAndLockedSkillBody() throws {
        var definition = definition(); definition.base_role = "implementer"; definition.tools.append("workspace.edit")
        let body = String(repeating: "Locked skill body\n", count: 1000)
        definition.skills = [.init(id: "project-rules", content: body, sha256: AgentPackageV1.hash(Data(body.utf8)), required: true)]
        let package = try AgentPackageV1.unsigned(definition)
        let projected = try AgentDefinitionLibrary.project(package, binding: .inheritsParent)
        let worker = try #require(projected.asSubagentProfile())
        #expect(projected.origin == .managed)
        #expect(worker.id == "user/reviewer")
        #expect(worker.permissionRoleID == "implementer")
        #expect(worker.requiresWriteAccess)
        #expect(!worker.effectiveToolNames().contains("apply_patch"))
        #expect(worker.effectiveToolNames(writeAccessGranted: true).contains("apply_patch"))
        #expect(!worker.effectiveToolNames(writeAccessGranted: true).contains("call_mcp_tool"))
        let prompt = AgentSubagentRunner.systemPrompt(workspaceURL: nil, profile: worker)
        #expect(prompt.contains(body))
        #expect(prompt.contains(package.sha256))
        let reviewerRole = AgentGoalTeamRole(id: "reviewer", boundProfileIDs: [projected.id], toolPolicy: .readOnly,
            lockedScope: "", doneCriteria: "Review only", validatorRoleID: "owner", memoryFileName: nil)
        let narrowed = try #require(reviewerRole.resolvedTrade(profiles: [projected]))
        #expect(!narrowed.toolNames.contains("apply_patch"))
        #expect(!narrowed.toolNames.contains("run_command"))
        definition.input_modalities = ["text", "image"]
        #expect(throws: (any Error).self) { try AgentDefinitionLibrary.project(.unsigned(definition), binding: .inheritsParent) }
        definition.input_modalities = ["text"]; definition.base_role = "reviewer"
        definition.tools.append("process.verify")
        let readOnly = try #require(AgentDefinitionLibrary.project(.unsigned(definition), binding: .inheritsParent).asSubagentProfile())
        #expect(!readOnly.effectiveToolNames(writeAccessGranted: true).contains("apply_patch"))
        #expect(!readOnly.effectiveToolNames().contains("run_command"))
        definition.tools = []
        #expect(throws: (any Error).self) { try AgentDefinitionLibrary.project(.unsigned(definition), binding: .inheritsParent) }
    }
    @Test func accountIsolationAndConflictsPreserveBothRevisions() throws {
        let (library, root, defaults, suite) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let first = try AgentPackageV1.unsigned(definition())
        var local = try library.install(first, source: .private, account: "account-a")
        #expect(try library.profiles().isEmpty)
        library.activate(account: "account-a")
        #expect(try library.profiles().count == 1)
        var remoteDefinition = first.definition; remoteDefinition.version = "1.0.0-rc2"; remoteDefinition.instructions = "Remote change."
        let remote = try AgentPackageV1.unsigned(remoteDefinition)
        local.conflict = .init(definition_id: remote.definition.definition_id, sha256: remote.sha256, version: remote.definition.version,
            deleted: false, etag: "new-etag", package: remote)
        try library.update(local)
        try library.resolve(local, keepLocal: false)
        let resolved = try #require(library.visibleInstallations().first)
        #expect(resolved.selected == remote.sha256)
        #expect(try library.package(revision: first.sha256, account: "account-a") == first)
        library.activate(account: "account-b")
        #expect(try library.profiles().isEmpty)
        library.activate(account: nil)
        #expect(try library.visibleInstallations().isEmpty)
    }
    @Test func sharingPreservesLocalModelBindingWithoutExportingIt() throws {
        let (library, root, defaults, suite) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let package = try AgentPackageV1.unsigned(definition())
        var local = try library.install(package, source: .local)
        let binding = AgentSubagentProfile.ModelBinding(preferredProviderEntryID: UUID(), preferredProviderID: "fixture-provider",
            model: "local-fixture-model", contextWindowTokens: 32000)
        local.binding = binding; local.pinned = true; try library.update(local)
        var shared = try library.share(local, account: "account-a")
        #expect(shared.binding == binding)
        #expect(shared.pinned == true)
        library.activate(account: "account-a")
        #expect(try library.profiles().first?.asSubagentProfile()?.modelBinding == binding)
        let exported = try library.package(revision: shared.selected, account: shared.account)
        #expect(exported == package)
        let json = String(decoding: try exported.encoded(), as: UTF8.self)
        #expect(!json.contains("local-fixture-model"))
        #expect(!json.contains("fixture-provider"))
        #expect(!json.contains("binding"))
        #expect(!json.contains(binding.preferredProviderEntryID!.uuidString))
        let accountBinding = AgentSubagentProfile.ModelBinding(preferredProviderID: "account-provider", model: "account-model", contextWindowTokens: 64000)
        shared.binding = accountBinding; shared.enabled = false; try library.update(shared)
        let repeated = try library.share(local, account: "account-a")
        #expect(repeated.binding == accountBinding)
        #expect(!repeated.enabled)
    }
    @Test func unsupportedImageInstallationDoesNotHideHealthyTextWorkers() throws {
        let (library, root, defaults, suite) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        _ = try library.install(.unsigned(definition()), source: .local)
        var image = definition(id: "user/image-reviewer"); image.input_modalities = ["text", "image"]
        _ = try library.install(.unsigned(image), source: .local)
        #expect(try library.visibleInstallations().first(where: { $0.definitionID == image.definition_id })?.enabled == false)
        #expect(try library.visibleInstallations().count == 2)
        #expect(try library.profiles().map(\.id) == ["user/reviewer"])
    }
    @Test func deletedConflictResolutionProducesTombstone() throws {
        let (library, root, defaults, suite) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let package = try AgentPackageV1.unsigned(definition())
        var installation = try library.install(package, source: .private, account: "account-a")
        installation.conflict = .init(definition_id: package.definition.definition_id, sha256: package.sha256,
            version: package.definition.version, deleted: true, etag: "deleted-etag", package: nil)
        try library.update(installation); try library.resolve(installation, keepLocal: false)
        let deleted = try #require(library.state().installations.first)
        #expect(deleted.deleted && !deleted.enabled && !deleted.dirty)
        #expect(deleted.etag == "deleted-etag")
        #expect(try library.package(revision: package.sha256, account: "account-a") == package)
    }
    @Test func remoteOriginMustBeSecureAndContainsNoCredentials() throws {
        #expect(throws: (any Error).self) { try AgentRegistryService(baseURL: "http://some.im") }
        #expect(throws: (any Error).self) { try AgentRegistryService(baseURL: "https://user:secret@some.im") }
        let client = try AgentRegistryService(baseURL: "https://some.im/v1")
        #expect(client.origin.absoluteString == "https://some.im")
    }
    @Test func syncUsesCustomerIdentityAndConditionalWrite() async throws {
        let (library, root, defaults, suite) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite); RegistryTestURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RegistryTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = try AgentRegistryService(baseURL: "https://some.im", token: "test-customer-session", session: session)
        let account = AgentRegistryIdentity(user_id: "user-a", tenant_id: "tenant-a").account(origin: service.origin)
        let package = try AgentPackageV1.unsigned(definition())
        _ = try library.install(package, source: .private, account: account)
        var written = false
        RegistryTestURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-customer-session")
            let data: Data
            if request.url!.path.hasSuffix("agent-identity") {
                data = Data("{\"code\":0,\"data\":{\"user_id\":\"user-a\",\"tenant_id\":\"tenant-a\"}}".utf8)
            } else if request.httpMethod == "GET" {
                data = Data("{\"data\":{\"items\":[],\"cursor\":\"initial\"}}".utf8)
            } else {
                #expect(request.httpMethod == "PUT")
                #expect(request.value(forHTTPHeaderField: "If-None-Match") == "*")
                #expect(request.value(forHTTPHeaderField: "Idempotency-Key") != nil)
                written = true
                let item = AgentRegistryItem(definition_id: package.definition.definition_id, sha256: package.sha256,
                    version: package.definition.version, deleted: false, etag: "etag-1", package: package)
                data = try itemEnvelope(item)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let active = try await AgentRegistrySync(library: library, service: service).synchronize()
        #expect(active == account && written)
        let synced = try #require(library.state().installations.first)
        #expect(!synced.dirty && synced.etag == "etag-1")
        #expect(try library.profiles().first?.registrySnapshot?.revision == package.sha256)
    }
    @Test func staleAccountCannotImportRemoteDefinitions() async throws {
        let (library, root, defaults, suite) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite); RegistryTestURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RegistryTestURLProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let service = try AgentRegistryService(baseURL: "https://some.im", token: "test-session", session: session)
        RegistryTestURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("{\"data\":{\"user_id\":\"user-a\",\"tenant_id\":\"tenant-a\"}}".utf8))
        }
        await #expect(throws: (any Error).self) { try await AgentRegistrySync(library: library, service: service, sessionStillCurrent: { false }).synchronize() }
        #expect(library.activeAccount == nil)
        #expect(try library.state().installations.isEmpty)
    }
    @Test func pinnedRevisionAndDisabledStateSurviveCloudUpdateAndDeletion() async throws {
        let (library, root, defaults, suite) = try sandbox()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RegistryTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); RegistryTestURLProtocol.handler = nil; try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let service = try AgentRegistryService(baseURL: "https://some.im", token: "test-session", session: session)
        let account = AgentRegistryIdentity(user_id: "user-a", tenant_id: "tenant-a").account(origin: service.origin)
        let first = try AgentPackageV1.unsigned(definition())
        var local = try library.install(first, source: .private, account: account, dirty: false)
        local.etag = "initial"; local.pinned = true; local.enabled = false; try library.update(local)
        var newerDefinition = first.definition; newerDefinition.version = "1.0.0-rc2"; newerDefinition.instructions = "Cloud change."
        let newer = try AgentPackageV1.unsigned(newerDefinition)
        var remote = AgentRegistryItem(definition_id: newer.definition.definition_id, sha256: newer.sha256,
            version: newer.definition.version, deleted: false, etag: "remote", package: newer)
        RegistryTestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            let data = request.url!.path.hasSuffix("agent-identity")
                ? Data("{\"data\":{\"user_id\":\"user-a\",\"tenant_id\":\"tenant-a\"}}".utf8)
                : try listEnvelope([remote])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let sync = AgentRegistrySync(library: library, service: service)
        _ = try await sync.synchronize()
        var current = try #require(library.state().installations.first)
        #expect(current.selected == first.sha256 && !current.enabled && current.conflict?.sha256 == newer.sha256)
        remote.deleted = true; remote.package = nil
        _ = try await sync.synchronize()
        current = try #require(library.state().installations.first)
        #expect(!current.deleted && current.selected == first.sha256 && current.conflict?.deleted == true)
        current.pinned = false; current.conflict = nil; try library.update(current)
        remote.deleted = false; remote.package = newer
        _ = try await sync.synchronize()
        current = try #require(library.state().installations.first)
        #expect(current.selected == newer.sha256 && !current.enabled && current.conflict == nil)
    }
    @Test func lostResponseRetryUsesStableIdempotencyKeyAndEquivalentHeadAcknowledgesSuccess() async throws {
        let (library, root, defaults, suite) = try sandbox()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RegistryTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); RegistryTestURLProtocol.handler = nil; try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let service = try AgentRegistryService(baseURL: "https://some.im", token: "test-session", session: session)
        let package = try AgentPackageV1.unsigned(definition())
        let item = AgentRegistryItem(definition_id: package.definition.definition_id, sha256: package.sha256,
            version: package.definition.version, deleted: false, etag: "remote", package: package)
        var keys: [String] = []
        RegistryTestURLProtocol.handler = { request in
            keys.append(try #require(request.value(forHTTPHeaderField: "Idempotency-Key")))
            if keys.count == 1 { throw URLError(.networkConnectionLost) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try itemEnvelope(item))
        }
        await #expect(throws: (any Error).self) { try await service.upload(package, etag: nil) }
        _ = try await service.upload(package, etag: nil)
        #expect(keys.count == 2 && keys[0] == keys[1] && !keys[0].contains("test-session"))
        let account = AgentRegistryIdentity(user_id: "user-a", tenant_id: "tenant-a").account(origin: service.origin)
        _ = try library.install(package, source: .private, account: account)
        RegistryTestURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            let data = request.url!.path.hasSuffix("agent-identity")
                ? Data("{\"data\":{\"user_id\":\"user-a\",\"tenant_id\":\"tenant-a\"}}".utf8)
                : try listEnvelope([item])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        _ = try await AgentRegistrySync(library: library, service: service).synchronize()
        let current = try #require(library.state().installations.first)
        #expect(!current.dirty && current.etag == item.etag && current.conflict == nil)
    }
    @Test func unexpectedWriteResponseCannotMarkAnotherAssetAsSynchronized() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RegistryTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); RegistryTestURLProtocol.handler = nil }
        let service = try AgentRegistryService(baseURL: "https://some.im", token: "test-session", session: session)
        let requested = try AgentPackageV1.unsigned(definition())
        let other = try AgentPackageV1.unsigned(definition(id: "user/other"))
        let item = AgentRegistryItem(definition_id: other.definition.definition_id, sha256: other.sha256,
            version: other.definition.version, deleted: false, etag: "remote", package: other)
        RegistryTestURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try itemEnvelope(item))
        }
        await #expect(throws: (any Error).self) { try await service.upload(requested, etag: nil) }
        await #expect(throws: (any Error).self) { try await service.delete(id: requested.definition.definition_id, etag: "remote") }
    }
    @Test func verifiedSessionRestoresOfflineButChangedSessionAndLogoutHidePrivateAssets() throws {
        let (library, root, defaults, suite) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let identity = AgentRegistryIdentity(user_id: "user-a", tenant_id: "tenant-a")
        let origin = URL(string: "https://some.im")!
        let fingerprint = AgentPackageV1.hash(Data("test-session".utf8))
        let account = identity.account(origin: origin)
        _ = try library.install(.unsigned(definition()), source: .private, account: account)
        try library.recordVerifiedActivation(identity: identity, origin: origin, sessionFingerprint: fingerprint)
        library.activate(account: nil)
        let restarted = AgentDefinitionLibrary(root: root, defaults: defaults)
        restarted.restoreVerifiedActivation(origin: origin, sessionFingerprint: fingerprint)
        #expect(try restarted.profiles().count == 1)
        restarted.restoreVerifiedActivation(origin: origin, sessionFingerprint: "changed-session")
        #expect(try restarted.profiles().isEmpty)
        restarted.restoreVerifiedActivation(origin: URL(string: "https://another.example")!, sessionFingerprint: fingerprint)
        #expect(try restarted.profiles().isEmpty)
        restarted.restoreVerifiedActivation(origin: origin, sessionFingerprint: nil)
        #expect(try restarted.profiles().isEmpty)
        let persisted = String(decoding: try #require(defaults.data(forKey: AgentDefinitionLibrary.verifiedActivationKey)), as: UTF8.self)
        #expect(!persisted.contains("test-session"))
    }
    @Test func nativeWorkerSendsPinnedInstructionsAndCompleteLockedSkillBody() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral; sessionConfiguration.protocolClasses = [RegistryTestURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { session.invalidateAndCancel(); RegistryTestURLProtocol.handler = nil; try? FileManager.default.removeItem(at: workspace) }
        for role in ["reviewer", "implementer"] {
            var definition = definition(id: "user/fixture-" + role)
            definition.base_role = role
            if role == "implementer" { definition.tools.append("workspace.edit") }
            let skillBody = String(repeating: "Read evidence before making a claim.\n", count: 400)
            definition.skills = [.init(id: "evidence", content: skillBody, sha256: AgentPackageV1.hash(Data(skillBody.utf8)), required: true)]
            let package = try AgentPackageV1.unsigned(definition)
            let profile = try AgentDefinitionLibrary.project(package, binding: .inheritsParent)
            #expect(profile.runtime.executor == .willDeep && profile.usages == [.subagent])
            let worker = try #require(profile.asSubagentProfile())
            let writeAccess = role == "implementer" ? AgentSubagentWriteAccess(targetRelativePaths: ["fixture.rs"]) : nil
            var observed = false
            RegistryTestURLProtocol.handler = { request in
                let body = request.httpBody ?? request.httpBodyStream.map { stream in
                    stream.open(); defer { stream.close() }
                    var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }; data.append(buffer, count: count)
                    }
                    return data
                } ?? Data()
                let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                let messages = try #require(object?["messages"] as? [[String: Any]])
                let instruction = try #require(messages.first?["content"] as? String)
                #expect(instruction.contains(package.sha256))
                #expect(instruction.contains(definition.instructions))
                #expect(instruction.contains(skillBody))
                if role == "implementer" { #expect(instruction.contains("fixture.rs")) }
                observed = true
                let chunk: [String: Any] = ["choices": [["delta": ["content": "Fixture complete."], "finish_reason": "stop"]],
                                           "usage": ["prompt_tokens": 100, "completion_tokens": 10, "total_tokens": 110]]
                let data = Data(("data: " + String(decoding: try JSONSerialization.data(withJSONObject: chunk), as: UTF8.self)
                    + "\n\ndata: [DONE]\n\n").utf8)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, data)
            }
            let outcome = try await AgentSubagentRunner.run(prompt: "Inspect the supplied fixture", configuration: .init(
                providerID: "openai", baseURL: "https://agent-fixture.invalid/v1", model: "gpt-4.1", apiKey: "test-placeholder"),
                workspaceURL: workspace, profile: worker, writeAccess: writeAccess, session: session, firstContactTimeout: 60)
            #expect(observed && outcome.report.contains("Fixture complete."))
        }
    }
    @Test func rendersNativeDefinitionEditorInLightAndDark() async throws {
        let (library, root, defaults, suite) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let installation = try library.install(.unsigned(definition()), source: .local)
        let app = AppState(dispatchStore: AgentDispatchStore(defaults: defaults),
            runtimeKernel: AgentRuntimeKernel(loadPersisted: false, persistsEvents: false),
            sessionManagementDefaults: defaults, loadSessionCatalog: false)
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/agent-registry-visuals")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = NSHostingView(rootView: AgentRegistrySettingsView(library: library, initialSelection: installation)
                .environmentObject(app).environment(\.colorScheme, name == "dark" ? .dark : .light)
                .background(Color(nsColor: .windowBackgroundColor)).tint(.primary))
            let window = NSWindow(contentRect: NSRect(x: -18000, y: -18000, width: 1100, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.appearance = NSAppearance(named: appearance)
            window.orderFront(nil)
            defer { window.close() }
            view.appearance = NSAppearance(named: appearance); view.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(png.count > 1000)
            try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        }
    }
}

private final class RegistryTestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try #require(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
