//
//  EditorInspector.swift
//  VeilWriter
//
//  Created by rocky on 2026/5/27.
//

import Foundation

enum EditorInspectorMode: String, CaseIterable, Identifiable {
    case minimap
    case structure

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimap:
            return "Minimap"
        case .structure:
            return "Structure"
        }
    }
}

struct EditorOutlineItem: Identifiable, Equatable {
    enum Kind: String {
        case type
        case function
        case property
        case section
        case key
    }

    let id = UUID()
    let title: String
    let kind: Kind
    let line: Int
    let level: Int
}

enum EditorOutlineExtractor {
    static func outline(for source: String, language: Language?) -> [EditorOutlineItem] {
        guard !source.isEmpty else { return [] }

        switch language {
        case .swift:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*(?:public\\s+|private\\s+|internal\\s+|fileprivate\\s+|open\\s+|final\\s+)*\\b(?:class|struct|enum|protocol|actor|extension)\\s+([A-Za-z_][A-Za-z0-9_]*)", kind: .type),
                OutlineSpec(pattern: "^\\s*(?:public\\s+|private\\s+|internal\\s+|fileprivate\\s+|open\\s+|static\\s+|override\\s+|mutating\\s+)*\\bfunc\\s+([A-Za-z_][A-Za-z0-9_]*)", kind: .function),
                OutlineSpec(pattern: "^\\s*(?:public\\s+|private\\s+|internal\\s+|fileprivate\\s+|open\\s+|static\\s+)*\\b(?:let|var)\\s+([A-Za-z_][A-Za-z0-9_]*)", kind: .property),
            ])
        case .javascript, .typescript:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*(?:export\\s+default\\s+|export\\s+)?class\\s+([A-Za-z_$][A-Za-z0-9_$]*)", kind: .type),
                OutlineSpec(pattern: "^\\s*(?:export\\s+)?interface\\s+([A-Za-z_$][A-Za-z0-9_$]*)", kind: .type),
                OutlineSpec(pattern: "^\\s*(?:export\\s+)?type\\s+([A-Za-z_$][A-Za-z0-9_$]*)", kind: .type),
                OutlineSpec(pattern: "^\\s*(?:export\\s+)?(?:async\\s+)?function\\s+([A-Za-z_$][A-Za-z0-9_$]*)", kind: .function),
                OutlineSpec(pattern: "^\\s*(?:export\\s+)?(?:const|let|var)\\s+([A-Za-z_$][A-Za-z0-9_$]*)\\s*=\\s*(?:async\\s*)?\\(?", kind: .function),
            ])
        case .ruby:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*(?:class|module)\\s+([A-Za-z_][A-Za-z0-9_:]*)", kind: .type),
                OutlineSpec(pattern: "^\\s*def\\s+(?:self\\.)?([A-Za-z_][A-Za-z0-9_!?=]*)", kind: .function),
            ])
        case .php:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*(?:final\\s+|abstract\\s+)?(?:class|interface|trait|enum)\\s+([A-Za-z_][A-Za-z0-9_]*)", kind: .type),
                OutlineSpec(pattern: "^\\s*(?:public\\s+|private\\s+|protected\\s+|static\\s+)*function\\s+([A-Za-z_][A-Za-z0-9_]*)", kind: .function),
            ])
        case .java:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*(?:public\\s+|private\\s+|protected\\s+|abstract\\s+|final\\s+|sealed\\s+)*\\b(?:class|interface|enum|record)\\s+([A-Za-z_][A-Za-z0-9_]*)", kind: .type),
                OutlineSpec(pattern: "^\\s*(?:public\\s+|private\\s+|protected\\s+|static\\s+|final\\s+|synchronized\\s+)*[A-Za-z_][A-Za-z0-9_<>, ?\\[\\]]+\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\(", kind: .function),
            ])
        case .go:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*func\\s+(?:\\([^)]*\\)\\s*)?([A-Za-z_][A-Za-z0-9_]*)", kind: .function),
                OutlineSpec(pattern: "^\\s*type\\s+([A-Za-z_][A-Za-z0-9_]*)\\s+(?:struct|interface)", kind: .type),
            ])
        case .html:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "<h([1-6])[^>]*>(.*?)</h\\1>", kind: .section, levelGroup: 1, titleGroup: 2),
                OutlineSpec(pattern: "<(?:section|article|main|nav|header|footer)[^>]*(?:id|class)=\"([^\"]+)\"", kind: .section),
            ], stripsHTML: true)
        case .css:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*([^@{}][^{]+)\\s*\\{", kind: .section),
            ])
        case .json:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*\"([^\"]+)\"\\s*:", kind: .key),
            ])
        case .markdown:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^(#{1,6})\\s+(.+)$", kind: .section, levelGroup: 1, titleGroup: 2),
            ])
        case .python:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*class\\s+([A-Za-z_][A-Za-z0-9_]*)", kind: .type),
                OutlineSpec(pattern: "^\\s*(?:async\\s+)?def\\s+([A-Za-z_][A-Za-z0-9_]*)", kind: .function),
            ])
        case .shell:
            return regexOutline(source, specs: [
                OutlineSpec(pattern: "^\\s*(?:function\\s+)?([A-Za-z_][A-Za-z0-9_]*)\\s*\\(\\)\\s*\\{", kind: .function),
            ])
        case .none:
            return []
        }
    }

    private struct OutlineSpec {
        let pattern: String
        let kind: EditorOutlineItem.Kind
        let levelGroup: Int?
        let titleGroup: Int

        init(
            pattern: String,
            kind: EditorOutlineItem.Kind,
            levelGroup: Int? = nil,
            titleGroup: Int = 1
        ) {
            self.pattern = pattern
            self.kind = kind
            self.levelGroup = levelGroup
            self.titleGroup = titleGroup
        }
    }

    private static func regexOutline(
        _ source: String,
        specs: [OutlineSpec],
        stripsHTML: Bool = false
    ) -> [EditorOutlineItem] {
        let lines = source.components(separatedBy: .newlines)
        var items: [EditorOutlineItem] = []

        for (index, line) in lines.enumerated() {
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)

            for spec in specs {
                guard let regex = try? NSRegularExpression(pattern: spec.pattern, options: []) else { continue }
                guard let match = regex.firstMatch(in: line, range: fullRange) else { continue }

                let titleRange = match.range(at: spec.titleGroup)
                guard titleRange.location != NSNotFound else { continue }

                var title = nsLine.substring(with: titleRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if stripsHTML {
                    title = title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                }
                guard !title.isEmpty else { continue }

                let level: Int
                if let levelGroup = spec.levelGroup {
                    let levelValue = nsLine.substring(with: match.range(at: levelGroup))
                    level = max(0, levelValue.count - 1)
                } else {
                    level = indentationLevel(for: line)
                }

                items.append(EditorOutlineItem(title: title, kind: spec.kind, line: index + 1, level: level))
                break
            }
        }

        return items
    }

    private static func indentationLevel(for line: String) -> Int {
        let prefix = line.prefix { $0 == " " || $0 == "\t" }
        let spaces = prefix.reduce(0) { total, character in
            total + (character == "\t" ? 4 : 1)
        }
        return spaces / 4
    }
}
