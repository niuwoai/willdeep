//
//  AgentPluginNetworkProxyTests.swift
//  WillDeepTests
//
//  宿主代发的 HTTP：白名单、内网拦截、请求整形。
//
//  这条通道最怕变成任意出口，所以用例的重点全在「什么该被拒」。
//

import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentPluginNetworkProxyTests {
    @Test
    func matchesExactHostsAndWildcards() {
        let domains = ["api.example.com", "*.cdn.example.org"]
        #expect(AgentPluginNetworkProxy.isAllowed(host: "api.example.com", domains: domains))
        #expect(AgentPluginNetworkProxy.isAllowed(host: "API.Example.com", domains: domains))
        #expect(AgentPluginNetworkProxy.isAllowed(host: "assets.cdn.example.org", domains: domains))
        // 通配符不覆盖裸域名：想要就两条都写，别让它悄悄多覆盖一层
        #expect(!AgentPluginNetworkProxy.isAllowed(host: "cdn.example.org", domains: domains))
        // 后缀相同但不是子域，也不能算命中
        #expect(!AgentPluginNetworkProxy.isAllowed(host: "evilcdn.example.org", domains: domains))
        #expect(!AgentPluginNetworkProxy.isAllowed(host: "example.com", domains: domains))
        #expect(!AgentPluginNetworkProxy.isAllowed(host: "api.example.com.evil.net", domains: domains))
    }

    @Test
    func emptyAllowlistReachesNothing() {
        // 声明了 network.access 却没写域名，不等于「随便连」
        #expect(!AgentPluginNetworkProxy.isAllowed(host: "api.example.com", domains: []))
    }

    @Test
    func recognizesLoopbackAndPrivateHosts() {
        for host in [
            "localhost", "app.localhost", "printer.local",
            "127.0.0.1", "10.1.2.3", "192.168.1.9", "172.16.0.1", "172.31.255.255",
            "169.254.1.1", "::1",
        ] {
            #expect(AgentPluginNetworkProxy.isPrivateOrLoopback(host: host), "\(host) 应被视为内网")
        }
        for host in ["api.example.com", "8.8.8.8", "172.32.0.1", "11.0.0.1"] {
            #expect(!AgentPluginNetworkProxy.isPrivateOrLoopback(host: host), "\(host) 不该被视为内网")
        }
    }

    @Test
    func buildsRequestsOnlyForDeclaredHttpsHosts() throws {
        let domains = ["api.example.com"]
        let request = try AgentPluginNetworkProxy.makeRequest(
            urlString: "https://api.example.com/v1/items?page=2",
            method: "post",
            headers: ["X-Trace": "abc"],
            body: "{\"a\":1}",
            domains: domains
        )
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Trace") == "abc")
        #expect(request.httpBody == Data("{\"a\":1}".utf8))
    }

    @Test
    func refusesPlainHttpAndOtherSchemes() {
        for url in [
            "http://api.example.com/x",
            "file:///etc/hosts",
            "willdeep-plugin://bundle/index.html",
        ] {
            #expect(throws: AgentPluginCapabilityError.self) {
                _ = try AgentPluginNetworkProxy.makeRequest(
                    urlString: url,
                    method: "GET",
                    headers: [:],
                    body: nil,
                    domains: ["api.example.com", "bundle"]
                )
            }
        }
    }

    @Test
    func refusesLoopbackEvenWhenDeclared() {
        // 白名单写了也不行：插件页不该成为打本机服务的跳板
        #expect(throws: AgentPluginCapabilityError.self) {
            _ = try AgentPluginNetworkProxy.makeRequest(
                urlString: "https://127.0.0.1:8080/admin",
                method: "GET",
                headers: [:],
                body: nil,
                domains: ["127.0.0.1"]
            )
        }
    }

    @Test
    func refusesUndeclaredHostsAndUnknownMethods() {
        #expect(throws: AgentPluginCapabilityError.self) {
            _ = try AgentPluginNetworkProxy.makeRequest(
                urlString: "https://other.example.net/x",
                method: "GET",
                headers: [:],
                body: nil,
                domains: ["api.example.com"]
            )
        }
        #expect(throws: AgentPluginCapabilityError.self) {
            _ = try AgentPluginNetworkProxy.makeRequest(
                urlString: "https://api.example.com/x",
                method: "TRACE",
                headers: [:],
                body: nil,
                domains: ["api.example.com"]
            )
        }
    }

    @Test
    func stripsHeadersThatWouldSubvertTheAllowlist() throws {
        let request = try AgentPluginNetworkProxy.makeRequest(
            urlString: "https://api.example.com/x",
            method: "GET",
            headers: ["Host": "evil.example.net", "Content-Length": "9", "X-Ok": "1"],
            body: nil,
            domains: ["api.example.com"]
        )
        // Host 被页面改掉,白名单校验就形同虚设
        #expect(request.value(forHTTPHeaderField: "Host") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Length") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Ok") == "1")
    }

    @Test
    func refusesOversizedRequestBodies() {
        let huge = String(repeating: "x", count: AgentPluginNetworkProxy.maximumRequestBodyBytes + 1)
        #expect(throws: AgentPluginCapabilityError.self) {
            _ = try AgentPluginNetworkProxy.makeRequest(
                urlString: "https://api.example.com/x",
                method: "POST",
                headers: [:],
                body: huge,
                domains: ["api.example.com"]
            )
        }
    }
}

