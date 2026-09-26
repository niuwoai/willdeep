//
//  AgentPluginMCPGatewayHTTP.swift
//  WillDeep
//
//  插件 MCP 网关用的最小 HTTP/1.1：只解析一条带 Content-Length 的请求，
//  回一条 `Connection: close` 的响应。网关只服务本机 MCP 客户端的 JSON-RPC
//  POST，用不到分块请求体、长连接或流水线，这些一律拒掉而不是半支持。
//
//  契约见 docs/decisions/0001-plugin-mcp-gateway.md。
//

import Foundation

/// 网关收到的一条 HTTP 请求。header 名一律转成小写存。
nonisolated struct AgentPluginMCPGatewayHTTPRequest: Equatable, Sendable {
    let method: String
    /// 请求行里的原始 target（含 query）。
    let target: String
    let headers: [String: String]
    let body: Data

    /// 去掉 query 之后的路径。
    var path: String {
        guard let queryStart = target.firstIndex(of: "?") else { return target }
        return String(target[..<queryStart])
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

nonisolated struct AgentPluginMCPGatewayHTTPResponse: Equatable, Sendable {
    nonisolated struct Header: Equatable, Sendable {
        let name: String
        let value: String
    }

    let status: Int
    let headers: [Header]
    let body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// 序列化成线上的字节。Content-Length / Connection 由这里统一补，调用方
    /// 只给业务相关的 header。
    func serialized() -> Data {
        var lines = ["HTTP/1.1 \(status) \(Self.reasonPhrase(for: status))"]
        for header in headers {
            lines.append("\(header.name): \(header.value)")
        }
        lines.append("Content-Length: \(body.count)")
        lines.append("Connection: close")
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }

    static func json(
        status: Int,
        body: Data,
        contentType: String = "application/json",
        extraHeaders: [Header] = []
    ) -> Self {
        Self(status: status, headers: [Header(name: "Content-Type", value: contentType)] + extraHeaders, body: body)
    }

    /// 非 JSON-RPC 层面的失败（鉴权、路由、方法），形状与插件自己的 HTTP 入口一致：
    /// `{"error": "..."}`。
    static func plainError(status: Int, message: String, extraHeaders: [Header] = []) -> Self {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": message], options: [.sortedKeys])) ?? Data()
        return json(status: status, body: body, extraHeaders: extraHeaders)
    }

    static func empty(status: Int) -> Self {
        Self(status: status, headers: [], body: Data())
    }

    static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default: return "Error"
        }
    }
}

nonisolated enum AgentPluginMCPGatewayHTTPParser {
    /// 请求行加全部 header 的上限。本机 MCP 客户端的请求头不过几百字节。
    static let maximumHeaderBytes = 32 * 1024
    /// 契约：请求体超过 8 MB 回 413。
    static let maximumBodyBytes = 8 * 1024 * 1024

    nonisolated enum Outcome: Equatable, Sendable {
        /// 还没收齐，继续读。
        case incomplete
        case request(AgentPluginMCPGatewayHTTPRequest)
        /// 请求本身不合格，直接回这个状态码并关连接。
        case reject(status: Int)
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    static func parse(_ input: Data) -> Outcome {
        // 统一成从 0 开始的索引，后面的切片运算才不会踩 Data 切片的坑。
        let buffer = Data(input)
        guard let terminator = buffer.range(of: headerTerminator) else {
            return buffer.count > maximumHeaderBytes ? .reject(status: 431) : .incomplete
        }
        guard terminator.lowerBound <= maximumHeaderBytes else { return .reject(status: 431) }
        guard let head = String(data: buffer.subdata(in: 0..<terminator.lowerBound), encoding: .utf8) else {
            return .reject(status: 400)
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              isToken(parts[0]),
              parts[1].hasPrefix("/"),
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            return .reject(status: 400)
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .reject(status: 400) }
            let name = String(line[..<colon]).lowercased()
            guard isToken(name) else { return .reject(status: 400) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                // 两个不一样的 Content-Length 是请求走私的经典手法，不猜哪个算数。
                if name == "content-length", existing != value { return .reject(status: 400) }
                headers[name] = name == "content-length" ? existing : "\(existing), \(value)"
            } else {
                headers[name] = value
            }
        }

        // 只收定长请求体：分块编码对一个只收单条 JSON-RPC 的网关没有意义。
        if headers["transfer-encoding"] != nil { return .reject(status: 411) }

        let method = parts[0]
        let length: Int
        if let rawLength = headers["content-length"] {
            guard !rawLength.isEmpty,
                  rawLength.allSatisfy(\.isASCII),
                  rawLength.allSatisfy(\.isNumber),
                  let parsed = Int(rawLength) else {
                return .reject(status: 400)
            }
            length = parsed
        } else if method == "POST" {
            return .reject(status: 411)
        } else {
            length = 0
        }
        // 在读请求体之前就拒：不为一个注定要拒的请求先攒 8 MB。
        guard length <= maximumBodyBytes else { return .reject(status: 413) }

        let bodyStart = terminator.upperBound
        guard buffer.count - bodyStart >= length else { return .incomplete }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        return .request(AgentPluginMCPGatewayHTTPRequest(
            method: method,
            target: parts[1],
            headers: headers,
            body: body
        ))
    }

    /// RFC 9110 的 token：方法名和 header 名只允许这些字符。
    private static func isToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let allowed = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return value.allSatisfy { allowed.contains($0) }
    }
}
