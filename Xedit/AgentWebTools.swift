//
//  AgentWebTools.swift
//  WillDeep
//
//  Built-in network tools: `web_search` (configured Exa / Brave
//  provider) and `web_fetch` (GET a public URL, reduce HTML to readable
//  text).
//
//  Risk posture mirrors the run_command classifier's stance on
//  curl/wget (both are flagged dangerous there): arbitrary fetching is
//  an exfiltration channel once hostile instructions are in context,
//  so `web_fetch` stays write-tier — per-call Allow, pinnable per
//  domain via the `web_fetch:<host>` signature, auto-approved in Goal
//  mode. `web_search` only ships the query string to one configured
//  search provider endpoint, so it rides the read tier like
//  search_files.
//
//  Both tools refuse loopback / RFC1918 / link-local hosts (and
//  redirects onto them) so the agent can't probe the user's LAN or
//  cloud metadata endpoints (169.254.169.254).
//

import Foundation

enum AgentWebTools {

    // MARK: - Limits

    /// Raw bytes pulled off the socket before we stop reading. Big
    /// enough for any article page, small enough that a pathological
    /// endpoint can't balloon memory.
    static let maxDownloadBytes = 3 * 1024 * 1024
    /// Default / ceiling for extracted text returned to the model.
    static let defaultMaxChars = 20_000
    static let maxMaxChars = 100_000
    static let defaultSearchCount = 8
    static let maxSearchCount = 20

    /// Page fetches should fail fast — these are interactive tool
    /// calls, not model streams, so AgentNetworkSupport's 120s
    /// no-bytes timeout would feel like a hang.
    private static let fetchTimeout: TimeInterval = 30

    private static let exaSearchEndpoint = "https://api.exa.ai/search"
    private static let braveSearchEndpoint = "https://api.search.brave.com/res/v1/web/search"

    // MARK: - web_fetch

