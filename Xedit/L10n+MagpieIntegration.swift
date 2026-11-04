import Foundation

extension L10n {
    enum MagpieIntegration {
        static let managed = String(localized: "magpie.managed", defaultValue: "Managed by Magpie · New sessions", table: "MagpieIntegration")
        static let refreshing = String(localized: "magpie.refreshing", defaultValue: "Refreshing Magpie connection…", table: "MagpieIntegration")
        static let disconnected = String(localized: "magpie.disconnected", defaultValue: "This session’s Magpie connection is disconnected. Reconnect in Magpie or choose another provider.", table: "MagpieIntegration")
        static let conflict = String(localized: "magpie.conflict", defaultValue: "The Magpie integration ID conflicts with a saved provider. Choose another provider or remove the conflicting entry in Settings.", table: "MagpieIntegration")
        static func invalid(_ category: String) -> String {
            String(format: String(localized: "magpie.invalid", defaultValue: "The Magpie connection is invalid (%@). Reconnect in Magpie or choose another provider.", table: "MagpieIntegration"), category)
        }
    }
}

extension AgentMagpieIntegration.Failure: LocalizedError {
    var errorDescription: String? {
        switch code {
        case .disconnected: return L10n.MagpieIntegration.disconnected
        case .conflict: return L10n.MagpieIntegration.conflict
        default: return L10n.MagpieIntegration.invalid(code.rawValue)
        }
    }
}
