//
//  WillDeepKeychainStore.swift
//  WillDeep
//
//  Shared macOS Keychain transport for every WillDeep-owned credential
//  service. New rows live in the Data Protection Keychain under the signed
//  app access group; legacy file-Keychain rows are read once and migrated.
//

import Foundation
import LocalAuthentication
import Security

nonisolated enum WillDeepKeychainStore {
    static let accessGroup = "ZH2S7D6PL6.com.willdeep.app"
    static let usesDataProtectionKeychain = true

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var processCache: [String: Data] = [:]

    static func load(
        service: String,
        account: String,
        migrationAccessibility: CFString = kSecAttrAccessibleAfterFirstUnlock
    ) -> String? {
        guard let data = loadData(
            service: service,
            account: account,
            migrationAccessibility: migrationAccessibility
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func loadData(
        service: String,
        account: String,
        migrationAccessibility: CFString = kSecAttrAccessibleAfterFirstUnlock
    ) -> Data? {
        loadDataReportingStatus(
            service: service,
            account: account,
            migrationAccessibility: migrationAccessibility
        ).data
    }

    static func loadDataReportingStatus(
        service: String,
        account: String,
        migrationAccessibility: CFString = kSecAttrAccessibleAfterFirstUnlock
    ) -> (status: OSStatus, data: Data?) {
        if let cached = cachedData(service: service, account: account) {
            return (errSecSuccess, cached)
        }
        let protectedResult = readResult(
            service: service,
            account: account,
            dataProtection: true
        )
        if let protected = protectedResult.data {
            cache(protected, service: service, account: account)
            return (errSecSuccess, protected)
        }
        guard protectedResult.status == errSecItemNotFound ||
              protectedResult.status == errSecMissingEntitlement else {
            return (
                protectedResult.status == errSecSuccess ? errSecDecode : protectedResult.status,
                nil
            )
        }

        // Compatibility path for rows created by pre-rc8 builds. The old
        // Keychain may ask for its ACL password once. A successful read is
        // immediately copied into the app-scoped Data Protection Keychain.
        let legacyResult = readResult(
            service: service,
            account: account,
            dataProtection: false
        )
        guard let legacy = legacyResult.data else {
            return (legacyResult.status, nil)
        }
        cache(legacy, service: service, account: account)
        if write(
            legacy,
            service: service,
            account: account,
            accessibility: migrationAccessibility,
            dataProtection: true
        ) == errSecSuccess {
            deleteLegacyWithoutPrompt(service: service, account: account)
        }
        return (errSecSuccess, legacy)
    }

    @discardableResult
    static func save(
        _ value: String,
        service: String,
        account: String,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlock
    ) -> OSStatus {
        guard !value.isEmpty, let data = value.data(using: .utf8) else {
            delete(service: service, account: account)
            return errSecSuccess
        }
        return saveData(
            data,
            service: service,
            account: account,
            accessibility: accessibility
        )
    }

    @discardableResult
    static func saveData(
        _ data: Data,
        service: String,
        account: String,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlock
    ) -> OSStatus {
        if cachedData(service: service, account: account) == data {
            return errSecSuccess
        }
        let protectedStatus = write(
            data,
            service: service,
            account: account,
            accessibility: accessibility,
            dataProtection: true
        )
        if protectedStatus == errSecSuccess {
            cache(data, service: service, account: account)
            return errSecSuccess
        }
        guard protectedStatus == errSecMissingEntitlement else {
            return protectedStatus
        }

        // Keep unsigned/mis-signed local builds usable. Production signing is
        // verified to carry `accessGroup`, so release builds stay on the
        // Data Protection path.
        let legacyStatus = write(
            data,
            service: service,
            account: account,
            accessibility: accessibility,
            dataProtection: false
        )
        if legacyStatus == errSecSuccess {
            cache(data, service: service, account: account)
        }
        return legacyStatus
    }

    static func accounts(service: String, matchingPrefix prefix: String) -> [String] {
        let protected = accountNames(service: service, dataProtection: true)
        let legacy = accountNames(service: service, dataProtection: false)
        return Array(Set(protected + legacy))
            .filter { $0.hasPrefix(prefix) }
            .sorted()
    }

    static func delete(service: String, account: String) {
        removeCachedData(service: service, account: account)
        SecItemDelete(query(service: service, account: account, dataProtection: true) as CFDictionary)
        deleteLegacyWithoutPrompt(service: service, account: account)
    }

    static func query(
        service: String,
        account: String?,
        dataProtection: Bool
    ) -> [String: Any] {
        var result: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let account {
            result[kSecAttrAccount as String] = account
        }
        if dataProtection {
            result[kSecUseDataProtectionKeychain as String] = true
            result[kSecAttrAccessGroup as String] = accessGroup
        }
        return result
    }

    private static func readResult(
        service: String,
        account: String,
        dataProtection: Bool
    ) -> (status: OSStatus, data: Data?) {
        var lookup = query(service: service, account: account, dataProtection: dataProtection)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        guard status == errSecSuccess else {
            return (status, nil)
        }
        return (status, item as? Data)
    }

    private static func write(
        _ data: Data,
        service: String,
        account: String,
        accessibility: CFString,
        dataProtection: Bool
    ) -> OSStatus {
        let base = query(service: service, account: account, dataProtection: dataProtection)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return errSecSuccess
        }
        if updateStatus != errSecItemNotFound {
            return updateStatus
        }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = accessibility
        return SecItemAdd(add as CFDictionary, nil)
    }

    private static func accountNames(service: String, dataProtection: Bool) -> [String] {
        var lookup = query(service: service, account: nil, dataProtection: dataProtection)
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitAll
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess else {
            return []
        }
        let rows: [[String: Any]]
        if let many = item as? [[String: Any]] {
            rows = many
        } else if let one = item as? [String: Any] {
            rows = [one]
        } else {
            return []
        }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func deleteLegacyWithoutPrompt(service: String, account: String) {
        var legacy = query(service: service, account: account, dataProtection: false)
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        legacy[kSecUseAuthenticationContext as String] = authenticationContext
        SecItemDelete(legacy as CFDictionary)
    }

    private static func cachedData(service: String, account: String) -> Data? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return processCache[cacheKey(service: service, account: account)]
    }

    private static func cache(_ data: Data, service: String, account: String) {
        cacheLock.lock()
        processCache[cacheKey(service: service, account: account)] = data
        cacheLock.unlock()
    }

    private static func removeCachedData(service: String, account: String) {
        cacheLock.lock()
        processCache.removeValue(forKey: cacheKey(service: service, account: account))
        cacheLock.unlock()
    }

    private static func cacheKey(service: String, account: String) -> String {
        "\(service)\u{0}\(account)"
    }
}
