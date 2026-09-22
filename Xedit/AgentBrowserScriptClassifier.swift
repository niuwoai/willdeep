//
//  AgentBrowserScriptClassifier.swift
//  WillDeep
//
//  Deterministic "is this page script read-only?" check for
//  embedded_browser_eval. A script that only walks the DOM and returns what
//  it found (querySelectorAll, textContent, getAttribute…) runs without a
//  confirmation card even on a site the user has not authorized yet. Anything
//  that could send a request, navigate, submit, change the page, write
//  storage, run dynamic code, or hide what it does falls back to the normal
//  site authorization. This is a deny-list on purpose: an unknown construct
//  is never proof of safety, so the list only ever widens what asks.
//

import Foundation

nonisolated enum AgentBrowserScriptClassifier {
    /// Scripts longer than this are not classified; they go to the normal
    /// authorization path.
    static let maximumClassifiedLength = 20_000

    private static let deniedPatterns: [(reason: String, pattern: String)] = [
        // Network
        ("network", #"\bfetch\s*\("#),
        ("network", #"XMLHttpRequest"#),
        ("network", #"sendBeacon"#),
        ("network", #"\bWebSocket\b"#),
        ("network", #"\bEventSource\b"#),
        ("network", #"serviceWorker"#),
        ("network", #"\bimportScripts\b"#),
        ("network", #"new\s+Image\b"#),
        ("network", #"\.(src|srcset|action|formAction)\s*(?<![=!<>])=(?![=>])"#),
        // Navigation and windows
        ("navigation", #"\blocation\s*(?<![=!<>])=(?![=>])"#),
        ("navigation", #"\blocation\s*\.\s*(assign|replace|reload)\b"#),
        ("navigation", #"\blocation\s*\.\s*(href|pathname|search|hash|host|hostname|protocol|port)\s*(?<![=!<>])=(?![=>])"#),
        ("navigation", #"\b(window\s*\.\s*)?open\s*\("#),
        ("navigation", #"\bhistory\s*\.\s*(pushState|replaceState|back|forward|go)\b"#),
        ("navigation", #"\bpostMessage\b"#),
        // Page actions
        ("action", #"\.\s*(submit|requestSubmit|click|focus|blur|select|showPicker|showModal)\s*\("#),
        ("action", #"\bdispatchEvent\b"#),
        ("action", #"\bexecCommand\b"#),
        ("action", #"\bnavigator\s*\.\s*(clipboard|credentials|share|permissions|geolocation|mediaDevices)\b"#),
        // DOM mutation
        ("mutation", #"\.\s*(innerHTML|outerHTML|textContent|innerText|outerText|value|checked|selected|disabled|className|nodeValue)\s*(\+|-)?(?<![=!<>])=(?![=>])"#),
        ("mutation", #"\.\s*(style|dataset|classList)\b[^;\n]*((?<![=!<>])=(?![=>])|\.\s*(add|remove|toggle|replace|setProperty)\s*\()"#),
        ("mutation", #"\b(setAttribute|removeAttribute|toggleAttribute|setAttributeNS)\b"#),
        ("mutation", #"\b(appendChild|insertBefore|removeChild|replaceChild|replaceChildren|replaceWith|insertAdjacent\w*|before|after)\s*\("#),
        ("mutation", #"\.\s*(append|prepend|remove)\s*\("#),
        ("mutation", #"\bdocument\s*\.\s*(write|writeln|open|close)\s*\("#),
        ("mutation", #"\bdesignMode\b|\bcontentEditable\b"#),
        // Storage and cookies
        ("storage", #"\bdocument\s*\.\s*cookie\s*(?<![=!<>])=(?![=>])"#),
        ("storage", #"\b(localStorage|sessionStorage)\s*\.\s*(setItem|removeItem|clear)\b"#),
        ("storage", #"\b(localStorage|sessionStorage)\s*\[[^\]]*\]\s*(?<![=!<>])=(?![=>])"#),
        ("storage", #"\bindexedDB\b|\bcaches\s*\.|\bcookieStore\b"#),
        // Dynamic code and obfuscation
        ("dynamic", #"\beval\s*\("#),
        ("dynamic", #"\bFunction\s*\("#),
        ("dynamic", #"\bset(Timeout|Interval)\s*\(\s*['"`]"#),
        ("dynamic", #"\bimport\s*\("#),
        ("dynamic", #"\bwith\s*\("#),
        ("dynamic", #"\b(atob|unescape|decodeURIComponent|fromCharCode)\s*\("#),
        ("dynamic", #"\\u[0-9a-fA-F{]|\\x[0-9a-fA-F]"#),
        ("dynamic", #"\[\s*['"`][^'"`\]]*['"`]\s*(\+|\])"#),
        ("dynamic", #"\b(window|globalThis|self|top|parent|frames|document|navigator)\s*\["#),
        ("dynamic", #"\b(Reflect|Proxy)\b|\bconstructor\b|__proto__|\bprototype\s*\.\s*\w+\s*(?<![=!<>])=(?![=>])"#),
        ("dynamic", #"\b(Worker|SharedWorker|Blob|URL\s*\.\s*createObjectURL)\b"#),
    ]

    /// nil when any rule fails to compile: a missing rule must never widen
    /// what runs without asking, so the classifier then answers "not read-only".
    static let compiled: [(reason: String, regex: NSRegularExpression)]? = {
        var rules: [(reason: String, regex: NSRegularExpression)] = []
        for item in deniedPatterns {
            guard let regex = try? NSRegularExpression(pattern: item.pattern) else { return nil }
            rules.append((item.reason, regex))
        }
        return rules
    }()

    /// The first reason the script is not read-only, or nil when it only
    /// reads the page.
    static func blockingReason(_ javascript: String) -> String? {
        let source = javascript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return "empty" }
        guard source.count <= maximumClassifiedLength else { return "too long to classify" }
        guard let compiled else { return "classifier unavailable" }
        let range = NSRange(source.startIndex..., in: source)
        for (reason, regex) in compiled where regex.firstMatch(in: source, range: range) != nil {
            return reason
        }
        return nil
    }

    static func isReadOnly(_ javascript: String) -> Bool {
        blockingReason(javascript) == nil
    }
}
