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
    var updatesSettings: some View {
        Form {
            Section(L10n.Settings.sectionSoftwareUpdate) {
                LabeledContent(L10n.Settings.labelInstalledVersion) {
                    Text(L10n.Settings.versionAndBuild(installedVersion, installedBuild))
                        .monospacedDigit()
                }

                Text(L10n.Settings.softwareUpdateHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Bound straight to Sparkle's own preference rather than a
                // parallel @AppStorage: the update alert's checkbox writes the
                // same value, and two stores would drift the moment a user
                // touched one of them.
                Toggle(L10n.Settings.automaticUpdates, isOn: Binding(
                    get: { AppUpdateController.shared.automaticallyDownloadsUpdates },
                    set: { AppUpdateController.shared.automaticallyDownloadsUpdates = $0 }
                ))
                .disabled(!AppUpdateController.shared.canEnableAutomaticDownloads)

                Text(
                    AppUpdateController.shared.canEnableAutomaticDownloads
                        ? L10n.Settings.automaticUpdatesHelp
                        : L10n.Settings.automaticUpdatesUnavailable
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button {
                    AppUpdateController.shared.checkForUpdates()
                } label: {
                    Label(L10n.AppUpdate.checkForUpdates, systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? L10n.About.unknownValue
    }

    private var installedBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? L10n.About.unknownValue
    }

    var agentAppearanceSettings: some View {
        Form {
            agentBackgroundSelectionSection
            agentWallpaperSettingsSection

            Section(L10n.Settings.sectionAgentChatText) {
                Picker(L10n.Settings.labelFont, selection: $appState.agentChatFontID) {
                    ForEach(AgentChatFontChoice.allCases) { font in
                        Text(font.displayName).tag(font.id)
                    }
                }

                LabeledContent(L10n.Settings.labelTextSize) {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(appState.agentChatBaseFontSize) },
                                set: { appState.agentChatBaseFontSize = CGFloat($0.rounded()) }
                            ),
                            in: Double(AgentSettingsStore.chatBaseFontSizeMin)
                                ... Double(AgentSettingsStore.chatBaseFontSizeMax),
                            step: 1
                        )
                        Text("\(Int(appState.agentChatBaseFontSize.rounded())) pt")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                LabeledContent(L10n.Settings.labelLineHeight) {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(appState.agentChatLineHeightMultiple) },
                                set: { appState.agentChatLineHeightMultiple = CGFloat($0) }
                            ),
                            in: Double(AgentSettingsStore.chatLineHeightMultipleMin)
                                ... Double(AgentSettingsStore.chatLineHeightMultipleMax),
                            step: 0.05
                        )
                        Text(String(format: "%.2fx", appState.agentChatLineHeightMultiple))
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }

                Text(L10n.Settings.AgentBehavior.agentAppearanceDescription("\(Int(AgentSettingsStore.chatBaseFontSizeMin))", "\(Int(AgentSettingsStore.chatBaseFontSizeMax))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Settings.sectionFontSmoothing) {
                Toggle(L10n.Settings.toggleFontSmoothing, isOn: $appState.agentFontSmoothingEnabled)
                Text(L10n.Settings.fontSmoothingDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.Composer.inputSuggestionSettingsSectionTitle) {
                Toggle(L10n.Composer.inputSuggestionSettingsToggle, isOn: $appState.agentInputSuggestionsEnabled)
                Text(L10n.Composer.inputSuggestionSettingsFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.SpecGateSettings.sectionTitle) {
                Toggle(L10n.SpecGateSettings.detectionToggle, isOn: $appState.agentSpecGateEnabled)
                Text(L10n.SpecGateSettings.detectionFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(L10n.SpecGateSettings.enforcementToggle, isOn: $appState.agentSpecGateEnforcement)
                    .disabled(!appState.agentSpecGateEnabled)
                Text(L10n.SpecGateSettings.enforcementFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    var agentBackgroundSelectionSection: some View {
        Section {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                NoWorkspaceWallpaperCard(
                    isSelected: appState.editorSettings.windowBackgroundImagePath == nil,
                    action: clearBackgroundImage
                )

                ForEach(BuiltInWorkspaceWallpaper.all) { wallpaper in
                    BuiltInWorkspaceWallpaperCard(
                        wallpaper: wallpaper,
                        isSelected: appState.editorSettings.windowBackgroundImagePath == wallpaper.persistedPath
                    ) {
                        selectBuiltInWallpaper(wallpaper)
                    }
                }
            }
            .padding(.vertical, 2)

            LabeledContent(L10n.Settings.labelImage) {
                HStack {
                    Text(backgroundImageLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button(L10n.Settings.buttonChoose) { chooseBackgroundImage() }
                    Button(L10n.Settings.buttonClear) { clearBackgroundImage() }
                        .disabled(appState.editorSettings.windowBackgroundImagePath == nil)
                }
            }

            Picker(L10n.Settings.labelImageMode, selection: setting(\.windowBackgroundImageMode)) {
                ForEach(EditorBackgroundImageMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
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
            .disabled(appState.editorSettings.windowBackgroundImagePath == nil)
        } header: {
            Text(L10n.Settings.backgroundChoices)
        }
    }

    var backgroundImageLabel: String {
        guard let path = appState.editorSettings.windowBackgroundImagePath else {
            return L10n.Settings.noImageSelected
        }
        if let wallpaper = BuiltInWorkspaceWallpaper.wallpaper(forPersistedPath: path) {
            return wallpaper.displayName
        }
        return WorkspaceWallpaperStore.displayName(for: path)
    }

    @ViewBuilder
    var agentWallpaperSettingsSection: some View {
        Section {
            Toggle(
                L10n.Settings.toggleAgentWallpaper,
                isOn: setting(\.agentWallpaperEnabled)
            )
            .disabled(!appState.editorSettings.hasConfiguredWorkspaceWallpaper)

            LabeledContent(L10n.Settings.labelAgentWallpaperSurfaceOpacity) {
                HStack {
                    Slider(value: setting(\.agentWallpaperSurfaceOpacity), in: 0.2...1, step: 0.05)
                    Text("\(Int(appState.editorSettings.agentWallpaperSurfaceOpacity * 100))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .disabled(!appState.editorSettings.hasConfiguredAgentWallpaper)

            Toggle(
                L10n.Settings.toggleAgentWallpaperGlass,
                isOn: setting(\.agentWallpaperGlassEnabled)
            )
            .disabled(!appState.editorSettings.hasConfiguredAgentWallpaper)

            Picker(
                L10n.Settings.labelGlassMaterial,
                selection: setting(\.agentWallpaperGlassMaterial)
            ) {
                ForEach(EditorGlassMaterial.allCases) { material in
                    Text(material.displayName).tag(material)
                }
            }
            .disabled(
                !appState.editorSettings.hasConfiguredAgentWallpaper
                    || !appState.editorSettings.agentWallpaperGlassEnabled
            )

            LabeledContent(L10n.Settings.labelGlassStrength) {
                HStack {
                    Slider(value: setting(\.agentWallpaperGlassOpacity), in: 0...1, step: 0.05)
                    Text("\(Int(appState.editorSettings.agentWallpaperGlassOpacity * 100))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .disabled(
                !appState.editorSettings.hasConfiguredAgentWallpaper
                    || !appState.editorSettings.agentWallpaperGlassEnabled
            )

            Text(L10n.Settings.agentWallpaperHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(L10n.Settings.sectionAgentWallpaper)
        }
    }

    func selectBuiltInWallpaper(_ wallpaper: BuiltInWorkspaceWallpaper) {
        let previousPath = appState.editorSettings.windowBackgroundImagePath
        update(\.windowBackgroundImagePath, wallpaper.persistedPath)
        if previousPath != wallpaper.persistedPath {
            WorkspaceWallpaperStore.removeManagedWallpaper(at: previousPath)
        }
        workspaceWallpaperErrorMessage = ""
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = L10n.Settings.chooseWorkspaceWallpaperTitle
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
            let previousPath = self.appState.editorSettings.windowBackgroundImagePath
            self.isInstallingWorkspaceWallpaper = true
            self.workspaceWallpaperErrorMessage = ""
            Task {
                let result = await Task.detached(priority: .utility) {
                    Result { try WorkspaceWallpaperStore.install(from: url) }
                }.value
                self.isInstallingWorkspaceWallpaper = false
                switch result {
                case .success(let installedURL):
                    self.update(\.windowBackgroundImagePath, installedURL.path)
                    if previousPath != installedURL.path {
                        WorkspaceWallpaperStore.removeManagedWallpaper(at: previousPath)
                    }
                case .failure:
                    self.workspaceWallpaperErrorMessage = L10n.Settings.workspaceWallpaperInstallFailed
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func clearBackgroundImage() {
        let path = appState.editorSettings.windowBackgroundImagePath
        update(\.windowBackgroundImagePath, nil)
        WorkspaceWallpaperStore.removeManagedWallpaper(at: path)
        workspaceWallpaperErrorMessage = ""
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
                // 卡片自铺一层「不透明」的皮肤窗口底色，再叠半透明 panelFill。
                // panelFill 是半透明的，若直接画在系统窗口材质上，dark 模式下
                // 背后的深色会透上来，浅色皮肤（淡雾森林/水墨宣纸）的深色文字
                // 就糊在暗背景上看不见。先铺不透明底 → 每张卡片都是自成一体的
                // 皮肤缩影，文字对比度不再受设置窗口系统外观影响。
                RoundedRectangle(cornerRadius: 8)
                    .fill(skin.windowBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(skin.palette.panelFill)
                    )
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
