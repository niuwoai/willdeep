import Foundation
import Testing
@testable import WillDeep

/// The server returns nickname/avatar only from `/customer/me`; every login
/// response carries balance without them. So a login result saved verbatim
/// blanks the profile — the "credits still show, name and picture are gone"
/// state users reported.
@Suite
@MainActor
struct SomeIMAccountProfileTests {
    private func account(
        email: String,
        nickname: String? = nil,
        avatarURL: String? = nil,
        tenantID: String? = nil,
        credits: String = "4130000000",
        profileUpdatedAt: Date? = nil
    ) -> SomeIMAccount {
        SomeIMAccount(
            email: email,
            nickname: nickname,
            avatarURL: avatarURL,
            tenantID: tenantID,
            balanceUSD: "41300",
            credits: credits,
            creditsPerUSD: 100_000,
            defaultModel: "deepseek-v4-flash",
            lastUpdatedAt: Date(),
            profileUpdatedAt: profileUpdatedAt
        )
    }

    // MARK: The reported failure

    @Test("a login response without profile fields keeps the stored name and avatar")
    func loginWithoutProfileKeepsExisting() {
        let stored = account(
            email: "rocky@example.com",
            nickname: "Rocky",
            avatarURL: "https://cdn.example.com/a.png",
            profileUpdatedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
        // What a login actually returns: email + balance, nothing else.
        let fromLogin = account(email: "rocky@example.com", credits: "5000000000")

        let merged = fromLogin.preservingProfile(from: stored)

        #expect(merged.nickname == "Rocky")
        #expect(merged.avatarURL == "https://cdn.example.com/a.png")
        #expect(merged.profileUpdatedAt == stored.profileUpdatedAt)
        // The fresh balance still wins — that half was never broken.
        #expect(merged.credits == "5000000000")
    }

    @Test("a browser login with no account block at all keeps the profile")
    func emptyAccountBlockKeepsProfile() {
        let stored = account(email: "rocky@example.com", nickname: "Rocky", avatarURL: "https://cdn.example.com/a.png")
        let blank = account(email: "", credits: "0")

        let merged = blank.preservingProfile(from: stored)

        #expect(merged.email == "rocky@example.com")
        #expect(merged.nickname == "Rocky")
        #expect(merged.avatarURL == "https://cdn.example.com/a.png")
    }

    // MARK: Account switching must not inherit

    @Test("signing in as a different person never inherits their profile")
    func differentAccountDoesNotInherit() {
        let stored = account(email: "rocky@example.com", nickname: "Rocky", avatarURL: "https://cdn.example.com/a.png")
        let other = account(email: "someone@example.com")

        let merged = other.preservingProfile(from: stored)

        #expect(merged.email == "someone@example.com")
        // Showing the previous user's avatar would be worse than showing none.
        #expect(merged.nickname == nil)
        #expect(merged.avatarURL == nil)
    }

    @Test("email comparison ignores case, so casing changes still preserve")
    func emailMatchIsCaseInsensitive() {
        let stored = account(email: "Rocky@Example.com", nickname: "Rocky")
        let fresh = account(email: "rocky@example.com")

        #expect(fresh.preservingProfile(from: stored).nickname == "Rocky")
    }

    // MARK: Fresh values win

    @Test("a response that does carry a profile overrides the stored one")
    func freshProfileWins() {
        let stored = account(email: "rocky@example.com", nickname: "Old", avatarURL: "https://cdn.example.com/old.png")
        let fresh = account(
            email: "rocky@example.com",
            nickname: "New",
            avatarURL: "https://cdn.example.com/new.png",
            profileUpdatedAt: Date()
        )

        let merged = fresh.preservingProfile(from: stored)

        #expect(merged.nickname == "New")
        #expect(merged.avatarURL == "https://cdn.example.com/new.png")
    }

    @Test("blank strings count as absent, not as a deliberate clear")
    func whitespaceIsTreatedAsMissing() {
        let stored = account(email: "rocky@example.com", nickname: "Rocky", avatarURL: "https://cdn.example.com/a.png")
        let fresh = account(email: "rocky@example.com", nickname: "   ", avatarURL: "")

        let merged = fresh.preservingProfile(from: stored)

        #expect(merged.nickname == "Rocky")
        #expect(merged.avatarURL == "https://cdn.example.com/a.png")
    }

    @Test("a first-ever login has nothing to preserve and stays as-is")
    func noPreviousAccountIsIdentity() {
        let fresh = account(email: "rocky@example.com")

        #expect(fresh.preservingProfile(from: nil) == fresh)
    }

    // MARK: Display fallback

    @Test("display name falls back to email, and is empty only when both are")
    func displayNameFallback() {
        #expect(account(email: "rocky@example.com", nickname: "Rocky").displayName == "Rocky")
        #expect(account(email: "rocky@example.com").displayName == "rocky@example.com")
        // Both blank is exactly the state the overwrite bug produced.
        #expect(account(email: "").displayName.isEmpty)
    }
}
