import Foundation

@main struct WorkspaceCloseIntentProbe {
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) throws {
            checks += 1
            guard value() else { throw NSError(domain: label, code: 1) }
        }
        var intent = AgentWorkspaceCloseIntent()
        try expect(intent.request(isDirty: false), "clean window closes")
        try expect(!intent.requiresConfirmation, "clean has no confirmation")
        try expect(!intent.request(isDirty: true), "dirty window stays open")
        let first = intent.requestID!
        try expect(intent.requiresConfirmation, "dirty requests confirmation")
        intent.continueEditing()
        try expect(!intent.requiresConfirmation, "cancel dismisses only close confirmation")
        try expect(!intent.confirmDiscard(requestID: first), "cancel revokes pending close")
        try expect(!intent.request(isDirty: true), "cancelled draft still blocks next close")
        let second = intent.requestID!
        intent.dismissPresentation()
        try expect(!intent.requiresConfirmation, "presentation may dismiss before action")
        try expect(intent.confirmDiscard(requestID: second), "explicit action survives binding dismissal")
        try expect(!intent.confirmDiscard(requestID: second), "discard cannot replay")
        try expect(intent.request(isDirty: true), "approved close can pass window delegate without clearing dirty")
        intent.abandonApprovedClose(second)
        try expect(!intent.request(isDirty: true), "failed close restores protection for unchanged editor")
        intent.continueEditing()
        try expect(intent.request(isDirty: false), "discarded clean editor closes")
        try expect(!intent.request(isDirty: true), "new dirty editing needs new confirmation")
        let third = intent.requestID!
        intent.continueEditing() // Account changes invalidate the old intent.
        try expect(!intent.confirmDiscard(requestID: third), "account change cannot consume old close intent")
        _ = intent.request(isDirty: true)
        let fourth = intent.requestID!
        try expect(!intent.confirmDiscard(requestID: third), "stale confirmation cannot approve a new request")
        try expect(intent.confirmDiscard(requestID: fourth), "current confirmation remains available")
        intent.continueEditing()
        try expect(intent.approvedRequestID == nil, "account change also revokes queued approved close")
        let result: [String: Any] = ["passed": true, "assertions": checks,
            "production_type": "AgentWorkspaceCloseIntent", "real_model_requests": 0]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self))
    }
}
