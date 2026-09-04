//
//  AgentPluginVersionSelectionTests.swift
//  WillDeepTests
//
//  同一个插件装了好几份的时候，到底跑哪一份。
//
//  这组用例来自两个真实故障，症状一模一样——用户以为「这功能你们没做」：
//
//   · 游戏厅：几周前装过一次本地副本 1.2.0，之后在插件中心切过版本，
//     `activeVersions` 就把它钉死了。App 升级带来内置 1.3.0（新关卡形状），
//     钉选照旧生效，用户玩到的一直是老关卡。
//   · 待办：本地副本和内置包都叫 1.1.0，内容却不一样（作者改了内容忘了升
//     版号）。版号打平时 `.installed` 排在 `.bundled` 前面，陈旧的那份赢了，
//     附件功能整个不见，而且版本列表里两边显示的版号一样，用户根本无从
//     发现。
//
//  所以这里钉的是选择规则本身，不是某个插件。
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct AgentPluginVersionSelectionTests {
    private func makePackage(
        id: String,
        version: String,
        source: AgentPluginPackageSource
    ) throws -> AgentPluginPackage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep-version-pick-\(UUID().uuidString)", isDirectory: true)
        let manifestURL = root.appendingPathComponent(".codex-plugin/plugin.json")
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: ["name": id, "version": version])
        try data.write(to: manifestURL, options: .atomic)
        return try AgentPluginPackageLoader.load(
            packageURL: root,
            source: source,
            currentWillDeepVersion: "1.332.0"
        )
    }

    /// makeSnapshot 内部会先按 packageVersionDescending 排序，所以这里直接
    /// 走它，顺便把排序也一起测了。
    private func activeVersionAndSource(
        packages: [AgentPluginPackage],
        pinned: String?
    ) throws -> (String, AgentPluginPackageSource) {
        var state = AgentPluginRegistryState.empty
        if let pinned { state.activeVersions["sample"] = pinned }
        let snapshot = AgentPluginRegistry.makeSnapshot(packages: packages, issues: [], state: state)
        let record = try #require(snapshot.records.first(where: { $0.pluginID == "sample" }))
        return (record.activePackage.version, record.activePackage.source)
    }

    @Test
    func aNewerBundledVersionOverridesAStalePin() throws {
        let installed = try makePackage(id: "sample", version: "1.2.0", source: .installed)
        let bundled = try makePackage(id: "sample", version: "1.3.0", source: .bundled)
        defer { cleanUp([installed, bundled]) }

        // 用户几周前手动切到 1.2.0；App 升级后内置带来 1.3.0
        let (version, source) = try activeVersionAndSource(
            packages: [installed, bundled],
            pinned: "1.2.0"
        )
        #expect(version == "1.3.0")
        #expect(source == .bundled)
    }

    @Test
    func aNewerInstalledVersionLeavesThePinAlone() throws {
        let old = try makePackage(id: "sample", version: "1.2.0", source: .installed)
        let newer = try makePackage(id: "sample", version: "1.4.0", source: .installed)
        defer { cleanUp([old, newer]) }

        // 用户自己装进来的版本，升不升由他决定——版本切换功能就是干这个的
        let (version, source) = try activeVersionAndSource(
            packages: [old, newer],
            pinned: "1.2.0"
        )
        #expect(version == "1.2.0")
        #expect(source == .installed)
    }

    @Test
    func aPinToTheBundledVersionStillHolds() throws {
        let installed = try makePackage(id: "sample", version: "2.0.0", source: .installed)
        let bundled = try makePackage(id: "sample", version: "1.3.0", source: .bundled)
        defer { cleanUp([installed, bundled]) }

        // 钉在内置那一版上：内置没有更高的版本，破例条件不成立
        let (version, source) = try activeVersionAndSource(
            packages: [installed, bundled],
            pinned: "1.3.0"
        )
        #expect(version == "1.3.0")
        #expect(source == .bundled)
    }

    @Test
    func theBundledCopyWinsWhenVersionNumbersTie() throws {
        let installed = try makePackage(id: "sample", version: "1.1.0", source: .installed)
        let bundled = try makePackage(id: "sample", version: "1.1.0", source: .bundled)
        defer { cleanUp([installed, bundled]) }

        // 版号一样内容不一样时，陈旧的那份几乎总是本地安装的
        let (_, source) = try activeVersionAndSource(packages: [installed, bundled], pinned: nil)
        #expect(source == .bundled)
    }

    @Test
    func withoutAPinTheHighestVersionRuns() throws {
        let installed = try makePackage(id: "sample", version: "9.0.0", source: .installed)
        let bundled = try makePackage(id: "sample", version: "1.0.0", source: .bundled)
        defer { cleanUp([installed, bundled]) }

        // 内置优先只是打平时的兜底，不该压过一个真正更新的本地版本
        let (version, source) = try activeVersionAndSource(
            packages: [installed, bundled],
            pinned: nil
        )
        #expect(version == "9.0.0")
        #expect(source == .installed)
    }

    private func cleanUp(_ packages: [AgentPluginPackage]) {
        for package in packages {
            try? FileManager.default.removeItem(at: package.packageURL)
        }
    }
}
