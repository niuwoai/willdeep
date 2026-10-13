import Foundation

extension L10n {
    nonisolated enum TurnProcess {
        static func messages(_ count: Int) -> String {
            String(format: String(localized: "turn-process.messages", defaultValue: "Process · %d messages", table: "TurnProcess"), count)
        }
    }
}
