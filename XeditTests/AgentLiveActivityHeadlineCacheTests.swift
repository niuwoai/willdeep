import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentLiveActivityHeadlineCacheTests {
    private func headline(_ title: String) -> AgentActivityHeadlinePresentation {
        AgentActivityHeadlinePresentation(
            title: title,
            liveTitle: title,
            systemImage: "ellipsis.bubble"
        )
    }

    // MARK: Memoization

    @Test("the same stream state is computed once, however many views ask")
    func repeatedReadsShareOneEvaluation() {
        var cache = AgentLiveActivityHeadlineCache()
        let messageID = UUID()
        var computeCount = 0

        for _ in 0..<5 {
            _ = cache.headline(messageID: messageID, sourceLength: 100) {
                computeCount += 1
                return self.headline("Reading AgentSubagents.swift")
            }
        }

        #expect(computeCount == 1)
    }

    @Test("growth recomputes, because the tail line may have changed")
    func growthRecomputes() {
        var cache = AgentLiveActivityHeadlineCache()
        let messageID = UUID()
        var computeCount = 0

        _ = cache.headline(messageID: messageID, sourceLength: 100) {
            computeCount += 1
            return self.headline("Reading files")
        }
        _ = cache.headline(messageID: messageID, sourceLength: 220) {
            computeCount += 1
            return self.headline("Reading files and checking imports")
        }

        #expect(computeCount == 2)
    }

    // MARK: Settling

    @Test("a line that is merely growing holds its displayed text")
    func continuedLineIsHeldSteady() {
        var cache = AgentLiveActivityHeadlineCache()
        let messageID = UUID()
        let start = Date()

        let first = cache.headline(
            messageID: messageID,
            sourceLength: 100,
            now: start
        ) { self.headline("Checking the auth") }

        let second = cache.headline(
            messageID: messageID,
            sourceLength: 140,
            now: start.addingTimeInterval(0.1)
        ) { self.headline("Checking the auth flow for tenants") }

        #expect(first?.liveTitle == "Checking the auth")
        // Same line, 100ms later — the label must not re-layout yet.
        #expect(second?.liveTitle == "Checking the auth")
    }

    @Test("the held line updates once the settle interval passes")
    func continuedLineUpdatesAfterInterval() {
        var cache = AgentLiveActivityHeadlineCache()
        let messageID = UUID()
        let start = Date()

        _ = cache.headline(messageID: messageID, sourceLength: 100, now: start) {
            self.headline("Checking the auth")
        }
        let later = cache.headline(
            messageID: messageID,
            sourceLength: 140,
            now: start.addingTimeInterval(AgentLiveActivityHeadlineCache.minimumUpdateInterval + 0.01)
        ) { self.headline("Checking the auth flow for tenants") }

        #expect(later?.liveTitle == "Checking the auth flow for tenants")
    }

    @Test("a genuinely different line appears immediately, without waiting")
    func newLineIsNotDelayed() {
        var cache = AgentLiveActivityHeadlineCache()
        let messageID = UUID()
        let start = Date()

        _ = cache.headline(messageID: messageID, sourceLength: 100, now: start) {
            self.headline("Checking the auth")
        }
        // A stale status is worse than an extra layout pass.
        let switched = cache.headline(
            messageID: messageID,
            sourceLength: 160,
            now: start.addingTimeInterval(0.05)
        ) { self.headline("Now running the tests") }

        #expect(switched?.liveTitle == "Now running the tests")
    }

    @Test("a new message never inherits the previous message's headline")
    func newMessageBypassesHold() {
        var cache = AgentLiveActivityHeadlineCache()
        let start = Date()

        _ = cache.headline(messageID: UUID(), sourceLength: 100, now: start) {
            self.headline("Checking the auth")
        }
        let fresh = cache.headline(
            messageID: UUID(),
            sourceLength: 100,
            now: start.addingTimeInterval(0.05)
        ) { self.headline("Planning the change") }

        #expect(fresh?.liveTitle == "Planning the change")
    }

    @Test("reset clears the hold so the next turn starts clean")
    func resetClearsState() {
        var cache = AgentLiveActivityHeadlineCache()
        let messageID = UUID()
        let start = Date()

        _ = cache.headline(messageID: messageID, sourceLength: 100, now: start) {
            self.headline("Checking the auth")
        }
        cache.reset()
        let afterReset = cache.headline(
            messageID: messageID,
            sourceLength: 140,
            now: start.addingTimeInterval(0.05)
        ) { self.headline("Checking the auth flow") }

        #expect(afterReset?.liveTitle == "Checking the auth flow")
    }

    // MARK: Continuation test shared with the sweep animation

    @Test("continuation recognizes growth, truncation, and rejects new lines")
    func continuationDetection() {
        #expect(AgentActivitySweepLabel.isContinuation(of: "Reading", in: "Reading files"))
        #expect(AgentActivitySweepLabel.isContinuation(of: "Reading files", in: "Reading"))
        #expect(AgentActivitySweepLabel.isContinuation(of: "Reading files…", in: "Reading files and imports"))
        #expect(AgentActivitySweepLabel.isContinuation(of: "Reading", in: "Reading"))
        #expect(!AgentActivitySweepLabel.isContinuation(of: "Reading files", in: "Running tests"))
    }
}

@Suite
@MainActor
struct AgentActivityHeadlineScanTests {
    @Test("the status line comes from the tail, not a full rescan")
    func statusLineReadsFromTail() throws {
        // A long thinking phase: the line we want is at the very end, and
        // everything before it is irrelevant to the result.
        let filler = String(repeating: "earlier reasoning line\n", count: 4_000)
        let reasoning = filler + "Checking the tenant permission model"

        let headline = try #require(
            AgentActivityHeadlinePresentation.makeLive(fromReasoning: reasoning)
        )

        #expect(headline.liveTitle == "Checking the tenant permission model")
    }

    @Test("long status lines are still truncated for display")
    func longLineIsTruncated() throws {
        let reasoning = "\n" + String(repeating: "x", count: 400)

        let headline = try #require(
            AgentActivityHeadlinePresentation.makeLive(fromReasoning: reasoning)
        )

        #expect(headline.liveTitle.count <= 141)
        #expect(headline.liveTitle.hasSuffix("…"))
    }

    @Test("reasoning with no usable line yields no headline")
    func emptyReasoningYieldsNothing() {
        #expect(AgentActivityHeadlinePresentation.makeLive(fromReasoning: "") == nil)
        // Under the 4-character floor.
        #expect(AgentActivityHeadlinePresentation.makeLive(fromReasoning: "ok\n#\n") == nil)
    }

    @Test("scanning a large buffer stays fast enough for a 10Hz stream")
    func tailScanIsBounded() {
        // Guards the O(n²) regression this bound was added to remove: at the
        // old cost, 200 scans of a 400KB buffer took seconds.
        let reasoning = String(repeating: "some reasoning text here\n", count: 16_000)
            + "Verifying the migration order"

        let started = Date()
        for _ in 0..<200 {
            _ = AgentActivityHeadlinePresentation.makeLive(fromReasoning: reasoning)
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 1.0, "tail scan took \(elapsed)s for 200 iterations")
    }
}
