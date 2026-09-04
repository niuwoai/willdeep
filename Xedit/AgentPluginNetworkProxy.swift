//
//  AgentPluginNetworkProxy.swift
//  WillDeep
//
//  `window.willdeep.net.fetch`：由宿主代发的 HTTP 请求。
//
//  为什么要代发而不是让页面自己 fetch：页面跑在自定义 scheme 下，CSP 与
//  跨源策略让它本来就发不出去；更要紧的是，`network.access` 这个权限
//  只回答「这插件要不要联网」，用户在安装面板上还有权知道**联的是谁**。
//  所以真正的门是 manifest 里的 `networkDomains` 白名单，权限只是开关。
//
//  几条硬约束，都是为了不让这条通道变成任意出口：
//   · 只走 https。明文 http 与 file/自定义 scheme 一律拒；
//   · 主机必须命中白名单（精确或 `*.example.com` 后缀）；
//   · 回环与内网地址一律拒，**哪怕它被写进了白名单**——插件页不该成为
//     打本机服务和内网的跳板；
//   · 跳转要重新过一遍白名单，不然「白名单域名 302 到别处」就是个洞；
//   · 请求体与响应体都有上限，超时固定。
//

import Foundation

nonisolated enum AgentPluginNetworkProxy {
    static let maximumRequestBodyBytes = 512 * 1024
    static let maximumResponseBytes = 2 * 1024 * 1024
    static let timeout: TimeInterval = 20
    static let allowedMethods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]
    /// 由 URLSession 自己管、页面不该染指的头。`Host` 被改掉等于绕开
    /// 白名单校验。
    static let reservedHeaders: Set<String> = [
        "host", "content-length", "connection", "transfer-encoding",
        "upgrade", "proxy-authorization", "proxy-connection",
    ]

    /// 主机是否落在白名单里。`*.example.com` 匹配任意子域，但不匹配
    /// `example.com` 本身——想要就两条都写，别让通配符悄悄多覆盖一层。
    static func isAllowed(host: String, domains: [String]) -> Bool {
        let host = host.lowercased()
        guard !host.isEmpty else { return false }
        for raw in domains {
            let pattern = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(1)) // ".example.com"
                if host.hasSuffix(suffix), host.count > suffix.count { return true }
            } else if host == pattern {
                return true
            }
        }
        return false
    }

    /// 回环、链路本地与 RFC1918 内网。插件页不该成为打本机服务的跳板：
    /// 用户机器上常年跑着各种只听 127.0.0.1 的东西，它们大多没有鉴权。
    static func isPrivateOrLoopback(host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (0, _), (169, 254):
            return true
        case (192, 168):
            return true
        case (172, let second) where (16...31).contains(second):
            return true
        default:
            return false
        }
    }

    /// 把页面递过来的参数变成一个可发的请求；任何一条门槛不过就抛错。
    static func makeRequest(
        urlString: String,
        method rawMethod: String,
        headers: [String: String],
        body: String?,
        domains: [String]
    ) throws -> URLRequest {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              let host = url.host else {
            throw AgentPluginCapabilityError.invalidArgument("url")
        }
        guard scheme == "https" else {
            throw AgentPluginCapabilityError.networkSchemeRefused(scheme)
        }
        guard !isPrivateOrLoopback(host: host) else {
            throw AgentPluginCapabilityError.networkHostRefused(host)
        }
        guard isAllowed(host: host, domains: domains) else {
            throw AgentPluginCapabilityError.networkHostNotDeclared(host)
        }
        let method = rawMethod.isEmpty ? "GET" : rawMethod.uppercased()
        guard allowedMethods.contains(method) else {
            throw AgentPluginCapabilityError.invalidArgument("method")
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        for (key, value) in headers {
            let name = key.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !reservedHeaders.contains(name.lowercased()) else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body, !body.isEmpty {
            let data = Data(body.utf8)
            guard data.count <= maximumRequestBodyBytes else {
                throw AgentPluginCapabilityError.payloadTooLarge(maximumRequestBodyBytes)
            }
            request.httpBody = data
        }
        return request
    }

    /// 发出去并把响应收成页面能用的形状。
    static func send(_ request: URLRequest, domains: [String]) async throws -> [String: Any] {
        let delegate = RedirectGuard(domains: domains)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentPluginCapabilityError.invalidArgument("response")
        }
        let truncated = data.count > maximumResponseBytes
        let clipped = truncated ? data.prefix(maximumResponseBytes) : data
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            headers[key.lowercased()] = value
        }
        return [
            "status": http.statusCode,
            "headers": headers,
            "body": String(decoding: clipped, as: UTF8.self),
            "truncated": truncated,
        ]
    }

    /// 跳转要重新过白名单。`api.allowed.com` 回一个 302 指向别处，
    /// 若不复查，白名单就只拦得住第一跳。
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        private let domains: [String]

        init(domains: [String]) {
            self.domains = domains
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url,
                  url.scheme?.lowercased() == "https",
                  let host = url.host,
                  !AgentPluginNetworkProxy.isPrivateOrLoopback(host: host),
                  AgentPluginNetworkProxy.isAllowed(host: host, domains: domains) else {
                // 交回 nil = 不跟随跳转，调用方拿到的是那条 3xx 本身。
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}
