import Foundation

extension L10n {
    enum RoundtableChat {
        static let open = String(localized: "roundtable.chat.open", defaultValue: "Go to Expert Roundtable")
        static let needsReply = String(localized: "roundtable.chat.needs-reply", defaultValue: "Your input is needed. Continue in Expert Roundtable.")
        static let truncated = String(localized: "roundtable.chat.truncated", defaultValue: "Long response shown as a preview")
        static let previewHint = String(localized: "roundtable.chat.preview-hint", defaultValue: "Speech previews only. Open Expert Roundtable for the full discussion and interaction.")
        static let speaker = String(localized: "roundtable.chat.speaker", defaultValue: "Round %1$d · %2$@ · %3$@")
        static let preparing = String(localized: "roundtable.chat.preparing", defaultValue: "Preparing to speak")
        static let speaking = String(localized: "roundtable.chat.speaking", defaultValue: "Speaking")
        static let analyzing = String(localized: "roundtable.chat.analyzing", defaultValue: "Organizing stance")
        static let finished = String(localized: "roundtable.chat.finished", defaultValue: "Latest response")
    }
}
