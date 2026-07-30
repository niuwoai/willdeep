//
//  AgentDispatchGoalSetupView.swift
//  WillDeep
//

import SwiftUI

struct AgentDispatchGoalSetupView: View {
    let workspaceLocation: WorkspaceLocation?
    let workspaceName: String
    let onCreate: (String, [String]) -> Void

    @State private var statement = ""
    @State private var checklistText = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case statement
        case checklist
    }

    private var checklistItems: [String] {
        checklistText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var normalizedStatement: String {
        statement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreate: Bool {
        !normalizedStatement.isEmpty && !checklistItems.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            ScrollView {
                HStack(alignment: .top, spacing: 18) {
                    definitionColumn
                    setupSummary
                }
                .padding(24)
                .frame(maxWidth: 980, alignment: .top)
                .frame(maxWidth: .infinity)
            }
            footer
        }
        .background(Color.primary.opacity(0.012))
        .onAppear {
            focusedField = .statement
        }
        .accessibilityIdentifier("dispatch.goal-setup")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.Dispatch.goalSetupTitle)
                    .font(.system(size: 18, weight: .semibold))
                Text(L10n.Dispatch.goalSetupMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var definitionColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldCard(
                title: L10n.GoalEditorSheet.statementLabel,
                symbol: "target"
            ) {
                ZStack(alignment: .topLeading) {
                    if statement.isEmpty {
                        Text(L10n.GoalEditorSheet.statementPlaceholder)
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $statement)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .focused($focusedField, equals: .statement)
                        .frame(minHeight: 116)
                        .accessibilityIdentifier("dispatch.goal-setup.statement")
                }
                .padding(4)
                .background(Color.primary.opacity(0.025))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                )
            }

            fieldCard(
                title: L10n.GoalEditorSheet.checklistLabel,
                symbol: "checklist"
            ) {
                TextEditor(text: $checklistText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($focusedField, equals: .checklist)
                    .frame(minHeight: 180)
                    .padding(8)
                    .background(Color.primary.opacity(0.025))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    )
                    .accessibilityIdentifier("dispatch.goal-setup.checklist")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var setupSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            summaryCard(
                title: L10n.Dispatch.goalWorkspace,
                symbol: workspaceLocation == nil ? "folder.badge.questionmark" : "folder.fill"
            ) {
                Text(workspaceName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let workspaceLocation {
                    Text(workspaceLocation.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }

            summaryCard(
                title: L10n.Dispatch.executor,
                symbol: "cpu"
            ) {
                Label(L10n.Dispatch.automaticExecutor, systemImage: "wand.and.stars")
                    .font(.system(size: 12, weight: .medium))
                Text(L10n.Dispatch.executorReason(.localFallback))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            summaryCard(
                title: L10n.Dispatch.environment,
                symbol: "network"
            ) {
                Label(L10n.Dispatch.automaticEnvironment, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .medium))
                Text(L10n.Dispatch.workspaceMappingHelp)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 250)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label(
                L10n.Dispatch.taskCount(checklistItems.count),
                systemImage: "point.3.connected.trianglepath.dotted"
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Spacer()
            Button {
                focusedField = nil
                onCreate(normalizedStatement, checklistItems)
            } label: {
                Label(L10n.Dispatch.startPlan, systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCreate)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("dispatch.goal-setup.create")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider().opacity(0.55)
        }
    }

    private func fieldCard<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    private func summaryCard<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }
}
