//
//  AgentSubagentHostedModelFallback.swift
//  WillDeep
//
//  What to do when a hosted worker chain answers `model_not_configured`.
//
//  `hostedTradeIDs` claims a trade's job prompt lives on a some.im virtual
//  model (`someim-32b-<trade>`). That claim is a snapshot of the relay taken
//  by hand — `AgentSubagentJobPrompts` says so in as many words — so it goes
//  stale the moment a chain is retired, renamed, or never finishes rolling
//  out. When it does, the gateway answers `model_not_configured` and the
//  spawn dies: the trade is listed in the UI, the model picks it, and the
//  user gets "subagent failed" for a reason that has nothing to do with the
//  task.
//
//  A stale roster should cost a retry, not the run. One re-run on a concrete
//  model that always exists turns a hard failure into a slower success, and
//  the report carries a line saying which model actually answered so a stale
//  entry stays visible instead of being papered over.
//
//  Deliberately narrow: only the hosted virtual model is retried this way,
//  and only for this one error. A worker that fails on its own merits, or a
//  model the user chose explicitly, is not silently swapped underneath them.
//

import Foundation

nonisolated enum AgentSubagentHostedModelFallback {
    /// Concrete model every some.im account can reach. Not a virtual `someim-*`
    /// chain — the whole point is to leave the layer that just failed.
    static let fallbackModel = "deepseek-v4-flash"

    /// Gateway error body for a virtual model with no chain behind it. Matched
    /// as a substring because it arrives wrapped in whatever envelope the
    /// provider layer put around it (`HTTP 400: {"error":…}`).
    static let notConfiguredMarker = "model_not_configured"

    /// Whether `error` is the gateway saying the model does not exist.
    static func isModelNotConfigured(_ error: Error) -> Bool {
        error.localizedDescription
            .lowercased()
            .contains(notConfiguredMarker)
    }

    /// The model to retry a failed hosted spawn on, or nil to let the failure
    /// stand.
    ///
    /// - `attemptedModel` is what the child actually ran with.
    /// - `hostedModel` is the trade's declared virtual model; nil means the
    ///   trade never claimed hosting, so this error came from somewhere else
    ///   and swapping the model would be guesswork.
    static func retryModel(
        afterError error: Error,
        attemptedModel: String,
        hostedModel: String?
    ) -> String? {
        guard isModelNotConfigured(error) else { return nil }
        guard let hostedModel, attemptedModel == hostedModel else { return nil }
        // Already on the fallback: the account cannot reach it either, and a
        // second identical attempt just doubles the wait before the same error.
        guard attemptedModel != fallbackModel else { return nil }
        return fallbackModel
    }

    /// Line appended to the worker's report so a stale `hostedTradeIDs` entry
    /// surfaces in the transcript instead of only in the debug log.
    static func fallbackNote(hostedModel: String, ranOn: String) -> String {
        """

        (WillDeep: `\(hostedModel)` is not provisioned on the relay right now \
        (`model_not_configured`), so this worker ran on `\(ranOn)` instead. \
        The trade's entry in `hostedTradeIDs` is stale.)
        """
    }
}
