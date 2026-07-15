//
//  DesktopPetSettingsSection.swift
//  WillDeep
//

import SwiftUI

enum DesktopPetSettingsDesign {
    static let bodyFontSize: CGFloat = 14
    static let appearanceNameMinimumHeight: CGFloat = 36

    static let bodyFont = Font.system(size: bodyFontSize)
    static let emphasizedBodyFont = Font.system(size: bodyFontSize, weight: .semibold)
}

struct DesktopPetSettingsPage: View {
    var body: some View {
        Form {
            Section {
                DesktopPetSettingsSection()
            } header: {
                Text(L10n.DesktopPet.settingsSectionTitle)
                    .font(DesktopPetSettingsDesign.emphasizedBodyFont)
                    .textCase(nil)
            }
        }
        .formStyle(.grouped)
    }
}

struct DesktopPetSettingsSection: View {
    @ObservedObject private var manager = DesktopPetWindowManager.shared

    private enum Layout {
        static let previewHeight: CGFloat = 78
        static let cardMinimumWidth: CGFloat = 104
        static let cardMaximumWidth: CGFloat = 132
        static let cardMinimumHeight: CGFloat = 118
        static let cardCornerRadius: CGFloat = 12
        static let gridSpacing: CGFloat = 12
    }

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: Layout.cardMinimumWidth,
                    maximum: Layout.cardMaximumWidth
                ),
                spacing: Layout.gridSpacing,
                alignment: .top
            )
        ]
    }

    var body: some View {
        Toggle(L10n.DesktopPet.settingsEnabled, isOn: enabledBinding)
            .font(DesktopPetSettingsDesign.bodyFont)

        VStack(alignment: .leading, spacing: Layout.gridSpacing) {
            Text(L10n.DesktopPet.settingsAppearance)
                .font(DesktopPetSettingsDesign.emphasizedBodyFont)

            LazyVGrid(columns: columns, alignment: .leading, spacing: Layout.gridSpacing) {
                ForEach(DesktopPetAppearance.allCases) { appearance in
                    appearanceButton(for: appearance)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Text(L10n.DesktopPet.settingsDescription)
            .font(DesktopPetSettingsDesign.bodyFont)
            .foregroundStyle(.secondary)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { manager.isEnabled },
            set: { manager.setEnabled($0) }
        )
    }

    private func appearanceButton(for appearance: DesktopPetAppearance) -> some View {
        let isSelected = appearance == manager.appearance
        return Button {
            manager.selectAppearance(appearance)
        } label: {
            VStack(spacing: 8) {
                Image(appearance.assetName)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: Layout.previewHeight)

                Text(appearance.displayName)
                    .font(.system(
                        size: DesktopPetSettingsDesign.bodyFontSize,
                        weight: isSelected ? .semibold : .regular
                    ))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: DesktopPetSettingsDesign.appearanceNameMinimumHeight,
                        alignment: .top
                    )
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: Layout.cardMinimumHeight, alignment: .top)
            .background(selectionBackground(for: appearance), in: RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                    .strokeBorder(selectionBorderColor(for: appearance), lineWidth: isSelected ? 2 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(7)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(appearance.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(appearance.displayName)
    }

    private func selectionBackground(for appearance: DesktopPetAppearance) -> Color {
        appearance == manager.appearance ? .accentColor.opacity(0.14) : .secondary.opacity(0.08)
    }

    private func selectionBorderColor(for appearance: DesktopPetAppearance) -> Color {
        appearance == manager.appearance ? .accentColor : .secondary.opacity(0.12)
    }
}
