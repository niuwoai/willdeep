import Foundation

/// Says out loud what switching models mid-conversation costs.
///
/// Providers key their prompt cache on the model, so changing it throws the
/// cache away and the next request prefills the whole history cold. On a
/// small conversation nobody notices. On a large one it is the difference
/// between waiting six seconds and waiting a minute and a half — and the
/// user has no way to connect the two events, because the switch looks free
/// and the slowness arrives one turn later.
///
/// Calibrated on a real session: 578k tokens with a 99% cache hit returned
/// its first token in 5.1s; the very next request, same conversation, first
/// one after the switch, 586k tokens with **zero** cache hit, took 85.1s.
/// A cold request of 164k tokens the same morning took 4.3s, which is why
/// the floor sits well above that — below it there is nothing worth saying.
///
/// Deliberately no predicted duration. The penalty depends on the provider's
/// prefill throughput, and a number we cannot stand behind would be worse
/// than the plain fact.
nonisolated enum AgentModelSwitchCachePolicy {
    /// Context size above which the cold prefill stops hiding inside ordinary
    /// variance. Under it the notice is noise.
    static let warningTokenThreshold = 200_000

    /// The extra sentence appended to the "model changed" divider, or nil
    /// when the switch is cheap enough to stay quiet about.
    ///
    /// `usedTokens` should come from `providerAnchoredUsedTokens` — the
    /// provider's own `prompt_tokens`, not a local character estimate, which
    /// under-reads badly enough to put a real 586k conversation below the
    /// threshold.
    static func cacheWarning(usedTokens: Int?) -> String? {
        guard let usedTokens, usedTokens >= warningTokenThreshold else { return nil }
        return L10n.AgentModelPicker.modelChangedCacheWarning(approximateTokens(usedTokens))
    }

    /// "586k" / "1.2M". Rounded on purpose: the point is the order of
    /// magnitude, and an exact figure invites the reader to check it against
    /// a gauge that is itself an estimate past the last provider reading.
    static func approximateTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
        return "\(Int((Double(tokens) / 1_000).rounded()))k"
    }
}
