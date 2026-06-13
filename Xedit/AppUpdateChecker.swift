//
//  AppUpdateChecker.swift
//  WillDeep
//
//  Lightweight update check for non-App-Store distribution. The server
//  publishes a small JSON document; the app only notifies the user and
//  opens the download URL, leaving installation explicit.
//

import AppKit
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
        case downloadURL
        case downloadUrl
        case download_url
        case releaseNotesURL
        case releaseNotesUrl
        case release_notes_url
        case title
        case notes
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
        version = try container.decode(String.self, forKey: .version)
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
    nonisolated static let defaultMetaURL = URL(string: "https://meta.niuwoai.com/willdeep/meta.json")!

    static func checkForUpdatesOnLaunch() {
        Task {
            await checkForUpdates()
        }
    }

    nonisolated static func checkForUpdates(
        metaURL: URL = defaultMetaURL,
        currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
        session: URLSession = .shared
    ) async {
        guard let current = AppVersion(currentVersion) else {
            return
        }

        do {
            let request = makeRequest(url: metaURL)
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return
            }
            let meta = try JSONDecoder().decode(AppUpdateMeta.self, from: data)
            guard let latest = AppVersion(meta.version), latest > current else {
                return
            }
            await presentUpdate(meta: meta, currentVersion: currentVersion)
        } catch {
            #if DEBUG
            NSLog("[WillDeep] update check failed: %@", error.localizedDescription)
            #endif
        }
    }

    nonisolated static func makeRequest(url: URL) -> URLRequest {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("WillDeep/\(appVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue(appVersion, forHTTPHeaderField: "X-App-Version")
        return request
    }

    @MainActor
    static func presentUpdate(meta: AppUpdateMeta, currentVersion: String) {
        let alert = NSAlert()
        alert.messageText = meta.title ?? L10n.AppUpdate.title(meta.version)
        alert.informativeText = informativeText(meta: meta, currentVersion: currentVersion)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.AppUpdate.download)
        if meta.releaseNotesURL != nil {
            alert.addButton(withTitle: L10n.AppUpdate.releaseNotes)
        }
        alert.addButton(withTitle: L10n.AppUpdate.later)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(meta.downloadURL)
            return
        }
        if response == .alertSecondButtonReturn, let releaseNotesURL = meta.releaseNotesURL {
            NSWorkspace.shared.open(releaseNotesURL)
        }
    }

    @MainActor
    private static func informativeText(meta: AppUpdateMeta, currentVersion: String) -> String {
        var lines = [
            L10n.AppUpdate.message(currentVersion, meta.version)
        ]
        if let minimumSystemVersion = meta.minimumSystemVersion,
           !minimumSystemVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(L10n.AppUpdate.minimumSystem(minimumSystemVersion))
        }
        if let notes = meta.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            lines.append("")
            lines.append(notes)
        }
        return lines.joined(separator: "\n")
    }
}
