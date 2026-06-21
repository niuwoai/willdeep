//
//  EditorSettingsPrimaryTabs.swift
//  WillDeep
//
//  Primary Settings tabs for editor typography, visual format, and
//  workspace behavior. Split from EditorSettingsView.swift so the
//  provider/tool settings logic can evolve without pushing the root
//  Settings view back toward the file-size threshold.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension EditorSettingsView {
    var typographySettings: some View {
        Form {
            Section(L10n.Settings.sectionEditorText) {
                Picker(L10n.Settings.labelFont, selection: setting(\.fontID)) {
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

                HStack {
                    Slider(value: setting(\.lineHeightMultiple), in: 1.0...1.8, step: 0.05)
                    Text(String(format: "%.2fx", appState.editorSettings.lineHeightMultiple))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            }

            Section(L10n.Settings.sectionWorkspaceText) {
                LabeledContent(L10n.Settings.labelTextSize) {
                    HStack {
                        Slider(value: setting(\.fileTreeFontSize), in: 10...16, step: 1)
                        Text("\(Int(appState.editorSettings.fileTreeFontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                LabeledContent(L10n.Settings.labelLineHeight) {
                    HStack {
                        Slider(value: setting(\.fileTreeLineHeightMultiple), in: 1.0...2.0, step: 0.05)
                        Text(String(format: "%.2fx", appState.editorSettings.fileTreeLineHeightMultiple))
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    var appearanceSettings: some View {
        Form {
            editorFormatSections
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    var editorFormatSections: some View {
        Section {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 158, maximum: 220), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(EditorInterfaceSkin.allCases) { skin in
                    InterfaceSkinCard(
                        skin: skin,
                        isSelected: appState.editorSettings.interfaceSkinID == skin.id
                    ) {
                        selectInterfaceSkin(skin)
                    }
                }
            }
            .padding(.vertical, 4)

            Text(L10n.Settings.interfaceSkinHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(L10n.Settings.sectionInterfaceSkin)
        }

        Section(L10n.Settings.sectionColorStyle) {
            Picker(L10n.Settings.labelTheme, selection: setting(\.themeID)) {
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

        Section(L10n.Settings.sectionEditorBackground) {
            LabeledContent(L10n.Settings.labelImage) {
                HStack {
                    Text(backgroundImageLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(appState.editorSettings.windowBackgroundImagePath == nil ? .secondary : .primary)
                    Spacer(minLength: 8)
                    Button(L10n.Settings.buttonChoose) {
                        chooseBackgroundImage()
                    }
                    Button(L10n.Settings.buttonClear) {
                        update(\.windowBackgroundImagePath, nil)
                    }
                    .disabled(appState.editorSettings.windowBackgroundImagePath == nil)
                }
            }

            Picker(L10n.Settings.labelImageMode, selection: setting(\.windowBackgroundImageMode)) {
                ForEach(EditorBackgroundImageMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .disabled(appState.editorSettings.windowBackgroundImagePath == nil)

            LabeledContent(L10n.Settings.labelImageSize) {
                HStack {
                    Slider(value: setting(\.windowBackgroundImageScale), in: 0.25...3, step: 0.05)
                    Text("\(Int(appState.editorSettings.windowBackgroundImageScale * 100))%")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }
            .disabled(appState.editorSettings.windowBackgroundImagePath == nil)

            LabeledContent(L10n.Settings.labelImageOpacity) {
                HStack {
                    Slider(value: setting(\.windowBackgroundImageOpacity), in: 0...1, step: 0.05)
                    Text("\(Int(appState.editorSettings.windowBackgroundImageOpacity * 100))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }

        Section(L10n.Settings.sectionEditor) {
            Toggle(L10n.Settings.toggleShowLineNumbers, isOn: setting(\.showsLineNumbers))
            Toggle(L10n.Settings.toggleHighlightCurrentLine, isOn: setting(\.highlightsCurrentLine))
            Toggle(L10n.Settings.toggleGlassEditorBackground, isOn: setting(\.editorGlassEnabled))

            Picker(L10n.Settings.labelGlassMaterial, selection: setting(\.editorGlassMaterial)) {
                ForEach(EditorGlassMaterial.allCases) { material in
                    Text(material.displayName).tag(material)
                }
            }
            .disabled(!appState.editorSettings.editorGlassEnabled)

            LabeledContent(L10n.Settings.labelGlassStrength) {
                HStack {
                    Slider(value: setting(\.editorGlassOpacity), in: 0...1, step: 0.05)
                    Text("\(Int(appState.editorSettings.editorGlassOpacity * 100))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .disabled(!appState.editorSettings.editorGlassEnabled)

            LabeledContent(L10n.Settings.labelEditorSurface) {
                HStack {
                    Slider(value: setting(\.editorSurfaceOpacity), in: 0.25...1, step: 0.05)
                    Text("\(Int(appState.editorSettings.editorSurfaceOpacity * 100))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .disabled(!appState.editorSettings.editorGlassEnabled)
        }
    }

    var workspaceSettings: some View {
        Form {
            Section(L10n.Settings.sectionInspector) {
                Picker(L10n.Settings.labelDefaultView, selection: setting(\.preferredInspectorMode)) {
                    ForEach(EditorInspectorMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Picker(L10n.Settings.labelViewOrder, selection: setting(\.inspectorPanelOrder)) {
                    ForEach(EditorInspectorPanelOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }
            }

            Section(L10n.Settings.sectionSave) {
                Toggle(L10n.Settings.toggleTrimTrailingWhitespace, isOn: setting(\.trimsTrailingWhitespaceOnSave))
                Toggle(L10n.Settings.toggleEnsureFinalNewline, isOn: setting(\.ensuresFinalNewlineOnSave))
            }
        }
        .formStyle(.grouped)
    }

    var backgroundImageLabel: String {
        guard let path = appState.editorSettings.windowBackgroundImagePath else {
            return L10n.Settings.noImageSelected
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = L10n.Settings.chooseBackgroundImageTitle
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        // Use a sheet attached to the Settings window (or a modeless panel
        // as fallback) instead of `runModal()`. The app-modal nested run
        // loop made the SwiftUI Settings scene dismiss itself the moment
        // the panel closed — so picking an image slammed the whole Settings
        // window shut. begin/beginSheetModal keeps it open.
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            self.update(\.windowBackgroundImagePath, url.path)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func selectInterfaceSkin(_ skin: EditorInterfaceSkin) {
        var settings = appState.editorSettings
        settings.interfaceSkinID = skin.id
        settings.themeID = skin.recommendedThemeID
        appState.editorSettings = settings.normalized()
    }

    func setting<Value>(_ keyPath: WritableKeyPath<EditorSettings, Value>) -> Binding<Value> {
        Binding {
            appState.editorSettings[keyPath: keyPath]
        } set: { newValue in
            update(keyPath, newValue)
        }
    }

    func update<Value>(_ keyPath: WritableKeyPath<EditorSettings, Value>, _ value: Value) {
        var settings = appState.editorSettings
        settings[keyPath: keyPath] = value
        appState.editorSettings = settings.normalized()
    }
}

private struct InterfaceSkinCard: View {
    let skin: EditorInterfaceSkin
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                preview

                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.Settings.InterfaceSkin.name(skin))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(skin.palette.primaryText)
                            .lineLimit(1)
                        Text(L10n.Settings.InterfaceSkin.summary(skin))
                            .font(.system(size: 10))
                            .foregroundStyle(skin.palette.secondaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(skin.palette.accent)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 132, maxHeight: 132, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(skin.palette.panelFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? skin.palette.accent : skin.palette.hairline, lineWidth: isSelected ? 1.6 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Settings.InterfaceSkin.name(skin))
    }

    private var preview: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 6)
                .fill(skin.palette.controlFill)
                .frame(height: 50)
                .overlay(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(skin.palette.accent)
                                .frame(width: 7, height: 7)
                            Circle()
                                .fill(skin.palette.secondaryAccent)
                                .frame(width: 7, height: 7)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(skin.palette.secondaryText.opacity(0.28))
                                .frame(width: 38, height: 7)
                        }
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(skin.palette.secondaryText.opacity(0.46))
                                .frame(width: 50, height: 6)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(skin.palette.secondaryText.opacity(0.24))
                                .frame(width: 28, height: 6)
                        }
                    }
                    .padding(.leading, 10)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(skin.palette.hairline, lineWidth: 1)
                )

            Image(systemName: skin.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(skin.palette.accent)
                .padding(9)
        }
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
