//
//  AppUpdateChecker.swift
//  WillDeep
//
//  Lightweight update metadata check for the sidebar. Sparkle owns the
//  signed download, privileged install handoff, rollback, and relaunch.
//

import Foundation

struct AppUpdateMeta: Decodable {
    let version: String
    let downloadURL: URL
    let releaseNotesURL: URL?
    let title: String?
    let notes: String?
    let minimumSystemVersion: String?

    enum CodingKeys: String, CodingKey {
        case version
        case latest_version
        case downloadURL
        case downloadUrl
        case download_url
        case releaseNotesURL
        case releaseNotesUrl
        case release_notes_url
        case title
        case notes
        case release_notes
        case minimumSystemVersion
        case minimum_system_version
    }

    nonisolated init(
        version: String,
        downloadURL: URL,
        releaseNotesURL: URL? = nil,
        title: String? = nil,
        notes: String? = nil,
        minimumSystemVersion: String? = nil
    ) {
        self.version = version
        self.downloadURL = downloadURL
        self.releaseNotesURL = releaseNotesURL
        self.title = title
        self.notes = notes
        self.minimumSystemVersion = minimumSystemVersion
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
            ?? container.decode(String.self, forKey: .latest_version)
        downloadURL = try Self.decodeURL(
            from: container,
            keys: [.downloadURL, .downloadUrl, .download_url],
            fieldName: "download_url"
        )
        releaseNotesURL = try Self.decodeOptionalURL(
            from: container,
            keys: [.releaseNotesURL, .releaseNotesUrl, .release_notes_url]
        )
        title = try container.decodeIfPresent(String.self, forKey: .title)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
            ?? container.decodeIfPresent(String.self, forKey: .release_notes)
        minimumSystemVersion = try container.decodeIfPresent(String.self, forKey: .minimumSystemVersion)
            ?? container.decodeIfPresent(String.self, forKey: .minimum_system_version)
    }

    private nonisolated static func decodeURL(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys],
        fieldName: String
    ) throws -> URL {
        for key in keys {
            guard let rawValue = try container.decodeIfPresent(String.self, forKey: key) else {
                continue
            }
            if let url = URL(string: rawValue), url.scheme != nil {
                return url
            }
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(fieldName) must be an absolute URL."
            )
        }
        throw DecodingError.keyNotFound(
            keys.first ?? .download_url,
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "\(fieldName) is required."
            )
        )
    }

    private nonisolated static func decodeOptionalURL(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) throws -> URL? {
        for key in keys {
            guard let rawValue = try container.decodeIfPresent(String.self, forKey: key) else {
                continue
            }
            if rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
            if let url = URL(string: rawValue), url.scheme != nil {
                return url
            }
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.rawValue) must be an absolute URL."
            )
        }
        return nil
    }
}

struct AppVersion: Comparable, Equatable {
    private struct Prerelease: Equatable {
        let name: String
        let number: Int
    }

    private let numbers: [Int]
    private let prerelease: Prerelease?

    nonisolated init?(_ rawValue: String) {
        var trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        let numberParts = parts[0].split(separator: ".").map(String.init)
        guard !numberParts.isEmpty else { return nil }

        var parsedNumbers: [Int] = []
        for part in numberParts {
            guard let number = Int(part), number >= 0 else { return nil }
            parsedNumbers.append(number)
        }
        while parsedNumbers.count < 3 {
            parsedNumbers.append(0)
        }
        numbers = parsedNumbers

        if parts.count > 1 {
            prerelease = Self.parsePrerelease(String(parts[1]))
        } else {
            prerelease = nil
        }
    }

    nonisolated static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        guard lhs.numbers == rhs.numbers else { return false }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return true
        case let (.some(left), .some(right)):
            return left.name == right.name && left.number == right.number
        default:
            return false
        }
    }

    nonisolated static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right {
                return left < right
            }
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case let (.some(left), .some(right)):
            return comparePrerelease(left, right) == .orderedAscending
        }
    }

    private nonisolated static func parsePrerelease(_ rawValue: String) -> Prerelease {
        let lowercased = rawValue.lowercased()
        let prefix = lowercased.prefix { !$0.isNumber }
        let suffix = lowercased.dropFirst(prefix.count)
        return Prerelease(
            name: prefix.isEmpty ? lowercased : String(prefix),
            number: Int(suffix) ?? 0
        )
    }

    private nonisolated static func comparePrerelease(_ lhs: Prerelease, _ rhs: Prerelease) -> ComparisonResult {
        if lhs.name != rhs.name {
            return lhs.name.localizedStandardCompare(rhs.name)
        }
        if lhs.number == rhs.number {
            return .orderedSame
        }
        return lhs.number < rhs.number ? .orderedAscending : .orderedDescending
    }
}

