//
//  SomeIMSharedSessionMemo.swift
//  WillDeep
//
//  共享 some.im 会话的读取结果与其缓存。
//
//  从 SomeIMIntegration.swift 抽出来：那个文件越过了 3000 行的硬上限
//  （complexity_guard），而这两个类型本来就自成一组——注释里那句
//  "Split out of `SomeIMIntegrationStore`" 早就说明了它们的独立性。
//  三态语义（session / signedOut / unavailable）是这里的全部要害：
//  只有 signedOut 是关于用户的陈述，把 unavailable 当成登出，轻则让安全
//  裁判缺席、重则删掉用户配好的 provider。
//

import Foundation
import SomeIMSharedSession

/// Holds one lazily-loaded shared session until something explicitly drops it.
///
/// Split out of `SomeIMIntegrationStore` so the caching rules are testable
/// without a Keychain: the real loader is a synchronous `securityd` round trip
/// that unit tests must never touch (it would read the developer's actual
/// some.im login), so tests exercise this type with a counting stub instead.
///
/// "Nobody is logged in" is a cacheable answer, hence `loaded` is tracked
/// separately from the value rather than leaning on `value == nil`.
/// What a shared-session read established, once the fallback store has had its
/// say. Distinguishing the last two is the whole point: only one of them is a
/// statement about the user, and only one of them may drive a sign-out.
enum SomeIMSessionReadOutcome: Equatable {
    case session(SomeIMSharedSession)
    /// Confirmed: no session is stored anywhere we look.
    case signedOut
    /// The read did not complete (missing entitlement, locked Keychain, busy
    /// securityd, unreadable or newer-schema payload). Says nothing about the
    /// user; the only correct response is to try again later.
    case unavailable

    var session: SomeIMSharedSession? {
        if case .session(let session) = self { return session }
        return nil
    }

    /// Trimmed API key, empty for both empty cases. Lets callers read the key
    /// without importing `SomeIMSharedSession` — and, because it is empty for
    /// `.unavailable` too, without accidentally treating a failed read as
    /// credentials worth using.
    var apiKey: String {
        session?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

final class SomeIMSharedSessionMemo {
    /// How long an `unavailable` outcome stays cached.
    ///
    /// A real session and a confirmed sign-out are both *answers* and are
    /// memoized until something invalidates them — that is what keeps the
    /// polling readers (the mobile gateway re-reads every 400ms) off the
    /// Keychain. A failed read is not an answer, so it expires on its own and
    /// the next reader retries. Without this, one unreadable moment left the
    /// whole app believing it was signed out until a notification happened
    /// along, which is what emptied the model picker for seconds at a time.
    static let defaultUnavailableTTL: TimeInterval = 1

    private let unavailableTTL: TimeInterval
    private let now: () -> Date
    private var cached: SomeIMSessionReadOutcome?
    /// When a cached `unavailable` stops being served. Nil for real answers.
    private var unavailableExpiresAt: Date?
    /// The most recent session an actual read produced.
    ///
    /// `.unavailable` says the read did not land — it says nothing about the
    /// user, so a caller that must keep working (the safety judge, which
    /// otherwise falls back to a provider with no key and hands the decision
    /// to the user) can keep using the credentials it already saw. A confirmed
    /// sign-out clears it; `invalidate()` deliberately does not, because
    /// invalidation only means "re-read", never "signed out".
    private(set) var lastKnownGoodSession: SomeIMSharedSession?
    /// Number of times the loader actually ran. Exists for tests to assert the
    /// Keychain is not being re-read on every access.
    private(set) var loadCount = 0

    init(
        unavailableTTL: TimeInterval = SomeIMSharedSessionMemo.defaultUnavailableTTL,
        now: @escaping () -> Date = Date.init
    ) {
        self.unavailableTTL = unavailableTTL
        self.now = now
    }

    func value(loading load: () -> SomeIMSessionReadOutcome) -> SomeIMSessionReadOutcome {
        if let cached {
            if cached != .unavailable { return cached }
            if let unavailableExpiresAt, now() < unavailableExpiresAt { return cached }
        }
        let outcome = load()
        cached = outcome
        unavailableExpiresAt = outcome == .unavailable
            ? now().addingTimeInterval(unavailableTTL)
            : nil
        switch outcome {
        case .session(let session):
            lastKnownGoodSession = session
        case .signedOut:
            // The only outcome that is a statement about the user.
            lastKnownGoodSession = nil
        case .unavailable:
            // A failed read must not erase what we already know.
            break
        }
        loadCount += 1
        return outcome
    }

    func invalidate() {
        cached = nil
        unavailableExpiresAt = nil
    }

    /// Drop the remembered session. Only sign-out should call this.
    func forgetLastKnownGoodSession() {
        lastKnownGoodSession = nil
    }
}
