//
//  AppUpdateCheckerTests.swift
//  WillDeepTests
//

import Foundation
import Testing
@testable import WillDeep

struct AppUpdateCheckerTests {
    @Test
    func semanticVersionsOrderReleaseCandidatesAndStableBuilds() throws {
        let rc1 = try #require(AppVersion("1.62.0-rc1"))
        let rc2 = try #require(AppVersion("1.62.0-rc2"))
        let stable = try #require(AppVersion("1.62.0"))
        let nextFeature = try #require(AppVersion("1.63.0-rc1"))

        #expect(rc1 < rc2)
        #expect(rc2 < stable)
        #expect(stable < nextFeature)
    }

    @Test
    func semanticVersionAcceptsVPrefixAndMissingPatch() throws {
        let short = try #require(AppVersion("v1.62"))
        let full = try #require(AppVersion("1.62.0"))

        #expect(short == full)
    }

    @Test
    func updateMetaDecodesSnakeCaseDownloadURL() throws {
        let data = try #require("""
        {
          "version": "1.63.0-rc1",
          "download_url": "https://meta.niuwoai.com/willdeep/WillDeep.dmg",
          "release_notes_url": "https://meta.niuwoai.com/willdeep/releases/1.63.0-rc1.html",
          "minimum_system_version": "13.7",
          "notes": "自动更新测试"
        }
        """.data(using: .utf8))

        let meta = try JSONDecoder().decode(AppUpdateMeta.self, from: data)

        #expect(meta.version == "1.63.0-rc1")
        #expect(meta.downloadURL.absoluteString == "https://meta.niuwoai.com/willdeep/WillDeep.dmg")
        #expect(meta.releaseNotesURL?.absoluteString == "https://meta.niuwoai.com/willdeep/releases/1.63.0-rc1.html")
        #expect(meta.minimumSystemVersion == "13.7")
        #expect(meta.notes == "自动更新测试")
    }

    @Test
    func updateMetaDecodesCamelCaseDownloadURL() throws {
        let data = try #require("""
        {
          "version": "1.63.0",
          "downloadURL": "https://meta.niuwoai.com/willdeep/WillDeep.dmg"
        }
        """.data(using: .utf8))

        let meta = try JSONDecoder().decode(AppUpdateMeta.self, from: data)

        #expect(meta.version == "1.63.0")
        #expect(meta.downloadURL.absoluteString == "https://meta.niuwoai.com/willdeep/WillDeep.dmg")
    }

    @Test
    func updateMetaDecodesSomeIMEnvelope() throws {
        let data = try #require("""
        {
          "code": 0,
          "data": {
            "update_available": true,
            "item": {
              "latest_version": "1.64.0-rc1",
              "download_url": "https://some.im/downloads/WillDeep.dmg",
              "release_notes": "Managed update"
            }
          }
        }
        """.data(using: .utf8))

        let meta = try AppUpdateChecker.decodeUpdateMeta(from: data)

        #expect(meta.version == "1.64.0-rc1")
        #expect(meta.downloadURL.absoluteString == "https://some.im/downloads/WillDeep.dmg")
        #expect(meta.notes == "Managed update")
    }

    @Test
    func managedUpdateURLsUseControlPlaneRoutes() throws {
        let settings = SomeIMIntegrationSettings(baseURL: "https://edge.example.test/v1")
        let metadataURL = try #require(AppUpdateChecker.managedUpdateURL(currentVersion: "1.180.0-rc1", settings: settings))
        let appcastURL = try #require(AppUpdateChecker.managedAppcastURL(settings: settings))

        #expect(metadataURL.path == "/api/v1/public/app-updates/latest")
        #expect(metadataURL.query?.contains("current_version=1.180.0-rc1") == true)
        #expect(appcastURL.path == "/api/v1/public/app-updates/appcast.xml")
        #expect(appcastURL.query?.contains("app_id=willdeep") == true)
        #expect(appcastURL.query?.contains("platform=macos") == true)
        #expect(appcastURL.query?.contains("channel=stable") == true)
    }
}
