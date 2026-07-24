//
//  MobileGatewaySettingsStore.swift
//  WillDeep
//
//  Persistence for the LAN Mobile Gateway control plane. Non-secret
//  preferences live in UserDefaults; the desktop bearer token lives in
//  Keychain because it authenticates the Swift desktop peer to the Go
//  gateway.
//

import Foundation
import Security

let mobileGatewayPortRange = 1...65535

/// How the Mac exposes the Mobile Gateway to a paired phone.
///
/// - `relay`: the Swift desktop peer connects directly to the public
///   internet relay (`j.niuwoai.com`) and the app builds the QR pairing
///   payload itself. NO local Go process runs — works off-LAN, nothing to
///   install. This is the default.
/// - `lanGateway`: launch the bundled Go `willdeep-agent serve-mobile`
///   process for same-network HTTP pairing + per-device tokens. Kept as an
///   opt-in fallback for offline/air-gapped LANs or when the phone needs
///   the HTTP claim flow.
enum MobileGatewayTransportMode: String, Codable, CaseIterable, Identifiable {
    case relay
    case lanGateway

    var id: String { rawValue }
}

struct MobileGatewaySettings: Codable, Equatable {
    static let defaultRelayBaseURL = "https://j.niuwoai.com"
    static let legacyDefaultRelayRoom = "willdeep-mobile"

    var transportMode: MobileGatewayTransportMode
    var host: String
    var port: Int
    var desktopName: String
    var executablePath: String
    var allowPairing: Bool
    var relayBaseURL: String
    var relayRoom: String

    enum CodingKeys: String, CodingKey {
        case transportMode
        case host
        case port
        case desktopName
        case executablePath
        case allowPairing
        case relayBaseURL
        case relayRoom
    }

    // 1.85.0-rc10:网关总是尝试启动,不再有「启用/停用」开关 —— 配对仍然
    // 走 token + QR 码,关闭开关没什么实际安全收益,反而增加用户认知负担。
    // 旧持久化里 `isEnabled` 字段保留在 JSON 里也无所谓(Codable 忽略多余
    // key),但本结构不再有这个字段。
    static let `default` = MobileGatewaySettings(
        transportMode: .relay,
        host: "0.0.0.0",
        port: 8877,
        desktopName: Host.current().localizedName ?? "WillDeep Mac",
        executablePath: "",
        allowPairing: true,
        relayBaseURL: Self.defaultRelayBaseURL,
        relayRoom: Self.legacyDefaultRelayRoom
    )

    init(
        transportMode: MobileGatewayTransportMode = .relay,
        host: String,
        port: Int,
        desktopName: String,
        executablePath: String,
        allowPairing: Bool,
        relayBaseURL: String,
        relayRoom: String
    ) {
        self.transportMode = transportMode
        self.host = host
        self.port = port
        self.desktopName = desktopName
        self.executablePath = executablePath
        self.allowPairing = allowPairing
        self.relayBaseURL = relayBaseURL
        self.relayRoom = relayRoom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default
        // Legacy installs predate transportMode; default them to relay so the
        // whole install base moves to the internet relay unless a user opts
        // back into the LAN gateway.
        transportMode = try container.decodeIfPresent(MobileGatewayTransportMode.self, forKey: .transportMode) ?? fallback.transportMode
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? fallback.host
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? fallback.port
        desktopName = try container.decodeIfPresent(String.self, forKey: .desktopName) ?? fallback.desktopName
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath) ?? fallback.executablePath
        allowPairing = try container.decodeIfPresent(Bool.self, forKey: .allowPairing) ?? fallback.allowPairing
        relayBaseURL = try container.decodeIfPresent(String.self, forKey: .relayBaseURL) ?? fallback.relayBaseURL
        relayRoom = try container.decodeIfPresent(String.self, forKey: .relayRoom) ?? fallback.relayRoom
    }

    var normalized: MobileGatewaySettings {
        normalized(defaultRelayRoom: Self.legacyDefaultRelayRoom)
    }

    func normalized(defaultRelayRoom: String) -> MobileGatewaySettings {
        let trimmedRelayBaseURL = relayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRelayRoom = relayRoom.trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedRoom = defaultRelayRoom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.legacyDefaultRelayRoom
            : defaultRelayRoom.trimmingCharacters(in: .whitespacesAndNewlines)
        return MobileGatewaySettings(
            // 1.195.0-rc22：手机网关固定走互联网中继。任何旧持久化里遗留的
            // `lanGateway`、或手动改过 JSON 的值，归一化时都强制回到 `.relay`，
            // 保证「开机自连中继」这条唯一线路不被历史配置污染。
            transportMode: .relay,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "0.0.0.0" : host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: min(max(port, mobileGatewayPortRange.lowerBound), mobileGatewayPortRange.upperBound),
            desktopName: desktopName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (Host.current().localizedName ?? "WillDeep Mac")
                : desktopName.trimmingCharacters(in: .whitespacesAndNewlines),
            executablePath: executablePath.trimmingCharacters(in: .whitespacesAndNewlines),
            allowPairing: allowPairing,
            relayBaseURL: trimmedRelayBaseURL.isEmpty ? Self.defaultRelayBaseURL : trimmedRelayBaseURL,
            relayRoom: trimmedRelayRoom.isEmpty || trimmedRelayRoom == Self.legacyDefaultRelayRoom
                ? generatedRoom
                : trimmedRelayRoom
        )
    }
}

