//
//  AgentPluginHostCapabilitiesTests.swift
//  WillDeepTests
//
//  插件页面新借到的三样宿主能力：只读文件、自己的存储、事件契约。
//
//  文件那部分的用例重点在「越界要拒」——这层守卫是 workspace.read 之所以
//  还叫「只读」的全部理由，破了它，插件权限就只是安装面板上的一行字。
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentPluginFileAccessTests {
    /// 造一个临时工作区：两个文件、一个子目录、一个隐藏文件。
    private func makeWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("willdeep-plugin-fs-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "hello plugin".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "let needle = 1\nlet other = 2\n".write(
            to: nested.appendingPathComponent("main.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "secret".write(
            to: root.appendingPathComponent(".hidden"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    @Test
    func listsVisibleEntriesUnderTheRoot() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try AgentPluginFileAccess.list(path: "", roots: [root])
        let entries = try #require(result["entries"] as? [[String: Any]])
        let names = entries.compactMap { $0["name"] as? String }
        #expect(names.contains("README.md"))
        #expect(names.contains("src"))
        // 点开头的一律不列：插件没理由顺手看到 .env / .git
        #expect(!names.contains(".hidden"))
        let directoryFlags = entries.filter { $0["name"] as? String == "src" }
            .compactMap { $0["isDirectory"] as? Bool }
        #expect(directoryFlags == [true])
    }

    @Test
    func readsFileContent() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try AgentPluginFileAccess.read(path: "README.md", roots: [root])
        #expect(result["text"] as? String == "hello plugin")
        #expect(result["truncated"] as? Bool == false)
    }

    @Test
    func readTruncatesOversizedFilesInsteadOfHandingThemToTheWebView() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = String(repeating: "a", count: AgentPluginFileAccess.maximumReadBytes + 4_096)
        try big.write(to: root.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)

        let result = try AgentPluginFileAccess.read(path: "big.txt", roots: [root])
        #expect(result["truncated"] as? Bool == true)
        let text = try #require(result["text"] as? String)
        #expect(text.utf8.count <= AgentPluginFileAccess.maximumReadBytes)
    }

    @Test
    func rejectsPathsThatEscapeTheWorkspace() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: AgentPluginCapabilityError.self) {
            _ = try AgentPluginFileAccess.read(path: "../../../../etc/hosts", roots: [root])
        }
        #expect(throws: AgentPluginCapabilityError.self) {
            _ = try AgentPluginFileAccess.read(path: "/etc/hosts", roots: [root])
        }
        #expect(throws: AgentPluginCapabilityError.self) {
            _ = try AgentPluginFileAccess.list(path: NSHomeDirectory(), roots: [root])
        }
    }

    @Test
    func rejectsSymlinksThatPointOutOfTheWorkspace() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        // 软链接不是第二道门：解析之后仍在根外就该拒
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: URL(fileURLWithPath: "/etc")
        )

        #expect(throws: AgentPluginCapabilityError.self) {
            _ = try AgentPluginFileAccess.list(path: "escape", roots: [root])
        }
    }

    @Test
    func absolutePathsInsideTheWorkspaceAreAccepted() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        // fs.list 回给页面的就是绝对路径，页面拿它再来读必须走得通
        let absolute = root.appendingPathComponent("README.md").path
        let result = try AgentPluginFileAccess.read(path: absolute, roots: [root])
        #expect(result["text"] as? String == "hello plugin")
    }

    @Test
    func searchFindsMatchesAndReportsTheRoot() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try AgentPluginFileAccess.search(
            query: "needle",
            path: "",
            isRegularExpression: false,
            limit: nil,
            roots: [root]
        )
        let matches = try #require(result["matches"] as? [String])
        #expect(matches.contains { $0.contains("main.swift") })
    }

    @Test
    func searchRejectsAnEmptyQuery() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: AgentPluginCapabilityError.self) {
            _ = try AgentPluginFileAccess.search(
                query: "   ",
                path: "",
                isRegularExpression: false,
                limit: nil,
                roots: [root]
            )
        }
    }

    @Test
    func everyEntryPointRefusesWhenThereIsNoWorkspace() {
        #expect(throws: AgentPluginCapabilityError.self) {
            _ = try AgentPluginFileAccess.list(path: "", roots: [])
        }
        #expect(throws: AgentPluginCapabilityError.self) {
            _ = try AgentPluginFileAccess.read(path: "x", roots: [])
        }
    }
}

