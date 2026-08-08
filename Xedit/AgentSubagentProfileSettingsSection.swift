//
//  AgentSubagentProfileSettingsSection.swift
//  WillDeep
//
//  Settings surface for subagent trades: which model each trade runs on.
//
//  Only the model binding is editable. Tool sets, prompts and budgets are
//  code, not configuration — a trade's narrow tool set is what makes it
//  cheap and accurate, and the read-only boundary is a safety property, so
//  neither is something to hand to a settings pane. The tool list is shown
//  read-only so the trade-off stays legible.
//

import SwiftUI

struct AgentSubagentProfileSettingsSection: View {
    @EnvironmentObject private var appState: AppState

    @State private var overrides = AgentSubagentProfileStore.loadOverrides()

    private var profiles: [AgentSubagentProfile] {
        AgentSubagentProfileCatalog.applyingOverrides(overrides)
    }

    var body: some View {
        ForEach(profiles) { profile in
            profileRow(profile)
        }
        Text(L10n.AgentDelegation.profilesSectionFooter)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func profileRow(_ profile: AgentSubagentProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(profile.localizedDisplayName)
                    .font(.subheadline.weight(.medium))
                Text("`\(profile.id)`")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            Text(profile.localizedPurpose)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent(L10n.AgentDelegation.profileModelLabel) {
                VStack(alignment: .trailing, spacing: 2) {
                    TextField(
                        L10n.AgentDelegation.profileInheritsParent,
                        text: modelBinding(for: profile)
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)

                    if !profile.modelBinding.inheritsEverything,
                       !appState.subagentProfileBindingIsAvailable(profile) {
                        // Not an error: an unusable binding silently runs on
                        // the parent's model. Saying so beats a user
                        // wondering why the cheap trade never got cheaper.
                        Text(L10n.AgentDelegation.profileUnavailableFallback)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            LabeledContent(L10n.AgentDelegation.profileToolsLabel) {
                Text(profile.toolNames.sorted().joined(separator: ", "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    /// Editing the model text writes an override; clearing it drops back to
    /// the built-in binding rather than storing an empty model.
    private func modelBinding(for profile: AgentSubagentProfile) -> Binding<String> {
        Binding(
            get: { overrides[profile.id]?.model ?? profile.modelBinding.model ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let base = AgentSubagentProfileCatalog.profile(id: profile.id)
                if trimmed.isEmpty {
                    overrides.removeValue(forKey: profile.id)
                } else {
                    var binding = overrides[profile.id] ?? base.modelBinding
                    binding.model = trimmed
                    overrides[profile.id] = binding
                }
                AgentSubagentProfileStore.saveOverrides(overrides)
            }
        )
    }
}
