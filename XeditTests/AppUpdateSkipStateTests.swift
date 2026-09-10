//
//  AppUpdateSkipStateTests.swift
//  WillDeepTests
//

import Foundation
import Testing

@testable import WillDeep

@Suite("更新跳过状态")
nonisolated struct AppUpdateSkipStateTests {
    // MARK: - 比较语义

    @Test("跳过的正是这一版就不再提示")
    func skipsExactVersion() {
        #expect(
            AppUpdateSkipState.skipsUpdate(
                candidateBundleVersion: 724,
                skippedMinorVersion: "724"
            )
        )
    }

    /// Sparkle 的判据是「已跳过版本 >= 候选版本」而不是相等。照抄这一条，
    /// 否则服务端回滚到更早的构建时，横幅会把用户明确拒绝过的东西再端上来。
    @Test("跳过的版本比候选新，同样不提示")
    func skipsOlderCandidate() {
        #expect(
            AppUpdateSkipState.skipsUpdate(
                candidateBundleVersion: 723,
                skippedMinorVersion: "724"
            )
        )
    }

    @Test("真正的新版本照常提示")
    func doesNotSkipNewerCandidate() {
        #expect(
            AppUpdateSkipState.skipsUpdate(
                candidateBundleVersion: 725,
                skippedMinorVersion: "724"
            ) == false
        )
    }

    // MARK: - 不确定时一律提示

    @Test("没有跳过记录就提示")
    func noRecordShowsBanner() {
        #expect(
            AppUpdateSkipState.skipsUpdate(
                candidateBundleVersion: 724,
                skippedMinorVersion: nil
            ) == false
        )
    }

    /// 接口万一不再返回 bundle_version，宁可多提示一次也不能静默藏起更新。
    @Test("拿不到候选构建号就提示")
    func missingCandidateShowsBanner() {
        #expect(
            AppUpdateSkipState.skipsUpdate(
                candidateBundleVersion: nil,
                skippedMinorVersion: "724"
            ) == false
        )
    }

    @Test("跳过记录不是数字就提示")
    func unparseableRecordShowsBanner() {
        #expect(
            AppUpdateSkipState.skipsUpdate(
                candidateBundleVersion: 724,
                skippedMinorVersion: "1.364.0-rc1"
            ) == false
        )
        #expect(
            AppUpdateSkipState.skipsUpdate(
                candidateBundleVersion: 724,
                skippedMinorVersion: ""
            ) == false
        )
    }

    @Test("记录带空格仍然认得出")
    func tolerantOfWhitespace() {
        #expect(
            AppUpdateSkipState.skipsUpdate(
                candidateBundleVersion: 724,
                skippedMinorVersion: " 724 "
            )
        )
    }

    @Test("用的是 Sparkle 自己的 defaults key")
    func usesSparkleKeys() {
        #expect(AppUpdateSkipState.skippedMinorVersionKey == "SUSkippedMinorVersion")
        #expect(AppUpdateSkipState.skippedMajorVersionKey == "SUSkippedMajorVersion")
    }

    // MARK: - 构建号解码

    /// 比对靠的是构建号。Sparkle 存的是 sparkle:version（724），
    /// 不是 1.365.0-rc1，所以这个字段必须真的解出来。
    @Test("接口返回的数字 bundle_version 能解出来")
    func decodesNumericBundleVersion() throws {
        let json = """
        {
          "latest_version": "1.364.0-rc1",
          "bundle_version": 724,
          "download_url": "https://example.com/WillDeep.dmg"
        }
        """
        let meta = try JSONDecoder().decode(AppUpdateMeta.self, from: Data(json.utf8))
        #expect(meta.bundleVersion == 724)
        #expect(meta.version == "1.364.0-rc1")
    }

    @Test("引号包起来的构建号也能解出来")
    func decodesQuotedBundleVersion() throws {
        let json = """
        {
          "latest_version": "1.364.0-rc1",
          "bundle_version": "724",
          "download_url": "https://example.com/WillDeep.dmg"
        }
        """
        let meta = try JSONDecoder().decode(AppUpdateMeta.self, from: Data(json.utf8))
        #expect(meta.bundleVersion == 724)
    }

    @Test("没有构建号字段不影响其余解码")
    func decodesWithoutBundleVersion() throws {
        let json = """
        {
          "latest_version": "1.364.0-rc1",
          "download_url": "https://example.com/WillDeep.dmg"
        }
        """
        let meta = try JSONDecoder().decode(AppUpdateMeta.self, from: Data(json.utf8))
        #expect(meta.bundleVersion == nil)
        #expect(meta.version == "1.364.0-rc1")
    }

    // MARK: - 闭环

    /// 这条守的是这个 bug 本身：跳过之后横幅必须消失。横幅是这次更新
    /// 唯一的入口，而点它会走 Sparkle 的用户主动检查，那条路会把跳过
    /// 记录删掉——所以一个不认跳过的横幅不是烦人，是会把跳过撤销掉。
    @Test("跳过之后横幅不再出现，用户不会被推回去撤销自己的跳过")
    func skippedUpdateStopsDrivingTheBanner() throws {
        let json = """
        {
          "latest_version": "1.364.0-rc1",
          "bundle_version": 724,
          "download_url": "https://example.com/WillDeep.dmg"
        }
        """
        let meta = try JSONDecoder().decode(AppUpdateMeta.self, from: Data(json.utf8))
        #expect(
            AppUpdateSkipState.skipsUpdate(
                candidateBundleVersion: meta.bundleVersion,
                skippedMinorVersion: "724"
            )
        )
    }
}
