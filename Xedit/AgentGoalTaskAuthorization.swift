import Foundation
import CryptoKit

/// One exact foreground verifier inside one Goal/workspace. This is not a
/// command-family allowlist, completion evidence, or permission to escalate.
nonisolated struct AgentGoalTaskAuthorization: Codable, Equatable {
    static let maximumLifetime: TimeInterval = 8 * 60 * 60
    static let maximumGrants = 32
    let id: UUID
    let issuerCallID: UUID
    let sessionID: UUID
    let contractDigest: String
    let workspacePath: String
    let requestDigest: String
    let environmentDigest: String
    let inputDigests: [String: String]
    let grantedAt: Date
    let expiresAt: Date

    static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    /// Missing manifests are also fingerprinted: creating one invalidates the
    /// old grant. Do not harvest arbitrary workspace files or credential files.
    static func inputs(command: String) -> [String]? {
        guard let tokens = AgentCommandAuthorization.shellTokens(from: command), tokens.count >= 2,
              !tokens[1].hasPrefix("-"), !command.contains("\0") else { return nil }
        let manifests: [String]
        switch tokens[0] {
        case "ruby": manifests = [tokens[1], "Gemfile", "Gemfile.lock", ".ruby-version"]
        case "yarn", "npm", "pnpm", "bun": manifests = ["package.json", "yarn.lock", "package-lock.json", "pnpm-lock.yaml", "bun.lock", ".yarnrc.yml"]
        case "swift": manifests = ["Package.swift", "Package.resolved"]
        case "go": manifests = ["go.mod", "go.sum", "go.work"]
        case "cargo": manifests = ["Cargo.toml", "Cargo.lock", ".cargo/config.toml"]
        case "pytest": manifests = ["pyproject.toml", "pytest.ini", "setup.cfg", "conftest.py"]
        default: return nil
        }
        let explicitFiles = tokens.dropFirst().filter {
            !$0.hasPrefix("-") && $0.contains(".") && !$0.contains("*") && !$0.contains("=") && !$0.contains(":")
        }
        return Array(Set(manifests + explicitFiles)).sorted()
    }
}
