//
//  AgentGoalRunSettingsSection.swift
//  WillDeep
//
//  Settings → Agent → Goal: how long one Goal segment may run on its own.
//

import SwiftUI

struct AgentGoalRunSettingsSection: View {
    @State private var hours = AgentGoalRunSettings.loadHours()

    var body: some View {
        Section(L10n.GoalRunSettings.section) {
            Picker(L10n.GoalRunSettings.segmentLimitLabel, selection: $hours) {
                ForEach(AgentGoalRunSettings.allowedHours, id: \.self) { value in
                    Text(L10n.GoalRunSettings.hours(value)).tag(value)
                }
            }
            .onCompatibleChange(of: hours) { (newValue: Int) in
                AgentGoalRunSettings.saveHours(newValue)
            }
            Text(L10n.GoalRunSettings.segmentLimitDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L10n.GoalRunSettings.overnightDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { hours = AgentGoalRunSettings.loadHours() }
    }
}
