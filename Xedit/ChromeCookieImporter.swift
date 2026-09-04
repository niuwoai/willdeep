//
//  ChromeCookieImporter.swift
//  WillDeep
//
//  把用户本机 Chrome 的登录 cookie 导进内置浏览器，省去在内置浏览器里逐个
//  重新登录。这条路走的是主流浏览器迁移（Brave / Arc 的「从 Chrome 导入」）
//  的同一套做法，几条边界刻意守死：
//
//  1. 用户发起。只有点了地址栏那个导入 icon 才会跑，绝不后台自动抽。
//  2. 授权闸不绕。Chrome 的 cookie 用钥匙串里 "Chrome Safe Storage" 那把密钥
//     加密，读它时 macOS 会弹授权框——那正是这条链路的同意闸，我们如实触发
//     它，不做任何抑制或绕过。
//  3. 只在本机、只导 cookie。不碰保存的密码（那要用户走 Chrome 自己的导出
//     流程），解密结果不落任何日志、不出本机。
//
//  技术要点（macOS Chrome）：Safe Storage 口令经 PBKDF2(salt=saltysalt,
//  1003 轮, SHA1) 派生出 16 字节 AES 密钥；每条 cookie 的 encrypted_value 以
//  "v10" 打头，去前缀后是 AES-128-CBC 密文，IV 为 16 个 0x20。Chrome M127 起
//  明文前会多 32 字节的域名 SHA256，需要识别后剥掉。

import CommonCrypto
import Foundation
import SQLite3
import Security

nonisolated struct ChromeProfile: Identifiable, Equatable, Sendable {
    /// 目录名（Default / Profile 1 …），用作稳定标识。
    let id: String
    /// Preferences 里的展示名，取不到就回落到目录名。
    let displayName: String
    /// Cookies 库的绝对路径。
    let cookiesDatabasePath: String
}

nonisolated enum ChromeCookieImportError: Error, LocalizedError, Equatable {
    case chromeNotFound
    case keychainDenied
    case keychainMissing
    case databaseUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .chromeNotFound:
            return "No Chrome profile with cookies was found on this Mac."
        case .keychainDenied:
            return "Keychain access to Chrome Safe Storage was denied."
        case .keychainMissing:
            return "Chrome Safe Storage was not found in the Keychain."
        case .databaseUnreadable(let reason):
            return "The Chrome cookie database could not be read: \(reason)"
        }
    }
}

nonisolated struct ChromeCookieImportSummary: Equatable, Sendable {
    let imported: Int
    let skipped: Int
}

