//
//  MobileGatewayCoordinator.swift
//  WillDeep
//
//  Starts and supervises the local Go Mobile Gateway process, fetches
//  desktop-only metadata, and connects the Swift desktop peer bridge.
//

import Combine
import Darwin
import Foundation

struct MobileGatewayPairingPayload: Codable, Equatable {
    var baseURL: String
    var pairingToken: String
    var protocolVersion: String
    var desktopName: String
    var expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case pairingToken = "pairing_token"
        case protocolVersion = "protocol_version"
        case desktopName = "desktop_name"
        case expiresAt = "expires_at"
    }

    var qrJSONString: String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

struct MobileGatewayDevice: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var createdAt: Date
    var lastConnectedAt: Date?
    var revokedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt = "created_at"
        case lastConnectedAt = "last_connected_at"
        case revokedAt = "revoked_at"
    }

    var isRevoked: Bool { revokedAt != nil }
}

struct MobileGatewayHealth: Codable, Equatable {
    struct VersionInfo: Codable, Equatable {
        var name: String
        var version: String
        var protocolVersion: String?

        enum CodingKeys: String, CodingKey {
            case name
            case version
            case protocolVersion = "protocol_version"
        }
    }

    var version: VersionInfo
    var protocolVersion: String
    var desktopName: String
    var pairingAllowed: Bool
    var desktopPeerConnected: Bool?

    enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol_version"
        case desktopName = "desktop_name"
        case pairingAllowed = "pairing_allowed"
        case desktopPeerConnected = "desktop_peer_connected"
    }
}

