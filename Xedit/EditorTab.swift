//
//  EditorTab.swift
//  WillDeep
//
//  Created by rocky on 2026/5/27.
//

import Foundation

struct EditorTab: Identifiable, Equatable {
    let id: UUID
    var url: URL
    var content: String
    var savedContent: String
    var isEdited: Bool
    var isUntitled: Bool
    var syntaxHighlightingSelection: SyntaxHighlightingSelection
    var contentRevision: Int
    var savedContentRevision: Int

    init(id: UUID = UUID(), url: URL, content: String = "", savedContent: String? = nil, isEdited: Bool = false, isUntitled: Bool = false, syntaxHighlightingSelection: SyntaxHighlightingSelection = .automatic) {
        self.id = id
        self.url = url
        self.content = content
        self.savedContent = savedContent ?? content
        self.isEdited = isEdited
        self.isUntitled = isUntitled
        self.syntaxHighlightingSelection = syntaxHighlightingSelection
        self.contentRevision = 0
        self.savedContentRevision = 0
    }

    var title: String {
        isUntitled ? "Untitled" : url.lastPathComponent
    }
}