enum AppUpdateChecker {
    nonisolated static let defaultAppID = "willdeep"
    nonisolated static let defaultPlatform = "macos"
    nonisolated static let defaultChannel = "stable"

    static func fetchAvailableUpdate(
        metaURL: URL? = nil,
        currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
        session: URLSession = .shared
    ) async throws -> AppUpdateMeta? {
        guard let current = AppVersion(currentVersion) else {
            return nil
        }
        guard let url = metaURL ?? managedUpdateURL(currentVersion: currentVersion) else {
            return nil
        }
        let request = makeRequest(url: url)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            return nil
        }
        let decoded = try decodeUpdateMeta(from: data)
        guard let latest = AppVersion(decoded.version), latest > current else {
            return nil
        }
        return decoded
    }

    nonisolated static func makeRequest(url: URL) -> URLRequest {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Reuse the single source of truth so the update-check UA matches every
        // other outgoing request (`some.im/WillDeep-{version} (macOS)`).
        request.setValue(AgentNetworkSupport.userAgentHeaderValue, forHTTPHeaderField: "User-Agent")
        request.setValue(appVersion, forHTTPHeaderField: "X-App-Version")
        return request
    }

    static func managedUpdateURL(currentVersion: String) -> URL? {
        managedUpdateURL(
            currentVersion: currentVersion,
            settings: SomeIMIntegrationStore.loadSettings()
        )
    }

    static func managedUpdateURL(currentVersion: String, settings: SomeIMIntegrationSettings) -> URL? {
        guard var components = URLComponents(string: settings.normalized.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        components.path = "/api/v1/public/app-updates/latest"
        components.queryItems = [
            URLQueryItem(name: "app_id", value: defaultAppID),
            URLQueryItem(name: "platform", value: defaultPlatform),
            URLQueryItem(name: "channel", value: defaultChannel),
            URLQueryItem(name: "current_version", value: currentVersion),
        ]
        return components.url
    }

    static func managedAppcastURL(
        settings: SomeIMIntegrationSettings = SomeIMIntegrationStore.loadSettings()
    ) -> URL? {
        guard var components = URLComponents(
            string: settings.normalized.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            return nil
        }
        components.path = "/api/v1/public/app-updates/appcast.xml"
        components.queryItems = [
            URLQueryItem(name: "app_id", value: defaultAppID),
            URLQueryItem(name: "platform", value: defaultPlatform),
            URLQueryItem(name: "channel", value: defaultChannel),
        ]
        return components.url
    }

    nonisolated static func decodeUpdateMeta(from data: Data) throws -> AppUpdateMeta {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(SomeIMAppUpdateEnvelope.self, from: data),
           envelope.code == 0,
           envelope.data.updateAvailable,
           let item = envelope.data.item {
            return item
        }
        if let payload = try? decoder.decode(SomeIMAppUpdatePayload.self, from: data),
           payload.updateAvailable,
           let item = payload.item {
            return item
        }
        return try decoder.decode(AppUpdateMeta.self, from: data)
    }

}

private struct SomeIMAppUpdateEnvelope: Decodable {
    let code: Int
    let data: SomeIMAppUpdatePayload

    private enum CodingKeys: String, CodingKey {
        case code
        case data
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        data = try container.decode(SomeIMAppUpdatePayload.self, forKey: .data)
    }
}

private struct SomeIMAppUpdatePayload: Decodable {
    let updateAvailable: Bool
    let item: AppUpdateMeta?

    enum CodingKeys: String, CodingKey {
        case updateAvailable
        case update_available
        case item
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updateAvailable = try container.decodeIfPresent(Bool.self, forKey: .updateAvailable)
            ?? container.decodeIfPresent(Bool.self, forKey: .update_available)
            ?? false
        item = try container.decodeIfPresent(AppUpdateMeta.self, forKey: .item)
    }
}