nonisolated enum ChromeCookieImporter {
    // Chromium 家族 cookie 加密的固定参数，多年未变。
    private static let salt = "saltysalt"
    private static let iterations: UInt32 = 1003
    private static let keyLength = 16
    private static let cbcIV = Data(repeating: 0x20, count: 16)
    /// Chrome M127 起，v10 明文前多出的域名 SHA256 长度。
    private static let domainHashPrefixLength = 32
    // expires_utc 是自 1601-01-01 起的微秒；换算到 Unix 需减去这个秒差。
    private static let windowsToUnixEpochSeconds: Double = 11_644_473_600

    static var defaultChromeRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }

    /// 枚举带 cookie 库的 Chrome profile。新版 Chrome 把库挪到了 Network/ 下，
    /// 两个位置都认。
    static func discoverProfiles(chromeRoot: URL = defaultChromeRoot) -> [ChromeProfile] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: chromeRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        var profiles: [ChromeProfile] = []
        for directory in entries {
            let name = directory.lastPathComponent
            guard name == "Default" || name.hasPrefix("Profile ") else { continue }
            let candidates = [
                directory.appendingPathComponent("Network/Cookies"),
                directory.appendingPathComponent("Cookies"),
            ]
            guard let cookies = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
                continue
            }
            profiles.append(
                ChromeProfile(
                    id: name,
                    displayName: profileDisplayName(in: directory) ?? name,
                    cookiesDatabasePath: cookies.path
                )
            )
        }
        return profiles.sorted { $0.id < $1.id }
    }

    private static func profileDisplayName(in directory: URL) -> String? {
        let preferences = directory.appendingPathComponent("Preferences")
        guard let data = try? Data(contentsOf: preferences),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let name = profile["name"] as? String,
              !name.isEmpty else {
            return nil
        }
        return name
    }

    /// 读钥匙串里的 Safe Storage 口令。这一步会触发 macOS 授权框；用户拒绝或
    /// 缺项时如实抛错，不静默继续。
    static func fetchSafeStorageKey(service: String = "Chrome Safe Storage") throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw ChromeCookieImportError.keychainMissing }
            return data
        case errSecItemNotFound:
            throw ChromeCookieImportError.keychainMissing
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw ChromeCookieImportError.keychainDenied
        default:
            throw ChromeCookieImportError.keychainDenied
        }
    }

    /// PBKDF2 派生 AES 密钥。纯函数，可单测。
    static func deriveKey(fromSafeStorageKey password: Data) -> Data {
        var derived = Data(count: keyLength)
        let saltBytes = Array(salt.utf8)
        _ = derived.withUnsafeMutableBytes { derivedPointer in
            password.withUnsafeBytes { passwordPointer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordPointer.baseAddress?.assumingMemoryBound(to: Int8.self),
                    password.count,
                    saltBytes,
                    saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    iterations,
                    derivedPointer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    keyLength
                )
            }
        }
        return derived
    }

    /// 解密单条 encrypted_value。非 v10 前缀的当作明文旧格式返回。纯函数，可单测。
    static func decrypt(encryptedValue blob: Data, key: Data) -> String? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else {
            // 早期 / 未加密的值直接按明文解。
            return String(data: blob, encoding: .utf8)
        }
        let ciphertext = blob.dropFirst(3)
        guard !ciphertext.isEmpty, ciphertext.count % 16 == 0,
              let plaintext = aesCBCDecrypt(Data(ciphertext), key: key, iv: cbcIV) else {
            return nil
        }
        return decodeCookiePlaintext(plaintext)
    }

    /// 新版 Chrome 在明文前塞了 32 字节域名哈希。先按原样试 UTF-8，不干净再剥
    /// 32 字节重试，避免把老格式误剥。
    private static func decodeCookiePlaintext(_ data: Data) -> String? {
        if let direct = cleanUTF8(data) {
            return direct
        }
        guard data.count > domainHashPrefixLength else { return nil }
        return cleanUTF8(data.dropFirst(domainHashPrefixLength))
    }

    private static func cleanUTF8<D: DataProtocol>(_ data: D) -> String? {
        guard let string = String(bytes: data, encoding: .utf8) else { return nil }
        // 明文里出现 NUL 或起手就是控制字符，多半是还带着二进制前缀，判为不干净。
        if string.unicodeScalars.contains(where: { $0.value == 0 }) { return nil }
        if let first = string.unicodeScalars.first, first.value < 0x20, first != "\t" { return nil }
        return string
    }

    private static func aesCBCDecrypt(_ ciphertext: Data, key: Data, iv: Data) -> Data? {
        let outputCapacity = ciphertext.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputPointer in
            ciphertext.withUnsafeBytes { cipherPointer in
                key.withUnsafeBytes { keyPointer in
                    iv.withUnsafeBytes { ivPointer in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPointer.baseAddress, key.count,
                            ivPointer.baseAddress,
                            cipherPointer.baseAddress, ciphertext.count,
                            outputPointer.baseAddress, outputCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(moved)
    }

    /// 读一个 profile 的全部 cookie，解密并构造 HTTPCookie。Chrome 可能锁着库，
    /// 所以先把库连同 -wal/-shm 拷到临时目录再只读打开。
    static func loadCookies(from profile: ChromeProfile, key: Data) throws -> (cookies: [HTTPCookie], skipped: Int) {
        let source = URL(fileURLWithPath: profile.cookiesDatabasePath)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-chrome-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let copy = temporaryDirectory.appendingPathComponent("Cookies")
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: source.path + suffix)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try? FileManager.default.copyItem(at: from, to: URL(fileURLWithPath: copy.path + suffix))
        }
        guard FileManager.default.fileExists(atPath: copy.path) else {
            throw ChromeCookieImportError.databaseUnreadable("copy failed")
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(database)
            throw ChromeCookieImportError.databaseUnreadable(message)
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly
        FROM cookies
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ChromeCookieImportError.databaseUnreadable(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var cookies: [HTTPCookie] = []
        var skipped = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cookie = makeCookie(from: statement, key: key) else {
                skipped += 1
                continue
            }
            cookies.append(cookie)
        }
        return (cookies, skipped)
    }

    private static func makeCookie(from statement: OpaquePointer?, key: Data) -> HTTPCookie? {
        let host = columnText(statement, 0)
        let name = columnText(statement, 1)
        guard !host.isEmpty, !name.isEmpty else { return nil }

        let plainValue = columnText(statement, 2)
        let value: String
        if !plainValue.isEmpty {
            value = plainValue
        } else if let blob = columnBlob(statement, 3), let decrypted = decrypt(encryptedValue: blob, key: key) {
            value = decrypted
        } else {
            return nil
        }

        let path = columnText(statement, 4)
        let expiresUTC = sqlite3_column_int64(statement, 5)
        let isSecure = sqlite3_column_int(statement, 6) != 0
        let isHTTPOnly = sqlite3_column_int(statement, 7) != 0

        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: host,
            .path: path.isEmpty ? "/" : path,
        ]
        if expiresUTC > 0 {
            let unix = Double(expiresUTC) / 1_000_000 - windowsToUnixEpochSeconds
            if unix > Date().timeIntervalSince1970 {
                properties[.expires] = Date(timeIntervalSince1970: unix)
            }
        }
        if isSecure { properties[.secure] = "TRUE" }
        // httpOnly 没有公开的 property key，用内部键名尽力设置。
        if isHTTPOnly { properties[HTTPCookiePropertyKey("HTTPOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)
    }

    private static func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private static func columnBlob(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return nil }
        return Data(bytes: pointer, count: count)
    }
}
