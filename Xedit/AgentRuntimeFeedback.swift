import Foundation

extension AgentRuntime {
    /// Retire the previous card without inventing a human rating. Remember an
    /// in-flight turn too, so queued input cannot resurrect its card at finish.
    func dismissFeedbackReviewForNewInput() {
        feedbackAssessmentTask?.cancel()
        feedbackAssessmentTask = nil
        if feedbackReview != nil { feedbackReview = nil }
        feedbackReviewSupersededTurnID = feedbackTurnID
    }

    func recordFeedback(_ signal: String, configure: (inout AgentFeedbackEvent) -> Void = { _ in }) {
        var event = AgentFeedbackEvent(sessionID: id, signal: signal)
        event.runID = feedbackRunID
        event.turnID = feedbackTurnID
        event.provider = feedbackProvider
        event.model = feedbackModel
        configure(&event)
        feedbackLedger.record(event)
    }

    func beginFeedbackRun(turnID: UUID, provider: String, model: String) {
        guard feedbackTurnID != turnID else { return }
        if feedbackRunID != nil { endFeedbackRun(reason: "replaced") }
        dismissFeedbackReviewForNewInput()
        feedbackReviewSupersededTurnID = nil
        feedbackBudgetStopReason = nil
        executionEvidenceTrace = AgentExecutionTrace.current
        feedbackRunID = executionEvidenceTrace?.seed.runID ?? UUID()
        feedbackTurnID = turnID
        feedbackProvider = provider
        feedbackModel = model
        executionEvidenceTrace?.record("started") { $0.runtimeParameters = runtimeParameters }
        // History belongs to earlier runs. Only new/pending calls may settle
        // into this run's denominator, even when the whole array publishes.
        feedbackRecordedTools = Set(toolCalls.filter { $0.status.isTerminal }.map(\.id))
        feedbackHistoricalToolIDs = feedbackRecordedTools
        recordFeedback("run_started") {
            $0.runtimeParameters = runtimeParameters
            $0.runtimeParametersSha256 = runtimeParameters?.fingerprint
        }
    }

    func endFeedbackRun(reason: String) {
        guard feedbackRunID != nil else { return }
        let reason = reason == "finished" ? (feedbackBudgetStopReason ?? reason) : reason
        if var budget = currentGoal?.continuationBudget, budget.activeElapsedSeconds != nil {
            budget.activeElapsedSeconds = budget.elapsed(at: Date())
            budget.segmentStartedAt = nil
            currentGoal?.continuationBudget = budget
        }
        if let runID = feedbackRunID, let turnID = feedbackTurnID,
           turnID != feedbackReviewSupersededTurnID {
            let calls = toolCalls.filter { feedbackRecordedTools.contains($0.id) && !feedbackHistoricalToolIDs.contains($0.id) }
            feedbackReview = AgentFeedbackReview(id: runID, turnID: turnID,
                provider: feedbackProvider, model: feedbackModel,
                parameterFingerprint: runtimeParameters?.fingerprint,
                toolSuccesses: calls.filter { $0.status == .succeeded }.count,
                toolFailures: calls.filter { $0.status == .failed }.count, stopReason: reason)
        }
        recordFeedback("run_finished") {
            $0.stopReason = reason
            // Native completion is not an independently rerun verifier result.
            $0.verification = "unverified"
        }
        executionEvidenceTrace?.record("finished") {
            $0.status = reason
            $0.runtimeParameters = runtimeParameters
        }
        executionEvidenceTrace = nil
        feedbackPreviousTurnID = feedbackTurnID
        feedbackRunID = nil
        feedbackTurnID = nil
    }

    func recordHumanDisposition(_ disposition: AgentFeedbackReview.Disposition) {
        guard var review = feedbackReview, review.disposition == nil else { return }
        review.disposition = disposition
        feedbackAssessmentTask?.cancel()
        feedbackAssessmentTask = nil
        feedbackReview = review
        recordReviewFeedback(review, signal: "human_disposition", source: "human", judgment: disposition.rawValue)
    }

