//
//  AgentTranscriptSearch.swift
//  WillDeep
//
//  Lightweight helpers for the in-conversation find overlay. Kept out
//  of AgentChatTranscript so the range matching and highlight styling
//  are covered by unit tests without spinning up SwiftUI.
//

import AppKit
import SwiftUI

nonisolated struct AgentTranscriptSearchHighlightResult {
    let attributedString: NSAttributedString
    let matchRanges: [NSRange]

    var matchCount: Int { matchRanges.count }
}

nonisolated enum AgentTranscriptSearch {
    static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matchRanges(in text: String, query rawQuery: String) -> [NSRange] {
        let query = normalizedQuery(rawQuery)
        guard !query.isEmpty else { return [] }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        guard fullRange.length > 0 else { return [] }

        var ranges: [NSRange] = []
        var searchLocation = 0
        while searchLocation < fullRange.length {
            let range = NSRange(location: searchLocation, length: fullRange.length - searchLocation)
            let match = nsText.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: range
            )
            guard match.location != NSNotFound, match.length > 0 else { break }
            ranges.append(match)
            searchLocation = match.location + match.length
        }
        return ranges
    }

    static func highlightedString(
        from base: NSAttributedString,
        query: String,
        activeMatchIndex: Int?,
        isDark: Bool
    ) -> AgentTranscriptSearchHighlightResult {
        let ranges = matchRanges(in: base.string, query: query)
        guard !ranges.isEmpty else {
            return AgentTranscriptSearchHighlightResult(attributedString: base, matchRanges: [])
        }

        let highlighted = NSMutableAttributedString(attributedString: base)
        let activeIndex = clampedActiveIndex(activeMatchIndex, count: ranges.count)
        let passiveBackground = searchMatchBackground(isDark: isDark)
        let activeBackground = activeSearchMatchBackground(isDark: isDark)
        let activeForeground = activeSearchMatchForeground(isDark: isDark)

        for (index, range) in ranges.enumerated() {
            guard range.location >= 0, NSMaxRange(range) <= highlighted.length else { continue }
            if index == activeIndex {
                highlighted.addAttributes([
                    .backgroundColor: activeBackground,
                    .foregroundColor: activeForeground,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: activeForeground.withAlphaComponent(0.58),
                ], range: range)
            } else {
                highlighted.addAttributes([
                    .backgroundColor: passiveBackground,
                ], range: range)
            }
        }

        return AgentTranscriptSearchHighlightResult(
            attributedString: highlighted,
            matchRanges: ranges
        )
    }

    static func clampedActiveIndex(_ index: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let raw = index ?? 0
        if raw < 0 { return 0 }
        if raw >= count { return count - 1 }
        return raw
    }

    private static func searchMatchBackground(isDark: Bool) -> NSColor {
        let color = isDark ? NSColor.systemYellow : NSColor.systemYellow
        return color.withAlphaComponent(isDark ? 0.34 : 0.42)
    }

    private static func activeSearchMatchBackground(isDark: Bool) -> NSColor {
        let color = isDark ? NSColor.systemOrange : NSColor.systemOrange
        return color.withAlphaComponent(isDark ? 0.72 : 0.78)
    }

    private static func activeSearchMatchForeground(isDark: Bool) -> NSColor {
        isDark ? NSColor.black : NSColor.white
    }
}

struct AgentConversationSearchKeyboardShortcutView: NSViewRepresentable {
    let onFind: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFind: onFind)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onFind = onFind
        context.coordinator.view = nsView
    }

    final class Coordinator {
        var onFind: () -> Void
        weak var view: NSView?
        private var monitor: Any?

        init(onFind: @escaping () -> Void) {
            self.onFind = onFind
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func attach(to view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard self.shouldHandle(event) else { return event }
                self.onFind()
                return nil
            }
        }

        private func shouldHandle(_ event: NSEvent) -> Bool {
            guard let view, let window = view.window, event.window === window else {
                return false
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command else { return false }
            return event.charactersIgnoringModifiers?.lowercased() == "f"
        }
    }
}

struct AgentConversationSearchBar: View {
    @Binding var isPresented: Bool
    @Binding var query: String
    let matchCount: Int
    let activeIndex: Int
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.secondary)

                TextField(L10n.Transcript.searchPlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($isSearchFocused)
                    .onSubmit(onNext)

                Divider()
                    .frame(height: 24)
                    .opacity(0.5)

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .foregroundStyle(.secondary)
                .help(L10n.Transcript.searchCloseHelp)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)

            if !AgentTranscriptSearch.normalizedQuery(query).isEmpty {
                Divider().opacity(0.5)
                HStack(spacing: 8) {
                    Button(action: onPrevious) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 26, height: 24)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .foregroundStyle(matchCount > 0 ? .secondary : .tertiary)
                    .disabled(matchCount == 0)
                    .help(L10n.Transcript.searchPreviousHelp)

                    Button(action: onNext) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 26, height: 24)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .foregroundStyle(matchCount > 0 ? .secondary : .tertiary)
                    .disabled(matchCount == 0)
                    .help(L10n.Transcript.searchNextHelp)

                    Spacer(minLength: 18)

                    Text(resultLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(matchCount > 0 ? .secondary : .tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
            }
        }
        .frame(width: 374)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.13), radius: 18, x: 0, y: 10)
        .onAppear {
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
    }

    private var resultLabel: String {
        guard matchCount > 0 else { return L10n.Transcript.searchNoResults }
        return L10n.Transcript.searchResultPosition(
            String(activeIndex + 1),
            String(matchCount)
        )
    }

    private func close() {
        isPresented = false
        onClose()
    }
}
