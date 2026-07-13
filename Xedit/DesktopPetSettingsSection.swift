//
//  DesktopPetSettingsSection.swift
//  WillDeep
//

import SwiftUI

struct DesktopPetSettingsSection: View {
    @ObservedObject private var manager = DesktopPetWindowManager.shared

    private enum Layout {
        static let previewSize: CGFloat = 58
        static let previewCornerRadius: CGFloat = 10
        static let previewSpacing: CGFloat = 10
    }

    var body: some View {
        Toggle(L10n.DesktopPet.settingsEnabled, isOn: enabledBinding)

        Picker(L10n.DesktopPet.settingsAppearance, selection: appearanceBinding) {
            ForEach(DesktopPetAppearance.allCases) { appearance in
                Text(appearance.displayName).tag(appearance)
            }
        }

        ScrollView(.horizontal) {
            LazyHStack(spacing: Layout.previewSpacing) {
                ForEach(DesktopPetAppearance.allCases) { appearance in
                    appearanceButton(for: appearance)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)

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

    private var appearanceBinding: Binding<DesktopPetAppearance> {
        Binding(
            get: { manager.appearance },
            set: { manager.selectAppearance($0) }
        )
    }

    private func appearanceButton(for appearance: DesktopPetAppearance) -> some View {
        Button {
            manager.selectAppearance(appearance)
        } label: {
            Image(appearance.assetName)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .padding(4)
                .frame(width: Layout.previewSize, height: Layout.previewSize)
                .background(selectionBackground(for: appearance), in: RoundedRectangle(cornerRadius: Layout.previewCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Layout.previewCornerRadius, style: .continuous)
                        .strokeBorder(selectionBorderColor(for: appearance), lineWidth: 2)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(appearance.displayName)
        .accessibilityAddTraits(appearance == manager.appearance ? .isSelected : [])
    }

    private func selectionBackground(for appearance: DesktopPetAppearance) -> Color {
        appearance == manager.appearance ? .accentColor.opacity(0.14) : .secondary.opacity(0.08)
    }

    private func selectionBorderColor(for appearance: DesktopPetAppearance) -> Color {
        appearance == manager.appearance ? .accentColor : .clear
    }
}