    static func webFetch(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        guard let rawURL = arguments["url"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawURL.isEmpty else {
            throw AgentToolError.missingArgument("url")
        }
        let maxChars = clampMaxChars(arguments["max_chars"]?.intValue())

        guard let url = validatedPublicURL(rawURL) else {
            throw AgentToolError.invalidArgument(
                "`url` must be a public http(s) URL; private, loopback, and link-local hosts are refused: \(rawURL)"
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = fetchTimeout
        request.setValue("text/html, application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        AgentNetworkSupport.applyStandardHeaders(to: &request)

        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request, delegate: RedirectGuard.shared)

        guard let http = response as? HTTPURLResponse else {
            throw AgentToolError.invalidArgument("Non-HTTP response from \(redacted(url))")
        }
        if (300..<400).contains(http.statusCode) {
            // RedirectGuard refused to follow — the target host failed
            // the public-URL check.
            throw AgentToolError.invalidArgument(
                "Redirect from \(redacted(url)) points at a private or non-http(s) location; refusing to follow."
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = try await AgentNetworkSupport.collectBody(from: bytes)
            throw AgentToolError.httpFailed(
                http.statusCode,
                "GET \(redacted(url)): \(String(body.prefix(400)))"
            )
        }

        var data = Data()
        var truncatedDownload = false
        for try await byte in bytes {
            data.append(byte)
            if data.count >= maxDownloadBytes {
                truncatedDownload = true
                break
            }
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard let body = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw AgentToolError.invalidArgument(
                "Response from \(redacted(url)) is not text (Content-Type: \(contentType.isEmpty ? "unknown" : contentType))."
            )
        }

        let extraction: Extraction
        if contentType.contains("html") || looksLikeHTML(body) {
            extraction = extractReadableText(fromHTML: body)
        } else {
            extraction = Extraction(title: nil, text: body)
        }

        var text = extraction.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var truncatedText = false
        if text.count > maxChars {
            text = String(text.prefix(maxChars))
            truncatedText = true
        }

        var headerLines = ["URL: \(redacted(url))"]
        if let title = extraction.title, !title.isEmpty {
            headerLines.append("Title: \(title)")
        }
        if truncatedDownload || truncatedText {
            headerLines.append("[content truncated]")
        }
        let payload = headerLines.joined(separator: "\n") + "\n\n" + (text.isEmpty ? "(no readable text)" : text)

        let host = url.host ?? "?"
        let summary = "Fetched \(host) (\(text.count) chars\(truncatedDownload || truncatedText ? ", truncated" : ""))"
        return AgentToolResult(
            summary: summary,
            payload: payload,
            references: [
                AgentSourceReference(
                    title: extraction.title,
                    url: redacted(url),
                    toolName: "web_fetch"
                )
            ]
        )
    }

    // MARK: - web_search

    static func webSearch(arguments: [String: AgentJSONValue]) async throws -> AgentToolResult {
        guard let query = arguments["query"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !query.isEmpty else {
            throw AgentToolError.missingArgument("query")
        }
        let count = clampSearchCount(arguments["count"]?.intValue())

        let provider = resolveSearchProvider()
        guard let provider else {
            throw AgentToolError.invalidArgument(
                "No web search API key configured. Ask the user to add an Exa API key in Settings → Agent → Web tools, or choose Brave and add a Brave Search API key."
            )
        }

        switch provider {
        case let .exa(apiKey):
            return try await performExaSearch(query: query, count: count, apiKey: apiKey)
        case let .brave(apiKey):
            return try await performBraveSearch(query: query, count: count, apiKey: apiKey)
        }
    }

    private enum ResolvedSearchProvider {
        case exa(apiKey: String)
        case brave(apiKey: String)
    }

    private static func resolveSearchProvider() -> ResolvedSearchProvider? {
        let selected = AgentSettingsStore.loadWebSearchProvider()
        let exaKey = AgentSettingsStore.loadExaSearchAPIKey()
        let braveKey = AgentSettingsStore.loadBraveSearchAPIKey()

        switch selected {
        case .exa:
            return exaKey.isEmpty ? nil : .exa(apiKey: exaKey)
        case .brave:
            return braveKey.isEmpty ? nil : .brave(apiKey: braveKey)
        case .auto:
            if !exaKey.isEmpty { return .exa(apiKey: exaKey) }
            if !braveKey.isEmpty { return .brave(apiKey: braveKey) }
            return nil
        }
    }

    private static func performExaSearch(query: String, count: Int, apiKey: String) async throws -> AgentToolResult {
        guard let url = URL(string: exaSearchEndpoint) else {
            throw AgentToolError.invalidArgument("Invalid Exa Search endpoint.")
        }
        let body = ExaSearchRequest(
            query: query,
            numResults: count,
            type: "auto",
            contents: ExaSearchRequest.Contents(highlights: true)
        )
        let encodedBody: Data
        do {
            encodedBody = try JSONEncoder().encode(body)
        } catch {
            throw AgentToolError.invalidArgument("Could not encode Exa Search request: \(error.localizedDescription)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = fetchTimeout
        request.httpBody = encodedBody
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        AgentNetworkSupport.applyStandardHeaders(to: &request)

        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AgentToolError.invalidArgument("Non-HTTP response from Exa Search API.")
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw AgentToolError.invalidArgument(
                "Exa Search API rejected the key (HTTP \(http.statusCode)). Ask the user to re-check it in Settings → Agent → Web tools."
            )
        case 429:
            throw AgentToolError.invalidArgument(
                "Exa Search API rate limit hit (HTTP 429). Wait a moment before searching again."
            )
        default:
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw AgentToolError.httpFailed(http.statusCode, "Exa Search API: \(body)")
        }

        return try formatExaResults(data: data, query: query)
    }

    private static func performBraveSearch(query: String, count: Int, apiKey: String) async throws -> AgentToolResult {

        var components = URLComponents(string: braveSearchEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(count))
        ]
        guard let url = components.url else {
            throw AgentToolError.invalidArgument("Could not encode query: \(query)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = fetchTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        AgentNetworkSupport.applyStandardHeaders(to: &request)

        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AgentToolError.invalidArgument("Non-HTTP response from Brave Search API.")
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw AgentToolError.invalidArgument(
                "Brave Search API rejected the key (HTTP \(http.statusCode)). Ask the user to re-check it in Settings → Agent → Web tools."
            )
        case 429:
            throw AgentToolError.invalidArgument(
                "Brave Search API rate limit hit (HTTP 429). Wait a moment before searching again."
            )
        default:
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw AgentToolError.httpFailed(http.statusCode, "Brave Search API: \(body)")
        }

        return try formatBraveResults(data: data, query: query)
    }

    // MARK: - Exa response parsing (split out for tests)

    private struct ExaSearchRequest: Encodable {
        struct Contents: Encodable {
            var highlights: Bool
        }

        var query: String
        var numResults: Int
        var type: String
        var contents: Contents
    }

    private struct ExaResponse: Decodable {
        struct Cost: Decodable {
            var total: Double?
        }

        struct Item: Decodable {
            var title: String?
            var url: String?
            var publishedDate: String?
            var author: String?
            var text: String?
            var highlights: [String]?
            var summary: String?
        }

        var results: [Item]
        var costDollars: Cost?
    }

    static func formatExaResults(data: Data, query: String) throws -> AgentToolResult {
        let decoded: ExaResponse
        do {
            decoded = try JSONDecoder().decode(ExaResponse.self, from: data)
        } catch {
            throw AgentToolError.invalidArgument("Could not parse Exa Search response: \(error.localizedDescription)")
        }

        guard !decoded.results.isEmpty else {
            return AgentToolResult(
                summary: "No Exa results for “\(query)”",
                payload: "Exa web search for \"\(query)\" returned no results. Try different keywords."
            )
        }

        var lines: [String] = ["Web search results for \"\(query)\" (Exa):", ""]
        var references: [AgentSourceReference] = []
        for (index, item) in decoded.results.enumerated() {
            let title = condenseWhitespace(decodeHTMLEntities(stripTags(item.title ?? "")))
            lines.append("\(index + 1). \(title.isEmpty ? "(untitled)" : title)")
            lines.append("   \(item.url ?? "")")
            if let reference = sourceReference(title: title, rawURL: item.url, toolName: "web_search") {
                references.append(reference)
            }

            var metadata: [String] = []
            if let publishedDate = item.publishedDate, !publishedDate.isEmpty {
                metadata.append("published: \(publishedDate)")
            }
            if let author = item.author, !author.isEmpty {
                metadata.append("author: \(condenseWhitespace(author))")
            }
            if !metadata.isEmpty {
                lines.append("   \(metadata.joined(separator: " | "))")
            }

            let snippet = exaSnippet(for: item)
            if !snippet.isEmpty {
                lines.append("   \(snippet)")
            }
            lines.append("")
        }
        if let total = decoded.costDollars?.total {
            lines.append("Provider cost estimate: $\(String(format: "%.6f", total))")
        }
        return AgentToolResult(
            summary: "\(decoded.results.count) Exa result\(decoded.results.count == 1 ? "" : "s") for “\(query)”",
            payload: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            references: references
        )
    }

    private static func exaSnippet(for item: ExaResponse.Item) -> String {
        let raw = item.highlights?.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            ?? item.summary
            ?? item.text
            ?? ""
        let cleaned = condenseWhitespace(decodeHTMLEntities(stripTags(raw)))
        guard cleaned.count > 360 else { return cleaned }
        return String(cleaned.prefix(357)) + "..."
    }

    // MARK: - Brave response parsing (split out for tests)

    private struct BraveResponse: Decodable {
        struct WebSection: Decodable { var results: [Item]? }
        struct NewsSection: Decodable { var results: [Item]? }
        struct Item: Decodable {
            var title: String?
            var url: String?
            var description: String?
        }
        var web: WebSection?
        var news: NewsSection?
    }

    static func formatBraveResults(data: Data, query: String) throws -> AgentToolResult {
        let decoded: BraveResponse
        do {
            decoded = try JSONDecoder().decode(BraveResponse.self, from: data)
        } catch {
            throw AgentToolError.invalidArgument("Could not parse Brave Search response: \(error.localizedDescription)")
        }

        let webItems = decoded.web?.results ?? []
        let newsItems = decoded.news?.results ?? []
        let items = webItems + newsItems
        guard !items.isEmpty else {
            return AgentToolResult(
                summary: "No results for “\(query)”",
                payload: "Web search for \"\(query)\" returned no results. Try different keywords."
            )
        }

        var lines: [String] = ["Web search results for \"\(query)\":", ""]
        var references: [AgentSourceReference] = []
        for (index, item) in items.enumerated() {
            let title = condenseWhitespace(decodeHTMLEntities(stripTags(item.title ?? "")))
            let snippet = condenseWhitespace(decodeHTMLEntities(stripTags(item.description ?? "")))
            lines.append("\(index + 1). \(title.isEmpty ? "(untitled)" : title)")
            lines.append("   \(item.url ?? "")")
            if let reference = sourceReference(title: title, rawURL: item.url, toolName: "web_search") {
                references.append(reference)
            }
            if !snippet.isEmpty {
                lines.append("   \(snippet)")
            }
            lines.append("")
        }
        return AgentToolResult(
            summary: "\(items.count) result\(items.count == 1 ? "" : "s") for “\(query)”",
            payload: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            references: references
        )
    }

    // MARK: - URL validation / SSRF guard

    /// Parse + validate: http(s) scheme, non-empty host, host not in a
    /// private / loopback / link-local range. Returns nil when any
    /// check fails. Re-run on every redirect hop by RedirectGuard.
    nonisolated static func validatedPublicURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              !isBlockedHost(host) else {
            return nil
        }
        return url
    }

    /// Hostname / IP-literal denylist. DNS-rebinding is out of scope —
    /// this guards against the agent *naming* an internal target, which
    /// is the realistic prompt-injection shape ("fetch http://169.254.
    /// 169.254/latest/meta-data/").
    nonisolated static func isBlockedHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // IPv6 literal brackets from URL authority ("[::1]").
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { return true }

        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host.hasSuffix(".local") || host.hasSuffix(".internal") || host.hasSuffix(".home.arpa") {
            return true
        }

        // IPv6 literals.
        if host.contains(":") {
            if host == "::" || host == "::1" { return true }
            // Unique-local fc00::/7 and link-local fe80::/10.
            if host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb") {
                return true
            }
            // IPv4-mapped (::ffff:10.0.0.1) — check the embedded IPv4.
            if let lastChunk = host.split(separator: ":").last, lastChunk.contains(".") {
                return isBlockedIPv4(String(lastChunk))
            }
            return false
        }

        // IPv4 literals.
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) {
            return isBlockedIPv4(host)
        }

        return false
    }

    nonisolated private static func isBlockedIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return true }
        switch octets[0] {
        case 0, 10, 127:
            return true
        case 172 where (16...31).contains(octets[1]):
            return true
        case 192 where octets[1] == 168:
            return true
        case 169 where octets[1] == 254:
            return true
        default:
            return false
        }
    }

