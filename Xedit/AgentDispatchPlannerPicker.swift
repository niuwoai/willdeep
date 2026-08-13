//
//  AgentDispatchPlannerPicker.swift
//  WillDeep
//

import SwiftUI

struct AgentDispatchPlannerPicker: View {
    let profiles: [AgentExecutionProfile]
    let onManageProfiles: () -> Void
    let onCancel: () -> Void
    let onApply: (String, String) -> Void

    @State private var primaryProfileID: String
    @State private var fallbackProfileID: String

    init(
        profiles: [AgentExecutionProfile],
        primaryProfileID: String,
        fallbackProfileIDs: [String],
        onManageProfiles: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onApply: @escaping (String, String) -> Void
    ) {
        self.profiles = profiles
        self.onManageProfiles = onManageProfiles
        self.onCancel = onCancel
        self.onApply = onApply

        let availableIDs = Set(profiles.map(\.id))
        let resolvedPrimaryID = availableIDs.contains(primaryProfileID)
            ? primaryProfileID
            : profiles.first?.id ?? primaryProfileID
        let resolvedFallbackID = fallbackProfileIDs.first {
            $0 != resolvedPrimaryID && availableIDs.contains($0)
        } ?? profiles.first(where: { $0.id != resolvedPrimaryID })?.id ?? ""
        _primaryProfileID = State(initialValue: resolvedPrimaryID)
        _fallbackProfileID = State(initialValue: resolvedFallbackID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            modelSection(
                title: L10n.Dispatch.plannerPrimaryModel,
                profile: primaryProfile,
                candidates: profiles,
                help: L10n.Dispatch.plannerPrimaryModelHelp,
                helpColor: .accentColor,
                onSelect: selectPrimary
            )
            fallbackConnector
            modelSection(
                title: L10n.Dispatch.plannerFallbackModel,
                profile: fallbackProfile,
                candidates: fallbackCandidates,
                help: L10n.Dispatch.plannerFallbackModelHelp,
                helpColor: .secondary,
                onSelect: { fallbackProfileID = $0 }
            )
            footer
        }
        .frame(width: 500)
        .accessibilityIdentifier("dispatch.planner-picker")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.Dispatch.plannerPickerTitle)
                .font(.system(size: 21, weight: .semibold))
            Text(L10n.Dispatch.plannerPickerMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 15)
    }

    private func modelSection(
        title: String,
        profile: AgentExecutionProfile?,
        candidates: [AgentExecutionProfile],
        help: String,
        helpColor: Color,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))

            ZStack {
                HStack(spacing: 13) {
                    Image(systemName: profile?.executor == .willDeep
                        ? "brain.head.profile"
                        : profile?.executor.symbol ?? "questionmark")
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                        }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile?.name ?? L10n.Dispatch.plannerModelUnavailable)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let profile {
                            Text(profileDetail(profile))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .contentShape(Rectangle())

                Menu {
                    ForEach(candidates) { candidate in
                        Button {
                            onSelect(candidate.id)
                        } label: {
                            Label(
                                candidate.name,
                                systemImage: candidate.id == profile?.id
                                    ? "checkmark"
                                    : candidate.executor.symbol
                            )
                        }
                    }
                } label: {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .disabled(candidates.isEmpty)
                .accessibilityLabel(title)
                .accessibilityIdentifier("dispatch.planner-picker.\(title)")
            }

            Label(help, systemImage: "circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(helpColor)
                .symbolRenderingMode(.monochrome)
                .padding(.leading, 49)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var fallbackConnector: some View {
        ZStack {
            Divider().opacity(0.55)
            Image(systemName: "arrow.down")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 7)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(L10n.Dispatch.manageProfiles, action: onManageProfiles)
                .buttonStyle(.plain)
            Spacer()
            Button(L10n.Dispatch.cancel, action: onCancel)
                .buttonStyle(.bordered)
            Button {
                onApply(primaryProfileID, fallbackProfileID)
            } label: {
                Text(L10n.Dispatch.done)
                    .frame(minWidth: 62)
            }
            .buttonStyle(.borderedProminent)
            .tint(.black)
            .disabled(primaryProfile == nil || fallbackProfile == nil)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
        .overlay(alignment: .top) {
            Divider().opacity(0.55)
        }
    }

    private var primaryProfile: AgentExecutionProfile? {
        profiles.first { $0.id == primaryProfileID }
    }

    private var fallbackProfile: AgentExecutionProfile? {
        profiles.first { $0.id == fallbackProfileID && $0.id != primaryProfileID }
    }

    private var fallbackCandidates: [AgentExecutionProfile] {
        profiles.filter { $0.id != primaryProfileID }
    }

    private func selectPrimary(_ profileID: String) {
        primaryProfileID = profileID
        if fallbackProfileID == profileID || fallbackProfile == nil {
            fallbackProfileID = profiles.first(where: { $0.id != profileID })?.id ?? ""
        }
    }

    private func profileDetail(_ profile: AgentExecutionProfile) -> String {
        let source = profile.providerID.map {
            AgentProviderPreset.suggestedDisplayName(providerID: $0)
        } ?? profile.executor.displayName
        let model = profile.modelID
            ?? profile.nativeProfileName
            ?? L10n.Dispatch.followCurrentModel
        return "\(source) · \(model)"
    }
}
