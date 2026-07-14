//
//  DesktopPetSettingsSection.swift
//  WillDeep
//

import SwiftUI

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

        VStack(alignment: .leading, spacing: Layout.gridSpacing) {
            Text(L10n.DesktopPet.settingsAppearance)
                .font(.subheadline.weight(.semibold))

            LazyVGrid(columns: columns, alignment: .leading, spacing: Layout.gridSpacing) {
                ForEach(DesktopPetAppearance.allCases) { appearance in
                    appearanceButton(for: appearance)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Text(L10n.DesktopPet.settingsDescription)
            .font(.caption)
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
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .top)
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