enum MobileGatewaySettingsStore {
    enum StoreError: LocalizedError {
        case tokenEncodingFailed
        case tokenSaveFailed(OSStatus)
        case tokenLoadFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tokenEncodingFailed:
                return "Could not encode the Mobile Gateway desktop token."
            case .tokenSaveFailed(let status):
                return "Could not save the Mobile Gateway desktop token: \(status)."
            case .tokenLoadFailed(let status):
                return "Could not load the Mobile Gateway desktop token: \(status)."
            }
        }
    }

    private static let settingsKey = "com.willdeep.mobileGateway.settings.v1"
    private static let relayRoomKey = "com.willdeep.mobileGateway.relayRoom.v1"
    private static let keychainService = "com.willdeep.mobile-gateway"
    private static let desktopTokenAccount = "desktop-peer-token"
    private static let relayTokenAccount = "relay-token"

    static func load(defaults: UserDefaults = .standard) -> MobileGatewaySettings {
        let relayRoom = loadOrCreateRelayRoom(defaults: defaults)
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(MobileGatewaySettings.self, from: data) else {
            return MobileGatewaySettings.default.normalized(defaultRelayRoom: relayRoom)
        }
        return settings.normalized(defaultRelayRoom: relayRoom)
    }

    static func save(_ settings: MobileGatewaySettings, defaults: UserDefaults = .standard) {
        let relayRoom = loadOrCreateRelayRoom(defaults: defaults)
        guard let data = try? JSONEncoder().encode(settings.normalized(defaultRelayRoom: relayRoom)) else { return }
        defaults.set(data, forKey: settingsKey)
    }

    static func normalize(_ settings: MobileGatewaySettings, defaults: UserDefaults = .standard) -> MobileGatewaySettings {
        settings.normalized(defaultRelayRoom: loadOrCreateRelayRoom(defaults: defaults))
    }

    static func loadOrCreateDesktopToken() throws -> String {
        if let token = try loadDesktopToken(), !token.isEmpty {
            return token
        }
        let token = try generateDesktopToken()
        try saveDesktopToken(token)
        return token
    }

    static func resetDesktopToken() throws -> String {
        let token = try generateDesktopToken()
        try saveDesktopToken(token)
        return token
    }

    static func loadOrCreateRelayToken() throws -> String {
        if let token = try loadToken(account: relayTokenAccount), !token.isEmpty {
            return token
        }
        let token = try generateDesktopToken()
        try saveToken(token, account: relayTokenAccount)
        return token
    }

    /// Mint a fresh relay token, replacing the stored one. In relay mode this
    /// is how a phone is de-authorized: rotating the token (paired with a new
    /// room) invalidates the credential every previously paired device holds,
    /// so they must re-scan the QR. There is no per-device revoke over the
    /// relay — the shared room token is all-or-nothing by design.
    @discardableResult
    static func resetRelayToken() throws -> String {
        let token = try generateDesktopToken()
        try saveToken(token, account: relayTokenAccount)
        return token
    }

    private static func loadOrCreateRelayRoom(defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: relayRoomKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }
        let room = "willdeep-\(UUID().uuidString.lowercased())"
        defaults.set(room, forKey: relayRoomKey)
        return room
    }

    /// Replace the persisted relay room with a fresh random one and return it.
    /// Used alongside `resetRelayToken()` to rotate relay credentials.
    @discardableResult
    static func regenerateRelayRoom(defaults: UserDefaults = .standard) -> String {
        let room = "willdeep-\(UUID().uuidString.lowercased())"
        defaults.set(room, forKey: relayRoomKey)
        return room
    }

    private static func loadDesktopToken() throws -> String? {
        try loadToken(account: desktopTokenAccount)
    }

    private static func saveDesktopToken(_ token: String) throws {
        try saveToken(token, account: desktopTokenAccount)
    }

    private static func loadToken(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw StoreError.tokenLoadFailed(status)
        }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveToken(_ token: String, account: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw StoreError.tokenEncodingFailed
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw StoreError.tokenSaveFailed(updateStatus)
        }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw StoreError.tokenSaveFailed(addStatus)
        }
    }

    private static func generateDesktopToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw StoreError.tokenSaveFailed(status)
        }
        return Data(bytes).base64EncodedString()
    }
}
