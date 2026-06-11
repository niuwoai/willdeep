//
//  FindReplaceScope.swift
//  WillDeep
//
//  Created by rocky on 2026/5/27.
//

import Foundation

enum FindReplaceScope: String, CaseIterable, Identifiable {
    case currentTab
    case openTabs
    case selectedFolder

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .currentTab:
            return "Current Tab"
        case .openTabs:
            return "Open Tabs"
        case .selectedFolder:
            return "Selected Folder"
        }
    }
}
