import Foundation

extension AppState {
    func assessFeedbackReview(for runtime: AgentRuntime) {
        guard let review = runtime.feedbackReview, !runtime.isResponding,
              !review.isAssessing, review.assessment == nil, review.disposition == nil else { return }
        var configuration = auxiliaryBaseConfiguration(for: runtime)
        configuration.model = configuration.titleSummaryModel()
        guard !configuration.model.isEmpty else { return }
        runtime.feedbackReview?.isAssessing = true
        runtime.feedbackReview?.assessmentFailed = false
        let runtimeID = runtime.id
        runtime.feedbackAssessmentTask = Task { [weak self, weak runtime] in
            let measurement = AgentAuxiliaryRequestMeasurement()
            let collector = AgentTextCollector()
            let messages = AgentLocalModelPrompting.messagesWithLanguageInstruction(
                systemPrompt: AgentFeedbackAssessment.prompt,
                userMessages: [AgentMessage(role: .user, content: review.facts)], configuration: configuration)
            var succeeded = true
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = 60
            sessionConfiguration.timeoutIntervalForResource = 60
            let session = URLSession(configuration: sessionConfiguration)
            defer { session.invalidateAndCancel() }
            do {
                try await AgentClient(configuration: configuration, session: session).streamChat(messages: messages) { event in
                    await measurement.consume(event)
                    if case .textDelta(let text) = event { await collector.append(text) }
                }
            } catch { succeeded = false }
            let record = await measurement.record(purpose: .feedbackAssessment,
                providerID: configuration.providerID, modelID: configuration.model,
                isLocal: AgentLocalModelPrompting.isLocalProvider(configuration), succeeded: succeeded)
            guard let self else { return }
            self.recordAuxiliaryModelRequest(record, runtimeID: runtimeID)
            guard !Task.isCancelled, let runtime, !runtime.isResponding,
                  runtime.feedbackReview?.id == review.id, runtime.feedbackReview?.disposition == nil else { return }
            runtime.feedbackReview?.isAssessing = false
            let assessment = succeeded ? AgentFeedbackAssessment.parse(await collector.value) : nil
            runtime.feedbackReview?.assessment = assessment
            runtime.feedbackReview?.assessmentProvider = configuration.providerID
            runtime.feedbackReview?.assessmentModel = configuration.model
            runtime.feedbackReview?.assessmentFailed = assessment == nil
            if let assessment, let updated = runtime.feedbackReview {
                runtime.recordReviewFeedback(updated, signal: "model_assessment", source: "model", judgment: assessment.judgment)
            }
            runtime.feedbackAssessmentTask = nil
        }
    }
}
