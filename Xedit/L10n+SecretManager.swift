import Foundation

// Strings for the secret manager (Composer lock sheet + Settings pane).
// Split out of L10n.swift to keep that façade under the 3000-line guard.
extension L10n {
    nonisolated enum SecretManager {
        static let tabTitle = String(localized: "secret-manager.tab-title", defaultValue: "Secrets")
        static let paneTitle = String(localized: "secret-manager.pane-title", defaultValue: "Secret manager")
        static let paneDescription = String(
            localized: "secret-manager.pane-description",
            defaultValue: "Values stay in the Keychain. The model only ever sees the ${secret:…} placeholder; the real value is substituted locally, at the moment a tool runs."
        )
        static let searchPlaceholder = String(
            localized: "secret-manager.search-placeholder",
            defaultValue: "Search by name or pinyin"
        )
        static let clearSearch = String(localized: "secret-manager.clear-search", defaultValue: "Clear search")
        static let noResults = String(localized: "secret-manager.no-results", defaultValue: "No secret matches this search.")
        static let rowActions = String(localized: "secret-manager.row-actions", defaultValue: "More actions")
        static let rename = String(localized: "secret-manager.rename", defaultValue: "Rename…")
        static let renameTitle = String(localized: "secret-manager.rename-title", defaultValue: "Rename secret")
        static let renameConfirm = String(localized: "secret-manager.rename-confirm", defaultValue: "Rename")
        static func renameMessage(_ a1: String) -> String {
            let template = String(
                localized: "secret-manager.rename-message",
                defaultValue: "Only the display name changes. The placeholder stays %@, so secrets already inserted into past conversations keep working."
            )
            return String(format: template, a1)
        }
        static let delete = String(localized: "secret-manager.delete", defaultValue: "Delete…")
        static let deleteTitle = String(localized: "secret-manager.delete-title", defaultValue: "Delete secret")
        static let deleteConfirm = String(localized: "secret-manager.delete-confirm", defaultValue: "Delete")
        static func deleteMessage(_ a1: String) -> String {
            let template = String(
                localized: "secret-manager.delete-message",
                defaultValue: "“%@” will be removed from the Keychain. Placeholders already inserted into past conversations will stop resolving. This cannot be undone."
            )
            return String(format: template, a1)
        }
        static let previousPage = String(localized: "secret-manager.previous-page", defaultValue: "Previous page")
        static let nextPage = String(localized: "secret-manager.next-page", defaultValue: "Next page")
        static func pageIndicator(_ a1: Int, _ a2: Int) -> String {
            let template = String(localized: "secret-manager.page-indicator", defaultValue: "Page %1$d of %2$d")
            return String(format: template, a1, a2)
        }
        static func totalCount(_ a1: Int) -> String {
            let template = String(localized: "secret-manager.total-count", defaultValue: "%d secrets")
            return String(format: template, a1)
        }
        static let addTitle = String(localized: "secret-manager.add-title", defaultValue: "Add secrets")
        static let addAction = String(localized: "secret-manager.add-action", defaultValue: "Add secret")
        static let saveAction = String(localized: "secret-manager.save-action", defaultValue: "Save")
    }
}
