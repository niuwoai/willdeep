import Foundation

extension L10n.About {
    static let authorHomepage = String(localized: "about.author-homepage", defaultValue: "Author homepage · 83d.me")
    static let otherApps = String(localized: "about.other-apps", defaultValue: "More apps by Rocky")
    static let otherAppsSummary = String(localized: "about.other-apps-summary", defaultValue: "A small shelf of sibling macOS apps from the 83d release catalog.")
    static let summary = String(localized: "about.summary", defaultValue: "A native macOS agent workspace for inspecting projects, using tools, and turning tasks into verifiable deliverables.")

    enum App {
        static let qTermName = String(localized: "about.app.qterm.name", defaultValue: "QTerm")
        static let qTermSummary = String(localized: "about.app.qterm.summary", defaultValue: "A lightweight terminal with tabs, SSH, and AI-friendly tooling.")
        static let timeBillName = String(localized: "about.app.timebill.name", defaultValue: "TimeBill")
        static let timeBillSummary = String(localized: "about.app.timebill.summary", defaultValue: "Time tracking and billing companion.")
        static let qPicName = String(localized: "about.app.qpic.name", defaultValue: "QPic")
        static let qPicSummary = String(localized: "about.app.qpic.summary", defaultValue: "Screenshots, image editing, and upload sharing.")
        static let qMarkViewName = String(localized: "about.app.qmarkview.name", defaultValue: "QMarkView")
        static let qMarkViewSummary = String(localized: "about.app.qmarkview.summary", defaultValue: "Clean Markdown reading.")
        static let qEchoName = String(localized: "about.app.qecho.name", defaultValue: "QEcho")
        static let qEchoSummary = String(localized: "about.app.qecho.summary", defaultValue: "AI voice input and text polishing.")
        static let qMailMateName = String(localized: "about.app.qmailmate.name", defaultValue: "QMailMate")
        static let qMailMateSummary = String(localized: "about.app.qmailmate.summary", defaultValue: "AI email writing, triage, summaries, and replies.")
        static let qNoteName = String(localized: "about.app.qnote.name", defaultValue: "QNote")
        static let qNoteSummary = String(localized: "about.app.qnote.summary", defaultValue: "Light notes and Markdown writing.")
    }
}
