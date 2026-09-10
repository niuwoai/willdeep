import Foundation

/// Plugin commands carry JSON over the WebKit bridge, not process argv.
enum AgentPluginCommandArgumentPolicy {
    nonisolated static let maximumKeyCount = 64
    // A 10 MiB attachment expands to ~14 MiB in Base64, and JSON may escape
    // every slash. Keep room for that expansion and the command metadata.
    nonisolated static let maximumEncodedBytes = 32 * 1024 * 1024

    nonisolated static func accepts(keyCount: Int, encodedArguments: Data?) -> Bool {
        guard keyCount <= maximumKeyCount, let encodedArguments else { return false }
        return encodedArguments.count <= maximumEncodedBytes
    }
}
