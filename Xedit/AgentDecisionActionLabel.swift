import SwiftUI

/// The shortcut stays with its action instead of a detached card footer.
struct AgentDecisionActionLabel: View {
    let title: String
    let systemImage: String
    let shortcut: String
    var shortcutFirst = false

    var body: some View {
        HStack(spacing: 8) {
            if shortcutFirst { shortcutBadge }
            Label(title, systemImage: systemImage)
            if !shortcutFirst { shortcutBadge }
        }
    }

    private var shortcutBadge: some View {
        Text(shortcut)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            .opacity(0.75)
    }
}
