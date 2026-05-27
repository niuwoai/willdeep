//
//  EditorSettingsView.swift
//  VeilWriter
//
//  Preferences UI for editor appearance.
//

import SwiftUI

struct EditorSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Typography") {
                Picker("Font", selection: setting(\.fontID)) {
                    ForEach(EditorFontChoice.allCases) { font in
                        Text(font.displayName).tag(font.id)
                    }
                }

                HStack {
                    Slider(value: setting(\.fontSize), in: 10...28, step: 1)
                    Text("\(Int(appState.editorSettings.fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }

            Section("Color Style") {
                Picker("Theme", selection: setting(\.themeID)) {
                    ForEach(EditorTheme.all) { theme in
                        Text(theme.displayName).tag(theme.id)
                    }
                }

                HStack(spacing: 8) {
                    ForEach(EditorTheme.all) { theme in
                        Button {
                            update(\.themeID, theme.id)
                        } label: {
                            ThemeSwatch(theme: theme)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(theme.displayName)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Editor") {
                Toggle("Show Line Numbers", isOn: setting(\.showsLineNumbers))
                Toggle("Highlight Current Line", isOn: setting(\.highlightsCurrentLine))
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 440)
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<EditorSettings, Value>) -> Binding<Value> {
        Binding {
            appState.editorSettings[keyPath: keyPath]
        } set: { newValue in
            update(keyPath, newValue)
        }
    }

    private func update<Value>(_ keyPath: WritableKeyPath<EditorSettings, Value>, _ value: Value) {
        var settings = appState.editorSettings
        settings[keyPath: keyPath] = value
        appState.editorSettings = settings.normalized()
    }
}

private struct ThemeSwatch: View {
    let theme: EditorTheme

    var body: some View {
        HStack(spacing: 0) {
            Color(nsColor: theme.backgroundColor)
            Color(nsColor: theme.keywordColor)
            Color(nsColor: theme.stringColor)
            Color(nsColor: theme.commentColor)
            Color(nsColor: theme.numberColor)
        }
        .frame(width: 64, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(nsColor: theme.gutterTextColor).opacity(0.45), lineWidth: 1)
        )
    }
}