    // MARK: - HTML → readable text

    struct Extraction: Equatable {
        let title: String?
        let text: String
    }

    static func looksLikeHTML(_ body: String) -> Bool {
        let head = body.prefix(2048).lowercased()
        return head.contains("<html") || head.contains("<!doctype html") || head.contains("<body")
    }

    /// Dependency-free HTML reducer. NSAttributedString's HTML importer
    /// would be higher fidelity but drags in WebKit and must run on the
    /// main thread; a tag-stripper is plenty for feeding a model.
    static func extractReadableText(fromHTML html: String) -> Extraction {
        let title = firstMatch(in: html, pattern: "<title[^>]*>(.*?)</title>")
            .map { decodeHTMLEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        var text = html
        // Drop non-content blocks wholesale before stripping tags.
        for block in ["script", "style", "noscript", "svg", "head", "template", "iframe"] {
            text = replace(in: text, pattern: "(?is)<\(block)\\b[^>]*>.*?</\(block)>", with: " ")
        }
        text = replace(in: text, pattern: "(?s)<!--.*?-->", with: " ")

        // Structural tags become line breaks / bullets so the text
        // keeps paragraph shape.
        text = replace(in: text, pattern: "(?i)<(br|hr)\\s*/?>", with: "\n")
        text = replace(in: text, pattern: "(?i)<li\\b[^>]*>", with: "\n- ")
        text = replace(in: text, pattern: "(?i)</(p|div|li|h1|h2|h3|h4|h5|h6|tr|table|ul|ol|blockquote|section|article|header|footer|pre)>", with: "\n")
        text = replace(in: text, pattern: "(?i)<(p|h1|h2|h3|h4|h5|h6|blockquote|pre)\\b[^>]*>", with: "\n")

        text = stripTags(text)
        text = decodeHTMLEntities(text)

        // Collapse intra-line whitespace, drop empty lines beyond pairs.
        let lines = text
            .components(separatedBy: .newlines)
            .map { line in
                line.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
        var collapsed: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            collapsed.append(line)
        }
        return Extraction(
            title: (title?.isEmpty ?? true) ? nil : title,
            text: collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func stripTags(_ text: String) -> String {
        replace(in: text, pattern: "<[^>]+>", with: " ")
    }

    /// Single-line normalization for search snippets: tag-stripping
    /// leaves doubled spaces behind, and Brave descriptions may carry
    /// stray newlines.
    static func condenseWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        // Ordered array, `&amp;` strictly last — decoding it earlier
        // would turn "&amp;lt;" into "&lt;" and then into "<".
        let named: [(String, String)] = [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&apos;", "'"), ("&#39;", "'"), ("&nbsp;", " "), ("&mdash;", "—"),
            ("&ndash;", "–"), ("&hellip;", "…"), ("&copy;", "©"), ("&rsquo;", "’"),
            ("&lsquo;", "‘"), ("&rdquo;", "”"), ("&ldquo;", "“"),
            ("&amp;", "&")
        ]
        for (entity, character) in named {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        // Numeric entities: &#1234; and &#x1F600;
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let fullRange = Range(match.range, in: result),
                      let hexFlag = Range(match.range(at: 1), in: result),
                      let digits = Range(match.range(at: 2), in: result) else { continue }
                let isHex = !result[hexFlag].isEmpty
                guard let value = UInt32(result[digits], radix: isHex ? 16 : 10),
                      let scalar = Unicode.Scalar(value) else { continue }
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }
        return result
    }

    // MARK: - Plumbing

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = fetchTimeout
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    private static func redacted(_ url: URL) -> String {
        AgentNetworkSupport.redactedURLString(url)
    }

    private static func sourceReference(title: String, rawURL: String?, toolName: String) -> AgentSourceReference? {
        guard let rawURL = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty,
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return AgentSourceReference(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title,
            url: redacted(url),
            toolName: toolName
        )
    }

    private static func clampMaxChars(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return defaultMaxChars }
        return min(requested, maxMaxChars)
    }

    private static func clampSearchCount(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return defaultSearchCount }
        return min(requested, maxSearchCount)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func replace(in text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: replacement
        )
    }

    /// Every redirect hop re-runs the public-URL check; a hop onto a
    /// private host (or a non-http scheme) is dropped, which surfaces
    /// upstream as the original 3xx response → explicit error.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        static let shared = RedirectGuard()

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let target = request.url,
                  AgentWebTools.validatedPublicURL(target.absoluteString) != nil else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}
