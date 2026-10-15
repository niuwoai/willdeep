import Foundation

extension AgentDefinitionLibrary {
    /// A visible suggestion, never an implicit published version change.
    func suggestedConflictVersion(_ installation: Installation) throws -> String {
        let local = try package(revision: installation.selected, account: installation.account).definition.version
        let base = local.replacingOccurrences(of: "-rc[0-9]+$", with: "", options: .regularExpression)
        var versions = Set(try installation.revisions.map { try package(revision: $0, account: installation.account).definition.version })
        if let remote = installation.conflict { versions.insert(remote.version) }
        let highest = versions.compactMap { version -> Int? in
            guard version.hasPrefix(base + "-rc") else { return nil }
            return Int(version.dropFirst((base + "-rc").count))
        }.max() ?? 0
        guard highest < Int.max else { throw AgentAssetError.invalidDefinition }
        return base + "-rc" + String(highest + 1)
    }
}
