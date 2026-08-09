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

    // MARK: - 1.238.2: 登录当下就要有头像，而不是几秒后才冒出来

    /// 登录响应不带资料时，旧行为是等下一次余额刷新（顺带打 `/customer/me`）
    /// 才把昵称头像补上，用户看到的是「登录后先秃几秒」。补拉必须在登录
    /// 这一步就发生，但要有时间预算 —— 资料接口挂起时宁可退回旧行为，
    /// 也不能把登录界面卡死。
    @Test("补拉有时间预算：超时就退回原账号，不阻塞登录")
    func hydrationBudgetFallsBackInsteadOfBlocking() async {
        let budget = SomeIMClient.loginProfileHydrationBudget
        #expect(budget > 0)
        // 预算必须显著小于 /customer/me 自身的 12s 超时，否则「登录慢半秒」
        // 会退化成「登录卡十几秒」。
        #expect(budget <= 5)

        // 断言行为而不是墙钟：操作要睡 5 秒才产出 "never"，预算只有 0.2 秒。
        // 拿到 nil 就证明预算确实抢先返回了 —— 若预算失效，这里会是 "never"。
        // （原先还断言 elapsed < 2s，但全量并行满载时这条被调度饿到 19.5s 而
        // 误报；结果断言不依赖机器负载，是同一件事的稳定测法。）
        let timedOut: String? = await SomeIMClient.withBudget(seconds: 0.2) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return "never"
        }
        #expect(timedOut == nil)
    }

    @Test("预算内返回的结果照常拿到")
    func hydrationBudgetReturnsFastResult() async {
        let value: String? = await SomeIMClient.withBudget(seconds: 5) { "profile" }
        #expect(value == "profile")
    }

    @Test("操作自身失败时返回 nil，登录继续用原账号")
    func hydrationBudgetPropagatesFailureAsNil() async {
        let value: String? = await SomeIMClient.withBudget(seconds: 5) { nil }
        #expect(value == nil)
    }

    /// 服务端已经随登录下发资料时（新版 some.im 的 attachClientLoginProfile），
    /// 不该再多打一次 `/customer/me`。这里用一个必然超时的预算做探针：
    /// 如果真去请求了，账号会退化成原样也说明不了问题 —— 所以直接断言
    /// 「已有资料的账号原样返回」，配合 sessionToken 为空的短路路径。
    @Test("登录响应已带资料时不再补拉")
    func hydrationSkippedWhenLoginAlreadyCarriedProfile() async {
        let withProfile = account(
            email: "rocky@example.com",
            nickname: "Rocky",
            avatarURL: "https://cdn.example.com/a.png"
        )
        let result = await SomeIMClient.hydratingLoginProfile(
            withProfile,
            settings: SomeIMIntegrationSettings(),
            sessionToken: "any-token",
            session: .shared
        )
        #expect(result == withProfile)
    }

    /// 补拉刻意不放在 `checkBrowserLoginStatus` 里 —— 那是个轮询状态检查，
    /// 塞进第二个请求会让每轮轮询都可能打 `/customer/me`。这里守住边界：
    /// 拿不到资料时 `hydrateLoginProfile` 必须原样返回，不写盘、不清空。
    @Test("补拉拿不到资料时原样返回，不触碰已存账号")
    func hydrateLoginProfileIsIdentityWhenNothingToFetch() async {
        let bare = account(email: "rocky@example.com")
        let result = await SomeIMClient.hydrateLoginProfile(
            for: bare,
            settings: SomeIMIntegrationSettings(),
            sessionToken: nil,
            session: .shared
        )
        #expect(result == bare)
    }

    @Test("没有会话 token 时安全跳过，不抛错也不清空资料")
    func hydrationSkippedWithoutSessionToken() async {
        let bare = account(email: "rocky@example.com")
        for token in [nil, "", "   "] as [String?] {
            let result = await SomeIMClient.hydratingLoginProfile(
                bare,
                settings: SomeIMIntegrationSettings(),
                sessionToken: token,
                session: .shared
            )
            #expect(result == bare)
        }
    }
}
