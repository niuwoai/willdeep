//
//  CollaborationConnectorOAuth.swift
//  WillDeep
//
//  OAuth helpers for collaboration connectors. Secrets and tokens are kept
//  behind AgentCredentialStore references; UserDefaults only stores routing
//  metadata and short-lived state nonces.
//

import Foundation

enum CollaborationConnectorCredentialKind: String, CaseIterable {
    case clientSecret = "client-secret"
    case accessToken = "access-token"
    case refreshToken = "refresh-token"
}

struct CollaborationConnectorOAuthRequest: Equatable {
    var connector: CollaborationConnectorConfig
    var authorizationURL: URL?
    var state: String
}

struct CollaborationConnectorOAuthCallback: Equatable {
    var platform: CollaborationConnectorPlatform
    var code: String
    var state: String
    var error: String
    var errorDescription: String
}

enum CollaborationConnectorOAuthCoordinator {
    private static let pendingStatePrefix = "com.willdeep.collaborationConnectors.oauth.state."
    static let defaultRelayBaseURL = "https://fly.niuwoai.com"

    static func credentialAccount(
        platform: CollaborationConnectorPlatform,
        kind: CollaborationConnectorCredentialKind
    ) -> String {
        "collaboration/\(platform.rawValue)/\(kind.rawValue)"
    }

    static func credentialReference(
        platform: CollaborationConnectorPlatform,
        kind: CollaborationConnectorCredentialKind
    ) -> String {
        AgentCredentialStore.reference(account: credentialAccount(platform: platform, kind: kind))
    }

    static func defaultRedirectURI(for platform: CollaborationConnectorPlatform) -> String {
        "\(defaultRelayBaseURL)/oauth/\(platform.rawValue)/callback"
    }

    static func localCallbackURI(for platform: CollaborationConnectorPlatform) -> String {
        "willdeep://oauth/\(platform.rawValue)/callback"
    }

    static func pendingState(
        for platform: CollaborationConnectorPlatform,
        defaults: UserDefaults = .standard
    ) -> String {
        defaults.string(forKey: pendingStateKey(for: platform)) ?? ""
    }

    static func prepareAuthorization(
        for connector: CollaborationConnectorConfig,
        defaults: UserDefaults = .standard
    ) -> CollaborationConnectorOAuthRequest {
        let state = UUID().uuidString
        defaults.set(state, forKey: pendingStateKey(for: connector.platform))

        var prepared = connector.normalized
        if prepared.redirectURI.isEmpty {
            prepared.redirectURI = defaultRedirectURI(for: prepared.platform)
        }
        if prepared.credentialReference.isEmpty {
            prepared.credentialReference = credentialReference(platform: prepared.platform, kind: .clientSecret)
        }
        prepared.connectionState = prepared.appID.isEmpty ? .notConfigured : .ready
        prepared.updatedAt = Date()

        return CollaborationConnectorOAuthRequest(
            connector: prepared,
            authorizationURL: authorizationURL(for: prepared, state: state),
            state: state
        )
    }

    static func parseCallback(_ url: URL) -> CollaborationConnectorOAuthCallback? {
        guard url.scheme == "willdeep",
              url.host == "oauth" else {
            return nil
        }

        let pathParts = url.pathComponents.filter { $0 != "/" }
        guard pathParts.count == 2,
              pathParts[1] == "callback",
              let platform = CollaborationConnectorPlatform(rawValue: pathParts[0]) else {
            return nil
        }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return CollaborationConnectorOAuthCallback(
            platform: platform,
            code: queryValue("code", in: items),
            state: queryValue("state", in: items),
            error: queryValue("error", in: items),
            errorDescription: queryValue("error_description", in: items)
        )
    }

    @discardableResult
    static func handleCallback(_ url: URL, defaults: UserDefaults = .standard) -> Bool {
        guard let callback = parseCallback(url) else { return false }

        let expectedState = pendingState(for: callback.platform, defaults: defaults)
        var connector = CollaborationConnectorSettingsStore.load(defaults: defaults)
            .connector(for: callback.platform)
        let stateMatches = !callback.state.isEmpty && callback.state == expectedState
        let receivedCode = !callback.code.isEmpty
        let receivedError = !callback.error.isEmpty

        connector.redirectURI = connector.redirectURI.isEmpty
            ? defaultRedirectURI(for: connector.platform)
            : connector.redirectURI
        connector.credentialReference = connector.credentialReference.isEmpty
            ? credentialReference(platform: connector.platform, kind: .clientSecret)
            : connector.credentialReference
        connector.connectionState = stateMatches && receivedCode && !receivedError ? .needsReview : .notConfigured
        connector.updatedAt = Date()
        CollaborationConnectorSettingsStore.upsert(connector, defaults: defaults)

        if stateMatches {
            defaults.removeObject(forKey: pendingStateKey(for: callback.platform))
        }
        return true
    }

    static func clearCredentials(for platform: CollaborationConnectorPlatform) {
        for kind in CollaborationConnectorCredentialKind.allCases {
            AgentCredentialStore.delete(account: credentialAccount(platform: platform, kind: kind))
        }
    }

    private static func authorizationURL(
        for connector: CollaborationConnectorConfig,
        state: String
    ) -> URL? {
        guard connector.authMode == .oauth,
              !connector.appID.isEmpty,
              !connector.redirectURI.isEmpty,
              let rawURL = connector.authorizationURL,
              !rawURL.isEmpty else {
            return nil
        }

        let replacements = [
            "{app_id}": connector.appID,
            "{client_id}": connector.appID,
            "{redirect_uri}": connector.redirectURI,
            "{state}": state
        ]
        if replacements.keys.contains(where: { rawURL.contains($0) }) {
            let substituted = replacements.reduce(rawURL) { result, item in
                result.replacingOccurrences(
                    of: item.key,
                    with: item.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item.value
                )
            }
            return URL(string: substituted)
        }

        guard var components = URLComponents(string: rawURL) else { return nil }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "client_id", value: connector.appID))
        items.append(URLQueryItem(name: "redirect_uri", value: connector.redirectURI))
        items.append(URLQueryItem(name: "response_type", value: "code"))
        items.append(URLQueryItem(name: "state", value: state))
        components.queryItems = items
        return components.url
    }

    private static func pendingStateKey(for platform: CollaborationConnectorPlatform) -> String {
        pendingStatePrefix + platform.rawValue
    }

    private static func queryValue(_ name: String, in items: [URLQueryItem]) -> String {
        items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