@MainActor
final class MobileGatewayCoordinator: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var settings: MobileGatewaySettings
    @Published private(set) var state: State = .stopped
    @Published private(set) var health: MobileGatewayHealth?
    @Published private(set) var pairingPayload: MobileGatewayPairingPayload?
    @Published private(set) var devices: [MobileGatewayDevice] = []
    @Published private(set) var displayBaseURL: URL?
    @Published private(set) var resolvedExecutablePath: String?

    private weak var appState: AppState?
    private var process: Process?
    private var monitorTask: Task<Void, Never>?
    private var tokenFileURL: URL?
    private let session: URLSession
    /// Tail (~4KB) of the child's stdout/stderr. Surfaced live in the
    /// settings "Gateway log" panel so the user can see the gateway's own
    /// output (e.g. "listening on …" or a bind error) instead of a silent
    /// "Starting…". Also appended to the failure message on non-zero exit.
    @Published private(set) var recentOutput = ""

    init(
        appState: AppState,
        settings: MobileGatewaySettings? = nil,
        session: URLSession? = nil
    ) {
        self.appState = appState
        self.settings = (settings ?? MobileGatewaySettingsStore.load()).normalized
        // Loopback session: the gateway always lives on 127.0.0.1, so a
        // configured system proxy must not intercept these probes.
        self.session = session ?? AgentNetworkSupport.loopbackSession()
    }

    deinit {
        monitorTask?.cancel()
        process?.terminate()
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var desktopPeerIsConnected: Bool {
        appState?.mobileGatewayDesktopPeer.isConnected ?? false
    }

    func updateSettings(_ newSettings: MobileGatewaySettings) {
        settings = newSettings.normalized
        MobileGatewaySettingsStore.save(settings)
    }

    func startIfEnabled() {
        guard settings.isEnabled else { return }
        Task { await start() }
    }

    func setEnabled(_ enabled: Bool) {
        var updated = settings
        updated.isEnabled = enabled
        updateSettings(updated)
        if enabled {
            Task { await start() }
        } else {
            stop()
        }
    }

    func start() async {
        guard process == nil else {
            await refresh()
            return
        }
        state = .starting
        recentOutput = ""
        do {
            var normalized = settings.normalized
            // 默认端口 8877 常被占用(残留网关进程或其它 App),直接导致
            // 子进程以 status 1 退出。从配置端口起探测第一个可 bind 的
            // 端口,自动避开冲突,保证「启动即可用」。
            if let available = Self.findAvailablePort(preferred: normalized.port),
               available != normalized.port {
                normalized.port = available
            }
            settings = normalized
            MobileGatewaySettingsStore.save(normalized)

            let executableURL = try Self.resolveExecutableURL(settings: normalized)
            resolvedExecutablePath = executableURL.path
            let desktopToken = try MobileGatewaySettingsStore.loadOrCreateDesktopToken()
            let desktopBaseURL = Self.desktopBaseURL(for: normalized)
            let pairingBaseURL = Self.pairingBaseURL(for: normalized)
            displayBaseURL = pairingBaseURL
            let tokenURL = try Self.writeDesktopTokenFile(desktopToken)
            tokenFileURL = tokenURL

            let gatewayProcess = Process()
            gatewayProcess.executableURL = executableURL
            gatewayProcess.arguments = [
                "serve-mobile",
                "--host", normalized.host,
                "--port", String(normalized.port),
                "--desktop-name", normalized.desktopName,
                "--desktop-token-file", tokenURL.path,
                "--pairing-ttl", "2m",
                "--allow-pairing=\(normalized.allowPairing ? "true" : "false")",
                "--pairing-base-url", pairingBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ]
            let outputPipe = Pipe()
            gatewayProcess.standardOutput = outputPipe
            gatewayProcess.standardError = outputPipe
            gatewayProcess.terminationHandler = { [weak self] finishedProcess in
                Task { @MainActor [weak self] in
                    self?.handleProcessTermination(finishedProcess)
                }
            }
            try gatewayProcess.run()
            process = gatewayProcess
            drain(pipe: outputPipe)

            try await waitUntilHealthy(baseURL: desktopBaseURL)
            appState?.mobileGatewayDesktopPeer.connect(baseURL: desktopBaseURL, desktopToken: desktopToken)
            state = .running
            await refresh()
        } catch {
            fail(error.localizedDescription)
        }
    }

    func stop() {
        appState?.mobileGatewayDesktopPeer.disconnect()
        process?.terminate()
        process = nil
        monitorTask?.cancel()
        monitorTask = nil
        health = nil
        pairingPayload = nil
        devices = []
        state = .stopped
        if let tokenFileURL {
            try? FileManager.default.removeItem(at: tokenFileURL)
            self.tokenFileURL = nil
        }
    }

    func refresh() async {
        guard process != nil else { return }
        guard let desktopToken = try? MobileGatewaySettingsStore.loadOrCreateDesktopToken() else { return }
        let baseURL = Self.desktopBaseURL(for: settings)
        displayBaseURL = Self.pairingBaseURL(for: settings)
        health = try? await get(path: "/mobile/health", baseURL: baseURL, token: nil, as: MobileGatewayHealth.self)
        pairingPayload = try? await get(path: "/mobile/pairing", baseURL: baseURL, token: desktopToken, as: MobileGatewayPairingResponse.self).pairingPayload
        devices = (try? await get(path: "/mobile/devices", baseURL: baseURL, token: desktopToken, as: DevicesResponse.self).devices) ?? devices
    }

    func revokeDevice(_ device: MobileGatewayDevice) async {
        guard let desktopToken = try? MobileGatewaySettingsStore.loadOrCreateDesktopToken() else { return }
        do {
            _ = try await post(
                path: "/mobile/devices/revoke",
                baseURL: Self.desktopBaseURL(for: settings),
                token: desktopToken,
                body: RevokeRequest(deviceID: device.id),
                as: RevokeResponse.self
            )
            await refresh()
        } catch {
            fail(error.localizedDescription)
        }
    }

    func rotatePairingPayload() async {
        guard process != nil else { return }
        guard let desktopToken = try? MobileGatewaySettingsStore.loadOrCreateDesktopToken() else { return }
        do {
            pairingPayload = try await post(
                path: "/mobile/pairing/rotate",
                baseURL: Self.desktopBaseURL(for: settings),
                token: desktopToken,
                body: EmptyRequest(),
                as: MobileGatewayPairingResponse.self
            ).pairingPayload
            await refresh()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func waitUntilHealthy(baseURL: URL) async throws {
        // Bounded by a wall-clock deadline with a short per-request timeout
        // so a hung health probe can't strand the UI on "Starting…"
        // indefinitely — if the gateway isn't healthy within the window we
        // fail fast and surface recentOutput in the failure message.
        var lastError: Error?
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            do {
                health = try await get(path: "/mobile/health", baseURL: baseURL, token: nil, timeout: 2, as: MobileGatewayHealth.self)
                return
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        throw lastError ?? CoordinatorError.gatewayDidNotBecomeHealthy
    }

    private func get<T: Decodable>(path: String, baseURL: URL, token: String?, timeout: TimeInterval? = nil, as type: T.Type) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = "GET"
        if let timeout { request.timeoutInterval = timeout }
        applyHeaders(to: &request, token: token)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response, as: type)
    }

    private func post<Body: Encodable, T: Decodable>(
        path: String,
        baseURL: URL,
        token: String,
        body: Body,
        as type: T.Type
    ) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = "POST"
        applyHeaders(to: &request, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response, as: type)
    }

    private func applyHeaders(to request: inout URLRequest, token: String?) {
        AgentNetworkSupport.applyStandardHeaders(to: &request)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func decode<T: Decodable>(data: Data, response: URLResponse, as type: T.Type) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw CoordinatorError.invalidResponse
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(APIEnvelope<T>.self, from: data)
        guard (200..<300).contains(http.statusCode), envelope.ok, let payload = envelope.data else {
            throw CoordinatorError.apiError(envelope.error.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: http.statusCode) : envelope.error)
        }
        return payload
    }

    private func handleProcessTermination(_ finishedProcess: Process) {
        guard process === finishedProcess else { return }
        process = nil
        appState?.mobileGatewayDesktopPeer.disconnect()
        if finishedProcess.terminationStatus == 0 {
            state = .stopped
        } else {
            fail(Self.terminationMessage(status: finishedProcess.terminationStatus, output: recentOutput))
        }
    }

    private func fail(_ message: String) {
        appState?.mobileGatewayDesktopPeer.disconnect()
        process?.terminate()
        process = nil
        state = .failed(message)
    }

    private func drain(pipe: Pipe) {
        monitorTask = Task.detached { [weak self] in
            let handle = pipe.fileHandleForReading
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { return }
                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    await self?.appendRecentOutput(text)
                }
            }
        }
    }

    /// Append child output, keeping only the tail so a long-running
    /// gateway doesn't accumulate unbounded logs in memory.
    private func appendRecentOutput(_ text: String) {
        recentOutput += text
        if recentOutput.count > 4096 {
            recentOutput = String(recentOutput.suffix(4096))
        }
    }

    static func resolveExecutableURL(settings: MobileGatewaySettings) throws -> URL {
        let fileManager = FileManager.default
        let configuredPath = settings.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredPath.isEmpty, fileManager.isExecutableFile(atPath: configuredPath) {
            return URL(fileURLWithPath: configuredPath)
        }

        var candidates: [String] = []
        if let resourcePath = Bundle.main.resourceURL?.appendingPathComponent("willdeep-agent").path {
            candidates.append(resourcePath)
        }
        candidates.append(
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("willdeep-agent/willdeep-agent").path
        )
        candidates.append(fileManager.currentDirectoryPath + "/willdeep-agent/willdeep-agent")
        candidates.append("/opt/homebrew/bin/willdeep-agent")
        candidates.append("/usr/local/bin/willdeep-agent")

        if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        throw CoordinatorError.executableNotFound
    }

    static func desktopBaseURL(for settings: MobileGatewaySettings) -> URL {
        let host = ["0.0.0.0", "::", ""].contains(settings.host) ? "127.0.0.1" : settings.host
        return URL(string: "http://\(host):\(settings.port)")!
    }

    static func pairingBaseURL(for settings: MobileGatewaySettings) -> URL {
        let host = ["0.0.0.0", "::", ""].contains(settings.host) ? (Self.primaryLANIPv4Address() ?? "127.0.0.1") : settings.host
        return URL(string: "http://\(host):\(settings.port)")!
    }

    static func writeDesktopTokenFile(_ token: String) throws -> URL {
        let directory = try applicationSupportDirectory()
            .appendingPathComponent("MobileGateway", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("desktop-token")
        try token.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleID = Bundle.main.bundleIdentifier ?? "com.willdeep.app"
        let url = base.appendingPathComponent(bundleID, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func primaryLANIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var fallback: String?
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard current.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                current.pointee.ifa_addr,
                socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let address = String(cString: hostname)
            if String(cString: current.pointee.ifa_name) == "en0" {
                return address
            }
            fallback = fallback ?? address
        }
        return fallback
    }

    /// Build a diagnosable failure string: the exit status plus the last
    /// few lines the child printed (the real reason — e.g. "address
    /// already in use" — instead of a bare status code).
    static func terminationMessage(status: Int32, output: String) -> String {
        let base = "Mobile Gateway exited with status \(status)."
        let tail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return base }
        let lastLines = tail
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(4)
            .joined(separator: "\n")
        return "\(base)\n\(lastLines)"
    }

    /// Find the first bindable TCP port at or above `preferred`. Default
    /// 8877 is frequently already held (a stale gateway or another app),
    /// which made the child exit with status 1; probing avoids the
    /// conflict. Returns nil if no port in the window is free.
    static func findAvailablePort(preferred: Int, attempts: Int = 50) -> Int? {
        let start = min(max(preferred, mobileGatewayPortRange.lowerBound), mobileGatewayPortRange.upperBound)
        for offset in 0..<attempts {
            let candidate = start + offset
            guard candidate <= mobileGatewayPortRange.upperBound else { break }
            if isPortBindable(candidate) { return candidate }
        }
        return nil
    }

    /// True when a TCP socket can bind 0.0.0.0:port right now — i.e. the
    /// port isn't held by an active listener. Mirrors what the Go child
    /// does on launch (plain bind, no SO_REUSEADDR) so the probe result
    /// matches the child's actual outcome.
    private static func isPortBindable(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }
}

struct APIEnvelope<T: Decodable>: Decodable {
    var ok: Bool
    var error: String
    var data: T?

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
        data = try container.decodeIfPresent(T.self, forKey: .data)
    }
}

struct MobileGatewayPairingResponse: Decodable {
    var pairingPayload: MobileGatewayPairingPayload?

    enum CodingKeys: String, CodingKey {
        case pairingPayload = "pairing_payload"
    }
}

private struct DevicesResponse: Decodable {
    var devices: [MobileGatewayDevice]
}

private struct RevokeRequest: Encodable {
    var deviceID: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
    }
}

private struct RevokeResponse: Decodable {
    var revoked: Bool
}

private struct EmptyRequest: Encodable {}

private enum CoordinatorError: LocalizedError, Equatable {
    case executableNotFound
    case gatewayDidNotBecomeHealthy
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Could not find an executable willdeep-agent binary."
        case .gatewayDidNotBecomeHealthy:
            return "Mobile Gateway did not become healthy."
        case .invalidResponse:
            return "Mobile Gateway returned an invalid response."
        case .apiError(let message):
            return message
        }
    }
}