    func recordReviewFeedback(_ review: AgentFeedbackReview, signal: String, source: String, judgment: String) {
        recordFeedback(signal) {
            $0.runID = review.id
            $0.turnID = review.turnID
            $0.provider = review.provider
            $0.model = review.model
            $0.runtimeParametersSha256 = review.parameterFingerprint
            $0.judgment = judgment
            $0.judgmentSource = source
            $0.confidence = source == "model" ? review.assessment?.confidence : nil
            $0.reasonCode = source == "model" ? review.assessment?.reasonCode : nil
            $0.assessmentProvider = source == "model" ? review.assessmentProvider : nil
            $0.assessmentModel = source == "model" ? review.assessmentModel : nil
            $0.assessmentPromptSha256 = source == "model" ? AgentFeedbackAssessment.promptFingerprint : nil
        }
    }

    func recordFeedbackToolResults() {
        guard feedbackRunID != nil else { return }
        for call in toolCalls where call.status == .succeeded || call.status == .failed {
            guard !localPanelPreviewCallIDs.contains(call.id),
                  feedbackRecordedTools.insert(call.id).inserted else { continue }
            recordFeedback(call.status == .succeeded ? "tool_succeeded" : "tool_failed") {
                $0.tool = call.toolName
                $0.errorClass = call.status == .failed ? "tool_error" : nil
            }
        }
    }

    func installInputSuggestion(_ text: String, provider: String?, model: String?) {
        inputSuggestion = text
        feedbackSuggestionID = UUID()
        feedbackSuggestionText = text
        feedbackSuggestionShownAt = Date()
        feedbackSuggestionAccepted = false
        feedbackSuggestionProvider = provider
        feedbackSuggestionModel = model
        recordSuggestionFeedback("suggestion_shown")
    }

    func acceptInputSuggestion() {
        guard feedbackSuggestionText != nil else { clearInputSuggestion(); return }
        recordSuggestionFeedback("suggestion_accepted")
        feedbackSuggestionAccepted = true
        inputSuggestion = nil
        inputSuggestionTask?.cancel()
        inputSuggestionTask = nil
        inputSuggestionEpoch = UUID()
    }

    func settleInputSuggestion(sent: String) {
        guard let suggested = feedbackSuggestionText else { return }
        let signal: String
        let normalized = suggested.trimmingCharacters(in: .whitespacesAndNewlines)
        let submitted = sent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !feedbackSuggestionAccepted { signal = "suggestion_ignored_typed" }
        else if normalized == submitted { signal = "suggestion_sent_verbatim" }
        else if (!normalized.isEmpty && submitted.contains(normalized)) ||
            AgentFeedbackEvent.distance(normalized, submitted).map({ $0 <= max(normalized.unicodeScalars.count, 1) / 2 }) == true { signal = "suggestion_sent_edited" }
        else { signal = "suggestion_sent_rewritten" }
        recordSuggestionFeedback(signal, sent: sent)
        resetSuggestionFeedback()
    }

    func dismissInputSuggestion() { clearInputSuggestion(outcome: "suggestion_dismissed") }

    func recordSuggestionFeedback(_ signal: String, sent: String? = nil) {
        guard let text = feedbackSuggestionText else { return }
        recordFeedback(signal) {
            $0.suggestionID = feedbackSuggestionID
            $0.provider = feedbackSuggestionProvider
            $0.model = feedbackSuggestionModel
            $0.textHash = AgentFeedbackEvent.hash(text)
            $0.textLen = text.unicodeScalars.count
            $0.promptBundle = "input_suggestion@" + String(AgentFeedbackEvent.hash(AgentInputSuggestion.systemPrompt).prefix(12))
            $0.dwellMS = feedbackSuggestionShownAt.map { Int(Date().timeIntervalSince($0) * 1000) }
            $0.sentHash = sent.map(AgentFeedbackEvent.hash)
            $0.sentLen = sent?.unicodeScalars.count
            $0.editDistance = sent.flatMap { AgentFeedbackEvent.distance(text, $0) }
        }
    }

    func resetSuggestionFeedback() {
        feedbackSuggestionID = nil
        feedbackSuggestionText = nil
        feedbackSuggestionShownAt = nil
        feedbackSuggestionAccepted = false
    }
}
