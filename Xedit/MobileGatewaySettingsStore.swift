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

struct MobileGatewaySettings: Codable, Equatable {
    static let defaultRelayBaseURL = "https://j.niuwoai.com"
    static let legacyDefaultRelayRoom = "willdeep-mobile"

    var host: String
    var port: Int
    var desktopName: String
    var executablePath: String
    var allowPairing: Bool
    var relayBaseURL: String
    var relayRoom: String

    enum CodingKeys: String, CodingKey {
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
        host: "0.0.0.0",
        port: 8877,
        desktopName: Host.current().localizedName ?? "WillDeep Mac",
        executablePath: "",
        allowPairing: true,
        relayBaseURL: Self.defaultRelayBaseURL,
        relayRoom: Self.legacyDefaultRelayRoom
    )

    init(
        host: String,
        port: Int,
        desktopName: String,
        executablePath: String,
        allowPairing: Bool,
        relayBaseURL: String,
        relayRoom: String
    ) {
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

    private static func loadOrCreateRelayRoom(defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: relayRoomKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }
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
