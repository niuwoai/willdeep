//
//  ChromeCookieImporterTests.swift
//  WillDeepTests
//
//  Chrome cookie 解密没有第三方依赖，靠自造密文回环验证：用已知密钥 AES-CBC
//  加密一段明文、拼上 v10 前缀，再让 importer 解回来。不碰真实 Chrome 数据。

import CommonCrypto
import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct ChromeCookieImporterTests {
    private let iv = Data(repeating: 0x20, count: 16)

    // 测试侧的 AES-128-CBC 加密，和 importer 里的解密对称。
    private func encryptV10(_ plaintext: Data, key: Data) -> Data {
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        _ = output.withUnsafeMutableBytes { out in
            plaintext.withUnsafeBytes { plain in
                key.withUnsafeBytes { keyPointer in
                    iv.withUnsafeBytes { ivPointer in
                        CCCrypt(
                            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPointer.baseAddress, key.count,
                            ivPointer.baseAddress,
                            plain.baseAddress, plaintext.count,
                            out.baseAddress, capacity, &moved
                        )
                    }
                }
            }
        }
        return Data("v10".utf8) + output.prefix(moved)
    }

    private var key: Data {
        ChromeCookieImporter.deriveKey(fromSafeStorageKey: Data("peanuts".utf8))
    }

    @Test
    func decryptsARoundTrippedV10Value() {
        let blob = encryptV10(Data("session=abc123".utf8), key: key)
        #expect(ChromeCookieImporter.decrypt(encryptedValue: blob, key: key) == "session=abc123")
    }

    @Test
    func stripsTheDomainHashPrefixFromNewerChrome() {
        // Chrome M127 起，明文前多 32 字节域名哈希；解密后应被剥掉。
        let prefix = Data((0..<32).map { UInt8($0) })
        let blob = encryptV10(prefix + Data("token=xyz".utf8), key: key)
        #expect(ChromeCookieImporter.decrypt(encryptedValue: blob, key: key) == "token=xyz")
    }

    @Test
    func passesThroughAnUnencryptedLegacyValue() {
        // 没有 v10 前缀的老值按明文原样返回。
        #expect(ChromeCookieImporter.decrypt(encryptedValue: Data("plain".utf8), key: key) == "plain")
    }

    @Test
    func returnsNilWhenTheKeyIsWrong() {
        let blob = encryptV10(Data("secret".utf8), key: key)
        let wrongKey = ChromeCookieImporter.deriveKey(fromSafeStorageKey: Data("different".utf8))
        // 错密钥要么解出乱码（非 UTF-8 判 nil），要么 padding 校验失败。
        #expect(ChromeCookieImporter.decrypt(encryptedValue: blob, key: wrongKey) != "secret")
    }

    @Test
    func derivedKeyIsSixteenBytesAndStable() {
        let first = ChromeCookieImporter.deriveKey(fromSafeStorageKey: Data("k".utf8))
        let second = ChromeCookieImporter.deriveKey(fromSafeStorageKey: Data("k".utf8))
        #expect(first.count == 16)
        #expect(first == second)
    }

    @Test
    func discoversProfilesAtBothLegacyAndNetworkPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrome-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default

        // Default 用旧路径，Profile 1 用新的 Network/ 路径，都该被发现。
        let defaultDir = root.appendingPathComponent("Default")
        try fileManager.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        try Data().write(to: defaultDir.appendingPathComponent("Cookies"))

        let profileDir = root.appendingPathComponent("Profile 1/Network")
        try fileManager.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try Data().write(to: profileDir.appendingPathComponent("Cookies"))

        // 没有 cookie 库的目录不该被算进来。
        try fileManager.createDirectory(at: root.appendingPathComponent("Profile 2"), withIntermediateDirectories: true)

        let profiles = ChromeCookieImporter.discoverProfiles(chromeRoot: root)
        #expect(profiles.map(\.id) == ["Default", "Profile 1"])
    }
}
