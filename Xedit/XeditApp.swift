//
//  XeditApp.swift
//  Xedit
//
//  Created by rocky on 2026/5/27.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@main
struct XeditApp: App {
    var body: some Scene {
        DocumentGroup(editing: .itemDocument, migrationPlan: XeditMigrationPlan.self) {
            ContentView()
        }
    }
}

extension UTType {
    static var itemDocument: UTType {
        UTType(importedAs: "com.example.item-document")
    }
}

struct XeditMigrationPlan: SchemaMigrationPlan {
    static var schemas: [VersionedSchema.Type] = [
        XeditVersionedSchema.self,
    ]

    static var stages: [MigrationStage] = [
        // Stages of migration between VersionedSchema, if required.
    ]
}

struct XeditVersionedSchema: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] = [
        Item.self,
    ]
}
