import Foundation

extension AgentRegistryService {
    func write(_ installation: AgentDefinitionLibrary.Installation, library: AgentDefinitionLibrary) async throws -> AgentRegistryItem {
        if installation.deleted {
            guard let etag = installation.etag else { throw AgentAssetError.conflict }
            return try await delete(id: installation.definitionID, etag: etag)
        }
        return try await upload(library.package(revision: installation.selected, account: installation.account), etag: installation.etag)
    }
}

@MainActor enum AgentRegistrySessionGate {
    private static var observer: NSObjectProtocol?
    static func configure() {
        restore()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: SomeIMIntegrationStore.sessionDidChangeNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { restore() }
        }
    }
    static func restore() {
        #if DEBUG
        if SomeIMIntegrationStore.isRunningUnderXCTest { return }
        #endif
        let token = SomeIMIntegrationStore.loadSessionToken()
        let origin = try? AgentRegistryService(baseURL: SomeIMIntegrationStore.loadSettings().baseURL).origin
        AgentDefinitionLibrary().restoreVerifiedActivation(origin: origin,
            sessionFingerprint: token.isEmpty ? nil : AgentPackageV1.hash(Data(token.utf8)))
    }
}

@MainActor final class AgentRegistrySync {
    let library: AgentDefinitionLibrary
    let service: AgentRegistryService
    let sessionStillCurrent: () -> Bool
    init(library: AgentDefinitionLibrary, service: AgentRegistryService, sessionStillCurrent: @escaping () -> Bool = { true }) {
        self.library = library; self.service = service; self.sessionStillCurrent = sessionStillCurrent
    }
    func synchronize() async throws -> String {
        let identity = try await service.identity()
        guard sessionStillCurrent() else { throw AgentAssetError.authentication }
        let account = identity.account(origin: service.origin)
        let remote = try await service.list()
        guard sessionStillCurrent() else { throw AgentAssetError.authentication }
        try library.recordVerifiedActivation(identity: identity, origin: service.origin, sessionFingerprint: AgentPackageV1.hash(Data(service.token.utf8)))
        for item in remote.items {
            let local = try library.state().installations.first { $0.definitionID == item.definition_id && $0.account == account }
            if let local, local.selected == item.sha256 && local.deleted == item.deleted {
                var changed = local; changed.etag = item.etag; changed.dirty = false; changed.conflict = nil
                try library.update(changed); continue
            }
            if let local, !local.dirty && local.pinned == true && (local.selected != item.sha256 || item.deleted) {
                var changed = local; changed.conflict = item; try library.update(changed); continue
            }
            if let local, local.dirty {
                if local.etag != item.etag {
                    var changed = local; changed.conflict = item; try library.update(changed)
                }
                continue
            }
            if let local, item.deleted {
                var changed = local; changed.deleted = true; changed.enabled = false; changed.etag = item.etag
                try library.update(changed)
            } else if let package = item.package {
                var changed = try library.install(package, source: .private, account: account, dirty: false)
                changed.etag = item.etag; try library.update(changed)
            }
        }
        for local in try library.state().installations where local.account == account && local.dirty && local.conflict == nil {
            guard sessionStillCurrent() else { throw AgentAssetError.authentication }
            if local.deleted && local.etag == nil {
                var changed = local; changed.dirty = false; try library.update(changed); continue
            }
            do {
                let item = try await service.write(local, library: library)
                guard sessionStillCurrent() else { throw AgentAssetError.authentication }
                // Do not mark an edit made during the request as synchronized.
                guard var current = try library.state().installations.first(where: { $0.id == local.id }) else { continue }
                current.etag = item.etag
                if current.selected == local.selected && current.deleted == local.deleted { current.dirty = false }
                try library.update(current)
            } catch AgentAssetError.conflict {
                let latest = try await service.list()
                guard sessionStillCurrent() else { throw AgentAssetError.authentication }
                if let item = latest.items.first(where: { $0.definition_id == local.definitionID }) {
                    guard var changed = try library.state().installations.first(where: { $0.id == local.id }) else { continue }
                    changed.conflict = item; try library.update(changed)
                }
            }
        }
        return account
    }
}
