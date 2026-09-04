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