@Suite
struct AgentPluginStorageStoreTests {
    /// 每个用例一个自己的目录。Swift Testing 并行跑用例，共享一个落盘
    /// 目录会让「另一个用例刚把目录删了」表现成 mktemp 失败。
    private func withTemporaryStore(_ body: (URL) throws -> Void) rethrows {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("willdeep-plugin-storage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test
    func roundTripsValuesAcrossReads() throws {
        try withTemporaryStore { directory in
            try AgentPluginStorageStore.setValue(
                ["a": 1],
                forKey: "draft",
                pluginID: "demo.plugin",
                directory: directory
            )
            let value = AgentPluginStorageStore.value(
                forKey: "draft",
                pluginID: "demo.plugin",
                directory: directory
            ) as? [String: Any]
            #expect(value?["a"] as? Int == 1)
            #expect(AgentPluginStorageStore.keys(pluginID: "demo.plugin", directory: directory) == ["draft"])

            try AgentPluginStorageStore.removeValue(
                forKey: "draft",
                pluginID: "demo.plugin",
                directory: directory
            )
            #expect(AgentPluginStorageStore.keys(pluginID: "demo.plugin", directory: directory).isEmpty)
        }
    }

    @Test
    func onePluginCannotSeeAnothersKeys() throws {
        try withTemporaryStore { directory in
            try AgentPluginStorageStore.setValue(
                "mine",
                forKey: "token",
                pluginID: "first.plugin",
                directory: directory
            )
            #expect(AgentPluginStorageStore.value(
                forKey: "token",
                pluginID: "second.plugin",
                directory: directory
            ) == nil)
            #expect(AgentPluginStorageStore.keys(pluginID: "second.plugin", directory: directory).isEmpty)
        }
    }

    @Test
    func pluginIdentifiersCannotEscapeTheStorageDirectory() throws {
        try withTemporaryStore { directory in
            // manifest 里的 id 是插件作者写的，不该能写出目录穿越来。
            // 点号保留（`com.foo.bar` 是正常 id），能穿越的是斜杠，那个被换掉了。
            try AgentPluginStorageStore.setValue(
                "x",
                forKey: "k",
                pluginID: "../../escape",
                directory: directory
            )
            let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(written == [".._.._escape.json"])
        }
    }

    @Test
    func rejectsOversizedValuesInsteadOfSilentlyDroppingThem() throws {
        try withTemporaryStore { directory in
            let huge = String(repeating: "x", count: AgentPluginStorageStore.maximumValueBytes + 1_024)
            #expect(throws: AgentPluginCapabilityError.self) {
                try AgentPluginStorageStore.setValue(
                    huge,
                    forKey: "big",
                    pluginID: "demo.plugin",
                    directory: directory
                )
            }
            // 写失败之后仓库还是空的，不能留下半条记录
            #expect(AgentPluginStorageStore.keys(pluginID: "demo.plugin", directory: directory).isEmpty)
        }
    }

    @Test
    func rejectsEmptyKeysAndNonJSONValues() throws {
        try withTemporaryStore { directory in
            #expect(throws: AgentPluginCapabilityError.self) {
                try AgentPluginStorageStore.setValue(
                    "v",
                    forKey: "  ",
                    pluginID: "demo.plugin",
                    directory: directory
                )
            }
            #expect(throws: AgentPluginCapabilityError.self) {
                try AgentPluginStorageStore.setValue(
                    Date(),
                    forKey: "when",
                    pluginID: "demo.plugin",
                    directory: directory
                )
            }
        }
    }
}

@Suite
struct AgentPluginBridgeContractTests {
    @Test
    func hostEventsCarryTheRightPermissionGate() {
        // 会话与回合事件带会话 id，属于会话元数据
        #expect(AgentPluginHostEvent.sessionChanged.requiredPermission == .conversationRead)
        #expect(AgentPluginHostEvent.turnStarted.requiredPermission == .conversationRead)
        #expect(AgentPluginHostEvent.turnFinished.requiredPermission == .conversationRead)
        // 工作区路径走 workspace.read
        #expect(AgentPluginHostEvent.workspaceChanged.requiredPermission == .workspaceRead)
        #expect(AgentPluginHostEvent.named("nope") == nil)
    }

    @Test
    func capabilityListIsValidJSONAndNamesTheNewSurfaces() throws {
        let literal = AgentPluginPageBridge.capabilitiesJSONLiteral
        let parsed = try JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [String]
        let capabilities = try #require(parsed)
        for expected in ["fs.list", "fs.read", "fs.search", "storage", "events", "chat.insert", "chat.send"] {
            #expect(capabilities.contains(expected))
        }
        // 旧能力不能因为加新东西就消失——插件靠这份清单降级
        #expect(capabilities.contains("ai.complete"))
        #expect(capabilities.contains("skills.list"))
    }

    @Test
    func conversationWriteIsASensitivePermissionAndInstallable() {
        // 能让 Agent 花钱、动工作区，必须和 process.execute 同一档
        #expect(AgentPluginPermission.conversationWrite.risk == .sensitive)
        // 不在加载器白名单里的权限，manifest 声明了也装不上
        #expect(AgentPluginPackageLoader.allowedPermissions.contains(.conversationWrite))
    }
}
