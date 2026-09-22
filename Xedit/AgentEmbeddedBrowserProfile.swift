//
//  AgentEmbeddedBrowserProfile.swift
//  WillDeep
//
//  Two website data stores for the embedded browser. "My browser" is the
//  default store with the user's sign-ins and imported Chrome cookies;
//  "isolated browser" is a separate store with none of them, so ordinary
//  browsing there runs without confirmation cards. See
//  docs/EMBEDDED_BROWSER_SITE_AUTHORIZATION.md, step 4.
//

import Foundation
import WebKit

nonisolated enum AgentEmbeddedBrowserProfile: String, CaseIterable, Sendable {
    case personal
    case isolated

    /// Fixed so the isolated store keeps its own history across launches
    /// while never sharing anything with the default store.
    static let isolatedStoreIdentifier = UUID(uuidString: "6B0F3C52-8D1E-4B5A-9F1C-2A7E5D3B9C40")!
}

@MainActor
enum AgentEmbeddedBrowserDataStores {
    /// macOS 13 has no identified stores; an app-lifetime non-persistent store
    /// is just as isolated, it only forgets on quit.
    private static var legacyIsolatedStore: WKWebsiteDataStore?

    static func store(for profile: AgentEmbeddedBrowserProfile) -> WKWebsiteDataStore {
        switch profile {
        case .personal:
            return .default()
        case .isolated:
            if #available(macOS 14.0, *) {
                return WKWebsiteDataStore(forIdentifier: AgentEmbeddedBrowserProfile.isolatedStoreIdentifier)
            }
            if let legacyIsolatedStore { return legacyIsolatedStore }
            let store = WKWebsiteDataStore.nonPersistent()
            legacyIsolatedStore = store
            return store
        }
    }
}

extension AgentToolAuthorization {
    /// Hidden argument: which data store the embedded browser used when the
    /// call was registered. Execution refuses if it has changed since.
    nonisolated static let embeddedBrowserProfileArgument = "_willdeep_browser_profile"

    static func stampingEmbeddedBrowserProfile(
        toolName: String,
        arguments: [String: AgentJSONValue],
        profile: AgentEmbeddedBrowserProfile
    ) -> [String: AgentJSONValue] {
        guard toolName.hasPrefix("embedded_browser_") else { return arguments }
        var stamped = arguments
        stamped[embeddedBrowserProfileArgument] = .string(profile.rawValue)
        return stamped
    }

    /// Ordinary embedded browser actions in the isolated browser need no
    /// card: it holds none of the user's sign-ins. Uploads (local files leave
    /// the machine), consequential clicks, and anything carrying a secret
    /// placeholder (typing a saved key into a site) still ask.
    static func isolatedBrowserAllowsWithoutAsking(
        toolName: String,
        arguments: [String: AgentJSONValue]
    ) -> Bool {
        toolName.hasPrefix("embedded_browser_")
            && arguments[embeddedBrowserProfileArgument]?.stringValue() == AgentEmbeddedBrowserProfile.isolated.rawValue
            && !browserToolsRequiringPerCallApproval.contains(toolName)
            && embeddedBrowserActionConsequence(toolName: toolName, arguments: arguments) == nil
            && !arguments.values.contains { $0.stringValue()?.contains(AgentSecretStore.placeholderPrefix) == true }
    }

    static func embeddedBrowserProfileDriftMessage(
        arguments: [String: AgentJSONValue],
        currentProfile: AgentEmbeddedBrowserProfile
    ) -> String? {
        guard let stamped = arguments[embeddedBrowserProfileArgument]?.stringValue(),
              stamped != currentProfile.rawValue else { return nil }
        return "The embedded browser switched from the \(stamped) profile to the \(currentProfile.rawValue) profile after this call was authorized, so it was not run. Call the tool again."
    }
}
