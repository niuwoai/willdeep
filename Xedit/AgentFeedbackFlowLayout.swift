import SwiftUI

/// Each control exists once. Cache measurements instead of exploring duplicate
/// horizontal/vertical candidate trees on every parent layout pass.
struct AgentFeedbackFlowLayout: Layout {
    var spacing: CGFloat
    var trailingLastItem = false

    struct Cache {
        var idealSizes: [CGSize]
        var width: CGFloat?
        var sizes: [CGSize] = []
        var origins: [CGPoint] = []
        var result = CGSize.zero
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(idealSizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        prepare(width: proposal.width, subviews: subviews, cache: &cache)
        return cache.result
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        prepare(width: bounds.width, subviews: subviews, cache: &cache)
        for index in subviews.indices {
            let origin = cache.origins[index]
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(cache.sizes[index])
            )
        }
    }

    private func prepare(width proposedWidth: CGFloat?, subviews: Subviews, cache: inout Cache) {
        let idealWidth = cache.idealSizes.reduce(0) { $0 + $1.width }
            + spacing * CGFloat(max(0, subviews.count - 1))
        let width = proposedWidth.flatMap { $0.isFinite ? max(0, $0) : nil } ?? idealWidth
        guard cache.width != width else { return }
        cache.width = width
        cache.sizes = subviews.indices.map { index in
            let ideal = cache.idealSizes[index]
            return ideal.width > width
                ? subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
                : ideal
        }
        let plan = AgentFeedbackFlowPlan(sizes: cache.sizes, width: width, spacing: spacing,
                                         trailingLastItem: trailingLastItem)
        cache.origins = plan.origins
        cache.result = plan.size
    }
}

/// Pure positioning makes wrapping and the narrow-window bounds testable.
nonisolated struct AgentFeedbackFlowPlan {
    let origins: [CGPoint]
    let size: CGSize

    init(sizes: [CGSize], width: CGFloat, spacing: CGFloat, trailingLastItem: Bool = false) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for (index, item) in sizes.enumerated() {
            if x > 0 && x + item.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            // Right-align the action group only when it shares the heading row.
            let itemX = trailingLastItem && index == sizes.count - 1 && y == 0 && index > 0
                ? max(x, width - item.width) : x
            positions.append(CGPoint(x: itemX, y: y))
            usedWidth = max(usedWidth, itemX + item.width)
            rowHeight = max(rowHeight, item.height)
            x = itemX + item.width + spacing
        }
        origins = positions
        size = CGSize(width: trailingLastItem ? width : usedWidth,
                      height: sizes.isEmpty ? 0 : y + rowHeight)
    }
}