@Suite
struct AgentPluginWebsiteDataStoreTests {
    @Test
    func identifiersAreStablePerPluginAndDifferAcrossPlugins() {
        let first = AgentPluginWebsiteDataStore.identifier(for: "com.example.alpha")
        let again = AgentPluginWebsiteDataStore.identifier(for: "com.example.alpha")
        let other = AgentPluginWebsiteDataStore.identifier(for: "com.example.beta")
        // 同一个插件每次启动都要落到同一个仓上，否则等于每次都清空
        #expect(first == again)
        // 所有插件页面共用同一个源，分仓是它们之间唯一的隔离
        #expect(first != other)
    }

    @Test
    func identifiersAreWellFormedUUIDs() {
        let id = AgentPluginWebsiteDataStore.identifier(for: "com.example.alpha")
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        #expect(bytes[6] & 0xF0 == 0x40)      // version 4
        #expect(bytes[8] & 0xC0 == 0x80)      // RFC 4122 variant
    }
}

@Suite
struct AgentPluginCommandApprovalStoreTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        // 前缀已登记进 TestDefaultsHygiene，残留壳会被清理
        let suiteName = "willdeep-plugin-approvals-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    @Test
    func remembersOneExactCommandOnly() {
        withDefaults { defaults in
            AgentPluginCommandApprovalStore.remember(
                command: "git status",
                pluginID: "demo.plugin",
                packageDigest: "sha-1",
                defaults: defaults
            )
            #expect(AgentPluginCommandApprovalStore.isRemembered(
                command: "git status",
                pluginID: "demo.plugin",
                packageDigest: "sha-1",
                defaults: defaults
            ))
            // 记住的是这一条的完整原文，不是前缀：别让 git status 替
            // git push --force 开门
            #expect(!AgentPluginCommandApprovalStore.isRemembered(
                command: "git status --short",
                pluginID: "demo.plugin",
                packageDigest: "sha-1",
                defaults: defaults
            ))
            // 也不跨插件
            #expect(!AgentPluginCommandApprovalStore.isRemembered(
                command: "git status",
                pluginID: "other.plugin",
                packageDigest: "sha-1",
                defaults: defaults
            ))
        }
    }

    @Test
    func aNewPackageDigestInvalidatesEveryMemory() {
        withDefaults { defaults in
            AgentPluginCommandApprovalStore.remember(
                command: "git status",
                pluginID: "demo.plugin",
                packageDigest: "sha-1",
                defaults: defaults
            )
            // 插件升级 = 代码换了人，上一版拿到的信任不该自动过继
            #expect(!AgentPluginCommandApprovalStore.isRemembered(
                command: "git status",
                pluginID: "demo.plugin",
                packageDigest: "sha-2",
                defaults: defaults
            ))
        }
    }

    @Test
    func forgettingOnePluginLeavesTheOthersAlone() {
        withDefaults { defaults in
            for plugin in ["a.plugin", "b.plugin"] {
                AgentPluginCommandApprovalStore.remember(
                    command: "ls",
                    pluginID: plugin,
                    packageDigest: "d",
                    defaults: defaults
                )
            }
            AgentPluginCommandApprovalStore.forget(pluginID: "a.plugin", defaults: defaults)
            #expect(AgentPluginCommandApprovalStore.rememberedCount(pluginID: "a.plugin", defaults: defaults) == 0)
            #expect(AgentPluginCommandApprovalStore.rememberedCount(pluginID: "b.plugin", defaults: defaults) == 1)
        }
    }

    @Test
    func perPluginMemoryIsCapped() {
        withDefaults { defaults in
            let limit = AgentPluginCommandApprovalStore.maximumPerPlugin
            for index in 0...(limit + 5) {
                AgentPluginCommandApprovalStore.remember(
                    command: "echo \(index)",
                    pluginID: "loud.plugin",
                    packageDigest: "d",
                    defaults: defaults
                )
            }
            // 上不封顶会让一个话痨插件把确认疲劳变成永久白名单
            #expect(AgentPluginCommandApprovalStore.rememberedCount(
                pluginID: "loud.plugin",
                defaults: defaults
            ) <= limit)
            // 裁剪从最旧的开始，最近记住的还在
            #expect(AgentPluginCommandApprovalStore.isRemembered(
                command: "echo \(limit + 5)",
                pluginID: "loud.plugin",
                packageDigest: "d",
                defaults: defaults
            ))
        }
    }
}
