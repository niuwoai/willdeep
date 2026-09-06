import Foundation

extension L10n {
    enum StopLifecycle {
        static let behaviorLabel = String(localized: "stop-lifecycle.behavior-label", defaultValue: "When response stops")
        static let independent = String(localized: "stop-lifecycle.independent", defaultValue: "Keep independently; stop this process separately")
        static let turnOwned = String(localized: "stop-lifecycle.turn-owned", defaultValue: "Stop with its originating turn")
        static func status(pendingLocal: Int, stoppedLocal: Int, managedRequested: Int, retained: Int) -> String {
            var parts = [L10n.Composer.stopped]
            if pendingLocal > 0 {
                parts.append(String(format: String(localized: "stop-lifecycle.pending", defaultValue: "Stopping %lld local process(es)…"), pendingLocal))
            }
            if stoppedLocal > 0 {
                parts.append(String(format: String(localized: "stop-lifecycle.stopped", defaultValue: "%lld local process(es) have exited."), stoppedLocal))
            }
            if managedRequested > 0 {
                parts.append(String(format: String(localized: "stop-lifecycle.managed", defaultValue: "Cancellation requested for %lld managed task(s); remote process exit is not confirmed."), managedRequested))
            }
            if retained > 0 {
                parts.append(String(format: String(localized: "stop-lifecycle.retained", defaultValue: "%lld independent process(es) were left untouched."), retained))
            }
            return parts.joined(separator: " ")
        }
    }
}
