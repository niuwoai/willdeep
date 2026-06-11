//
//  AgentRoutinesSidebarSection.swift
//  WillDeep
//
//  The "ROUTINES" block that sits in the Agent-mode sidebar between
//  primary actions and the workspace list. New file (rather than another
//  300 lines inside AgentModeView) because AgentModeView is already past
//  the 3000-line soft cap — at least keep new feature code out of the
//  bloat.
//

import SwiftUI

struct AgentRoutinesSidebarSection: View {
    @EnvironmentObject var appState: AppState

    /// The routine row currently under the mouse — drives the hover-only
    /// trailing controls (toggle / edit / delete). Same cursor-style
    /// pattern as session rows.
    @State private var hoveredRoutineID: AgentRoutine.ID?
    /// Routine being edited in the sheet, or nil when the sheet is closed.
    /// Using `Identifiable`-based `.sheet(item:)` so the sheet recreates
    /// fresh state every time it opens.
    @State private var editing: RoutineSheetTarget?

    private struct RoutineSheetTarget: Identifiable {
        let id = UUID()
        let routine: AgentRoutine
        let isNew: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if appState.agentRoutines.isEmpty {
                emptyState
            } else {
                ForEach(appState.agentRoutines) { routine in
                    routineRow(routine)
                }
            }
            Spacer().frame(height: 12)
        }
        .sheet(item: $editing) { target in
            AgentRoutineEditorView(routine: target.routine, isNew: target.isNew)
                .environmentObject(appState)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Routines")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer(minLength: 0)
            Button {
                let seeded = AgentRoutine(
                    workspaceRootPath: appState.rootDirectory?.standardizedFileURL.path
                )
                editing = RoutineSheetTarget(routine: seeded, isNew: true)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("新建 Routine")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var emptyState: some View {
        Text("还没有 Routine。点击 + 创建一条到点自动运行的提示词。")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func routineRow(_ routine: AgentRoutine) -> some View {
        let isHovered = (hoveredRoutineID == routine.id)
        let isEnabled = routine.isEnabled

        Button {
            editing = RoutineSheetTarget(routine: routine, isNew: false)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isEnabled ? "clock.fill" : "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
                    .frame(width: 12)

                VStack(alignment: .leading, spacing: 1) {
                    Text(routine.name)
                        .font(.system(size: 12))
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(routine.schedule.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
                trailingActions(routine: routine, isHovered: isHovered)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredRoutineID = routine.id
            } else if hoveredRoutineID == routine.id {
                hoveredRoutineID = nil
            }
        }
        .contextMenu {
            Button(routine.isEnabled ? "停用" : "启用") {
                appState.toggleAgentRoutineEnabled(id: routine.id)
            }
            Button("立即运行一次") {
                appState.runAgentRoutineNow(id: routine.id)
            }
            Divider()
            Button("编辑…") {
                editing = RoutineSheetTarget(routine: routine, isNew: false)
            }
            Button("删除 Routine", role: .destructive) {
                appState.deleteAgentRoutine(id: routine.id)
            }
        }
    }

    @ViewBuilder
    private func trailingActions(routine: AgentRoutine, isHovered: Bool) -> some View {
        HStack(spacing: 4) {
            if isHovered {
                Button {
                    appState.runAgentRoutineNow(id: routine.id)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("立即运行一次")

                Button {
                    appState.toggleAgentRoutineEnabled(id: routine.id)
                } label: {
                    Image(systemName: routine.isEnabled ? "pause.fill" : "play.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(routine.isEnabled ? "停用" : "启用")
            }
        }
    }
}
