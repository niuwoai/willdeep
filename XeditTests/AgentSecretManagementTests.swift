import Foundation
import Testing
@testable import WillDeep

/// Secret search / pagination rules and the new destructive store paths.
///
/// The store writes through `AgentCredentialStore`, which under XCTest keeps
/// everything in an in-memory dictionary — no real Keychain item is created
/// or deleted by these tests.
@Suite
@MainActor
struct AgentSecretManagementTests {
    // MARK: Search

    @Test("search matches label and identifier regardless of case, spacing or width")
    func searchNormalizesBothSides() {
        let secret = AgentSavedSecret(identifier: "openai-api-key", label: "OpenAI API Key", updatedAt: .distantPast)

        #expect(AgentSecretSearch.matches(secret, normalizedQuery: AgentSecretSearch.normalized("api key")))
        #expect(AgentSecretSearch.matches(secret, normalizedQuery: AgentSecretSearch.normalized("APIKEY")))
        #expect(AgentSecretSearch.matches(secret, normalizedQuery: AgentSecretSearch.normalized("openai-api")))
        #expect(!AgentSecretSearch.matches(secret, normalizedQuery: AgentSecretSearch.normalized("anthropic")))
    }

    @Test("a Chinese label is searchable by full pinyin and by initials")
    func chineseLabelMatchesPinyin() {
        let secret = AgentSavedSecret(identifier: "secret-1", label: "生产数据库密码", updatedAt: .distantPast)

        #expect(AgentSecretSearch.matches(secret, normalizedQuery: AgentSecretSearch.normalized("shengchan")))
        #expect(AgentSecretSearch.matches(secret, normalizedQuery: AgentSecretSearch.normalized("scsjkmm")))
        // Still matches the characters themselves.
        #expect(AgentSecretSearch.matches(secret, normalizedQuery: AgentSecretSearch.normalized("数据库")))
        #expect(!AgentSecretSearch.matches(secret, normalizedQuery: AgentSecretSearch.normalized("ceshi")))
    }

    @Test("pinyin terms are empty for labels with no Han characters")
    func asciiLabelsSkipPinyin() {
        let terms = AgentSecretSearch.pinyinTerms(for: "Stripe live key")

        #expect(terms.full.isEmpty)
        #expect(terms.initials.isEmpty)
    }

    @Test("an empty query keeps every secret")
    func emptyQueryDoesNotFilter() {
        let secrets = [
            AgentSavedSecret(identifier: "a", label: "A", updatedAt: .distantPast),
            AgentSavedSecret(identifier: "b", label: "B", updatedAt: .distantPast),
        ]

        #expect(AgentSecretSearch.filter(secrets, query: "   ").count == 2)
    }

    // MARK: Pagination

    @Test("pagination reports at least one page and clamps out-of-range indices")
    func paginationBounds() {
        #expect(AgentSecretSearch.pageCount(itemCount: 0) == 1)
        #expect(AgentSecretSearch.pageCount(itemCount: 20, pageSize: 20) == 1)
        #expect(AgentSecretSearch.pageCount(itemCount: 21, pageSize: 20) == 2)
        #expect(AgentSecretSearch.clampedPageIndex(9, itemCount: 21, pageSize: 20) == 1)
        #expect(AgentSecretSearch.clampedPageIndex(-3, itemCount: 21, pageSize: 20) == 0)
    }

    @Test("a page returns its own slice, and the last page may be short")
    func pageSlicing() {
        let items = Array(1...25)

        #expect(AgentSecretSearch.page(items, pageIndex: 0, pageSize: 20).count == 20)
        #expect(AgentSecretSearch.page(items, pageIndex: 1, pageSize: 20) == Array(21...25))
        // Beyond the end clamps back onto the last page instead of returning
        // nothing, so a shrinking list cannot strand the user on a blank page.
        #expect(AgentSecretSearch.page(items, pageIndex: 7, pageSize: 20) == Array(21...25))
        #expect(AgentSecretSearch.page([Int](), pageIndex: 0, pageSize: 20).isEmpty)
    }

    // MARK: Store mutations

    @Test("deleting a secret removes it from the list and stops resolving its placeholder")
    func deleteRemovesValueAndIndexEntry() {
        let label = "delete-me-\(UUID().uuidString.prefix(6))"
        guard let placeholder = AgentSecretStore.saveSecret("s3cr3t", label: label) else {
            Issue.record("saving the secret under test failed")
            return
        }
        let identifier = AgentSecretStore.normalizedAlias(label)
        #expect(AgentSecretStore.savedSecrets().contains { $0.identifier == identifier })

        AgentSecretStore.deleteSecret(identifier: identifier)

        #expect(!AgentSecretStore.savedSecrets().contains { $0.identifier == identifier })
        // An unresolvable placeholder is left verbatim rather than emptied.
        #expect(AgentSecretStore.resolvePlaceholders(in: placeholder).secretValues.isEmpty)
    }

    @Test("renaming changes the label only, so existing placeholders keep resolving")
    func renameKeepsIdentifierAndValue() {
        let label = "rename-me-\(UUID().uuidString.prefix(6))"
        guard let placeholder = AgentSecretStore.saveSecret("v4lue", label: label) else {
            Issue.record("saving the secret under test failed")
            return
        }
        let identifier = AgentSecretStore.normalizedAlias(label)

        #expect(AgentSecretStore.renameSecret(identifier: identifier, label: "生产密钥"))

        let renamed = AgentSecretStore.savedSecrets().first { $0.identifier == identifier }
        #expect(renamed?.label == "生产密钥")
        #expect(renamed?.placeholder == placeholder)
        #expect(AgentSecretStore.resolvePlaceholders(in: placeholder).text == "v4lue")

        AgentSecretStore.deleteSecret(identifier: identifier)
    }

    @Test("renaming an unknown or blank target is refused rather than creating a ghost row")
    func renameRejectsUnknownTarget() {
        #expect(!AgentSecretStore.renameSecret(identifier: "no-such-secret-\(UUID().uuidString)", label: "X"))

        let label = "blank-rename-\(UUID().uuidString.prefix(6))"
        _ = AgentSecretStore.saveSecret("value", label: label)
        let identifier = AgentSecretStore.normalizedAlias(label)

        #expect(!AgentSecretStore.renameSecret(identifier: identifier, label: "   "))
        #expect(AgentSecretStore.savedSecrets().first { $0.identifier == identifier }?.label == label)

        AgentSecretStore.deleteSecret(identifier: identifier)
    }
}
