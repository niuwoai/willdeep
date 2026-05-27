//
//  EditorTab.swift
//  VeilWriter
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

    init(id: UUID = UUID(), url: URL, content: String = "", savedContent: String? = nil, isEdited: Bool = false) {
        self.id = id
        self.url = url
        self.content = content
        self.savedContent = savedContent ?? content
        self.isEdited = isEdited
    }

    var title: String {
        url.lastPathComponent
    }
}
