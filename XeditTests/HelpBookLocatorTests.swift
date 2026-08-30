//
//  HelpBookLocatorTests.swift
//  XeditTests
//
//  「帮助」菜单自己开窗显示包内 Help Book，不再依赖系统帮助查看器
//  （macOS 26 起是「提示」，它会把第三方 Help Book 显示成
//  「所选内容当前不可用」）。这里锁定入口页面的定位与语言选择。
//

import Foundation
import Testing
@testable import WillDeep

struct HelpBookLocatorTests {
    private func makeBook(locales: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-help-test-\(UUID().uuidString)", isDirectory: true)
        let resources = root
            .appendingPathComponent(HelpBookLocator.bookFolder)
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        for locale in locales {
            let lproj = resources.appendingPathComponent("\(locale).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            try "<html>\(locale)</html>".write(
                to: lproj.appendingPathComponent(HelpBookLocator.accessFile),
                atomically: true,
                encoding: .utf8
            )
        }
        return root
    }

    @Test("a regional preference selects its base localization")
    func regionalPreferenceMatchesBaseLocalization() throws {
        let root = try makeBook(locales: ["en", "zh-Hans"])
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try #require(HelpBookLocator.indexURL(
            resourceURL: root,
            preferredLanguages: ["zh-Hans-CN", "en-US"]
        ))

        #expect(url.deletingLastPathComponent().lastPathComponent == "zh-Hans.lproj")
    }

    @Test("an unavailable language falls back to English")
    func unknownLanguageFallsBackToEnglish() throws {
        let root = try makeBook(locales: ["en", "zh-Hans"])
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try #require(HelpBookLocator.indexURL(
            resourceURL: root,
            preferredLanguages: ["fr-FR"]
        ))

        #expect(url.deletingLastPathComponent().lastPathComponent == "en.lproj")
    }

    @Test("a book with no page at all reports nothing rather than a broken URL")
    func emptyBookReturnsNil() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-help-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(HelpBookLocator.indexURL(resourceURL: root, preferredLanguages: ["en"]) == nil)
        #expect(HelpBookLocator.indexURL(resourceURL: nil, preferredLanguages: ["en"]) == nil)
    }

    @Test("the shipped help book has both localizations and a search index")
    func shippedHelpBookIsComplete() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resources = repositoryRoot
            .appendingPathComponent("Help/WillDeep.help/Contents/Resources", isDirectory: true)

        for locale in ["en", "zh-Hans"] {
            let lproj = resources.appendingPathComponent("\(locale).lproj", isDirectory: true)
            #expect(FileManager.default.fileExists(atPath: lproj.appendingPathComponent("index.html").path))
            // 索引缺失时旧系统的帮助查看器会转去在线帮助库找内容并报错。
            #expect(FileManager.default.fileExists(atPath: lproj.appendingPathComponent("WillDeep.helpindex").path))
            #expect(FileManager.default.fileExists(atPath: lproj.appendingPathComponent("WillDeep.cshelpindex").path))
        }

        let info = try #require(NSDictionary(contentsOf: repositoryRoot.appendingPathComponent(
            "Help/WillDeep.help/Contents/Info.plist"
        )))
        #expect(info["HPDBookType"] as? String == "3")
        #expect(info["HPDBookIndexPath"] as? String == "WillDeep.helpindex")
        // Help Viewer 用 CFBundleHelpBookName 找书，它必须与 book 的标题一致。
        #expect(info["HPDBookTitle"] as? String == "WillDeep Help")
    }
}
