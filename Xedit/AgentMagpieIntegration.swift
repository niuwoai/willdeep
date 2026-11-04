import Foundation
import Darwin

/// Read-only consumer of the CLI repository's canonical magpie-agent.v1 contract.
/// This module never loads user settings or credentials and never writes connection.json.
nonisolated enum AgentMagpieIntegration {
    static let providerEntryID = UUID(uuidString: "70D7B194-6038-4B32-8195-84F25E1648A3")!
    static let clientID = "willdeep"
    static let clientMarker = "magpie-willdeep"
    static let maximumFileBytes = 65_536
    static let maximumModelBytes = 1_024
    static let retryDelayNanoseconds: UInt64 = 100_000_000
    static let directoryComponents = [".willdeep", "integrations", "magpie", "desktop"]

    struct Connection: Equatable, Sendable {
        let baseURL: String
        let model: String
        let contextWindow: Int?
        let maximumOutputTokens: Int?
    }

    struct Failure: Error, Equatable, Sendable {
        enum Code: String, Sendable { case io, truncated, json, duplicate, field, type, version, client, url, model, metadata, size, file, conflict, disconnected }
        let code: Code
        var field: String? = nil
        var retryable: Bool { code == .io || code == .truncated }
    }

    enum State: Equatable, Sendable {
        case disconnected
        case connected(Connection)
        case invalid(Failure)
    }

    static func read(home: URL) async -> State {
        let first = await Task.detached(priority: .utility) { snapshot(home: home) }.value
        guard case .invalid(let error) = first, error.retryable else { return first }
        do { try await Task.sleep(nanoseconds: retryDelayNanoseconds) }
        catch { return .invalid(Failure(code: .io)) }
        return await Task.detached(priority: .utility) { snapshot(home: home) }.value
    }

    static func parse(_ data: Data?, clientID expectedClient: String = clientID) -> State {
        guard let data else { return .disconnected }
        guard data.count <= maximumFileBytes else { return .invalid(Failure(code: .size)) }
        do {
            var parser = ObjectParser(bytes: Array(data))
            let fields = try parser.parse(clientID: expectedClient)
            let context = try fields["context_window"].flatMap { try metadata($0, range: 4_000...1_048_576, field: "context_window") }
            let output = try fields["max_output_tokens"].flatMap { try metadata($0, range: 1...1_048_576, field: "max_output_tokens") }
            if let context, let output, output > context { throw Failure(code: .metadata) }
            if fields.isEmpty || fields["enabled"] == .boolean(false) || (fields.count == 1 && fields["model"] != nil) {
                return .disconnected
            }
            guard fields["schema_version"] == .integer(1), fields["client_id"] == .string(expectedClient),
                  fields["enabled"] == .boolean(true), fields["client_marker"] == .string("magpie-" + expectedClient),
                  case .string(let url) = fields["base_url"], case .string(let model) = fields["model"] else {
                throw Failure(code: .field)
            }
            return .connected(Connection(baseURL: try validatedBaseURL(url), model: model, contextWindow: context, maximumOutputTokens: output))
        } catch let failure as Failure { return .invalid(failure) }
        catch { return .invalid(Failure(code: .json)) }
    }

    /// Validate the raw spelling, before URLComponents can normalize shorthand IPs,
    /// escaped hosts, uppercase schemes, zero/overflow ports, or alternate paths.
    /// localhost is replaced at this boundary so DNS/proxy settings cannot redirect it.
    static func validatedBaseURL(_ raw: String) throws -> String {
        let pattern = #"^http(s)?://(localhost|127\.(?:0|[1-9][0-9]{0,2})\.(?:0|[1-9][0-9]{0,2})\.(?:0|[1-9][0-9]{0,2})|\[::1\])(?::([0-9]+))?/v1$"#
        guard let match = raw.range(of: pattern, options: .regularExpression), match == raw.startIndex..<raw.endIndex,
              let components = URLComponents(string: raw), let host = components.host else { throw Failure(code: .url) }
        if host.hasPrefix("127.") {
            guard host.split(separator: ".").allSatisfy({ Int($0).map { (0...255).contains($0) } == true }) else { throw Failure(code: .url) }
        }
        let authority = raw.components(separatedBy: "://")[1].dropLast(3)
        let portText: Substring?
        if authority.hasPrefix("[") {
            portText = authority.contains("]:") ? authority.split(separator: "]", maxSplits: 1)[1].dropFirst() : nil
        } else {
            portText = authority.contains(":") ? authority.split(separator: ":", maxSplits: 1)[1] : nil
        }
        if let portText {
            guard let port = Int(portText), (1...65_535).contains(port) else { throw Failure(code: .url) }
        }
        return raw.replacingOccurrences(of: "://localhost", with: "://127.0.0.1")
    }

    static func validateModel(_ model: String) throws {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.utf8.count <= maximumModelBytes,
              !model.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { throw Failure(code: .model) }
    }

    private static let allowedFields: Set<String> = ["schema_version", "client_id", "enabled", "base_url", "client_marker", "model", "context_window", "max_output_tokens"]

    private static func validateField(_ key: String, _ value: Value, clientID expected: String) throws {
        switch key {
        case "schema_version":
            guard case .integer(let n) = value else { throw Failure(code: .type, field: key) }
            guard n == 1 else { throw Failure(code: .version, field: key) }
        case "client_id", "client_marker":
            guard case .string(let id) = value else { throw Failure(code: .type, field: key) }
            guard id == (key == "client_id" ? expected : "magpie-" + expected) else { throw Failure(code: .client, field: key) }
        case "enabled":
            guard case .boolean = value else { throw Failure(code: .type, field: key) }
        case "base_url":
            guard case .string(let url) = value else { throw Failure(code: .type, field: key) }
            _ = try validatedBaseURL(url)
        case "model":
            guard case .string(let model) = value else { throw Failure(code: .type, field: key) }
            try validateModel(model)
        case "context_window": _ = try metadata(value, range: 4_000...1_048_576, field: key)
        case "max_output_tokens": _ = try metadata(value, range: 1...1_048_576, field: key)
        default: throw Failure(code: .field)
        }
    }

    private static func metadata(_ value: Value, range: ClosedRange<Int>, field: String) throws -> Int? {
        if value == .null { return nil }
        guard case .integer(let number) = value else { throw Failure(code: .type, field: field) }
        guard range.contains(number) else { throw Failure(code: .metadata, field: field) }
        return number
    }

    private static func openDirectory(home: URL, create: Bool = false) throws -> Int32? {
        var descriptor = Darwin.open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure(code: .io) }
        do {
            for component in directoryComponents {
                if create && mkdirat(descriptor, component, 0o700) != 0 && errno != EEXIST { throw Failure(code: .io) }
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 {
                    if errno == ENOENT { close(descriptor); return nil }
                    throw Failure(code: errno == ELOOP || errno == ENOTDIR ? .file : .io)
                }
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private static func snapshot(home: URL) -> State {
        do {
            guard let directory = try openDirectory(home: home) else { return .disconnected }
            defer { close(directory) }
            let descriptor = openat(directory, "connection.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else {
                if errno == ENOENT { return .disconnected }
                throw Failure(code: errno == ELOOP ? .file : .io)
            }
            defer { close(descriptor) }
            var before = stat()
            guard fstat(descriptor, &before) == 0 else { throw Failure(code: .io) }
            guard before.st_mode & S_IFMT == S_IFREG else { throw Failure(code: .file) }
            guard before.st_size <= maximumFileBytes else { throw Failure(code: .size) }
            var bytes = [UInt8](repeating: 0, count: maximumFileBytes + 1)
            var total = 0
            while total < bytes.count {
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(descriptor, buffer.baseAddress!.advanced(by: total), buffer.count - total)
                }
                if count < 0 { if errno == EINTR { continue }; throw Failure(code: .io) }
                if count == 0 { break }
                total += count
            }
            guard total <= maximumFileBytes else { throw Failure(code: .size) }
            var after = stat()
            guard fstat(descriptor, &after) == 0 else { throw Failure(code: .io) }
            guard before.st_size == after.st_size, total == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw Failure(code: .truncated) }
            return parse(Data(bytes.prefix(total)))
        } catch let failure as Failure { return .invalid(failure) }
        catch { return .invalid(Failure(code: .io)) }
    }

    /// Only the private support marker is written, off the main thread. Open directory
    /// descriptors survive atomic directory replacement without following a new symlink.
    static func writeSupportMarker(home: URL, version: String) async throws {
        try await Task.detached(priority: .utility) {
            guard let directory = try openDirectory(home: home, create: true) else { throw Failure(code: .io) }
            defer { close(directory) }
            let bytes = try JSONSerialization.data(withJSONObject: ["client_id": clientID, "schema_version": 1, "version": version])
            let temporary = ".client-\(UUID().uuidString).json"
            let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw Failure(code: .io) }
            defer { close(descriptor); unlinkat(directory, temporary, 0) }
            var offset = 0
            while offset < bytes.count {
                let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
                if count < 0 { if errno == EINTR { continue }; throw Failure(code: .io) }
                offset += count
            }
            guard renameat(directory, temporary, directory, "client.json") == 0 else { throw Failure(code: .io) }
        }.value
    }

    private enum Value: Equatable { case string(String), integer(Int), boolean(Bool), null, other }

    /// A small flat-object tokenizer preserves duplicate keys and integer *tokens*.
    /// Foundation's keyed decoders silently collapse duplicates and accept 1.0 as Int.
    private struct ObjectParser {
        let bytes: [UInt8]
        var index = 0
        mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte: UInt8) throws {
            whitespace()
            guard index < bytes.count else { throw Failure(code: .truncated) }
            guard bytes[index] == byte else { throw Failure(code: .json) }
            index += 1
        }
        mutating func string() throws -> String {
            whitespace()
            let start = index
            try take(34)
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 34 && !escaped {
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                    catch { throw Failure(code: .json) }
                }
                if byte == 92 && !escaped { escaped = true } else { escaped = false }
            }
            throw Failure(code: .truncated)
        }
        mutating func value() throws -> Value {
            whitespace()
            guard index < bytes.count else { throw Failure(code: .truncated) }
            if bytes[index] == 34 { return .string(try string()) }
            if bytes[index] == 123 || bytes[index] == 91 { return .other }
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 125].contains(bytes[index]) { index += 1 }
            let token = String(decoding: bytes[start..<index], as: UTF8.self)
            switch token {
            case "true": return .boolean(true)
            case "false": return .boolean(false)
            case "null": return .null
            default:
                if token.range(of: #"^-?(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil, let integer = Int(token) { return .integer(integer) }
                if (try? JSONSerialization.jsonObject(with: Data(token.utf8), options: .fragmentsAllowed)) != nil { return .other }
                if index == bytes.count { throw Failure(code: .truncated) }
                throw Failure(code: .json)
            }
        }
        mutating func parse(clientID: String) throws -> [String: Value] {
            try take(123)
            whitespace()
            var result: [String: Value] = [:]
            if index < bytes.count && bytes[index] == 125 { index += 1 }
            else {
                while true {
                    let key = try string()
                    guard result[key] == nil else { throw Failure(code: .duplicate) }
                    guard allowedFields.contains(key) else { throw Failure(code: .field) }
                    try take(58)
                    let parsed = try value()
                    try validateField(key, parsed, clientID: clientID)
                    result[key] = parsed
                    whitespace()
                    guard index < bytes.count else { throw Failure(code: .truncated) }
                    if bytes[index] == 125 { index += 1; break }
                    try take(44)
                }
            }
            whitespace()
            guard index == bytes.count else { throw Failure(code: .json) }
            return result
        }
    }
}
