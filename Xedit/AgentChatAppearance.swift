//
//  AgentChatAppearance.swift
//  WillDeep
//
//  Agent transcript typography choices shared by Settings, SwiftUI's live
//  message renderer, and the TextKit history renderer.
//

import AppKit
import SwiftUI

struct AgentChatFontChoice: Identifiable, CaseIterable, Equatable {
    enum Kind {
        case system
        case rounded
        case serif
        case monospaced
        case menlo
    }

    let id: String
    let displayName: String
    let kind: Kind

    static var system: AgentChatFontChoice {
        AgentChatFontChoice(id: "system", displayName: L10n.Settings.agentFontSystem, kind: .system)
    }

    static var rounded: AgentChatFontChoice {
        AgentChatFontChoice(id: "rounded", displayName: L10n.Settings.agentFontRounded, kind: .rounded)
    }

    static var serif: AgentChatFontChoice {
        AgentChatFontChoice(id: "serif", displayName: L10n.Settings.agentFontSerif, kind: .serif)
    }

    static var monospaced: AgentChatFontChoice {
        AgentChatFontChoice(id: "monospaced", displayName: L10n.Settings.agentFontMonospaced, kind: .monospaced)
    }

    static var menlo: AgentChatFontChoice {
        AgentChatFontChoice(id: "menlo", displayName: "Menlo", kind: .menlo)
    }

    static var allCases: [AgentChatFontChoice] {
        [.system, .rounded, .serif, .monospaced, .menlo]
    }

    static func byID(_ id: String) -> AgentChatFontChoice? {
        allCases.first { $0.id == id }
    }

    func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let font: NSFont
        switch kind {
        case .system:
            font = NSFont.systemFont(ofSize: size, weight: weight)
        case .rounded:
            let descriptor = NSFont.systemFont(ofSize: size, weight: weight)
                .fontDescriptor.withDesign(.rounded)
            font = descriptor.flatMap { NSFont(descriptor: $0, size: size) }
                ?? NSFont.systemFont(ofSize: size, weight: weight)
        case .serif:
            let descriptor = NSFont.systemFont(ofSize: size, weight: weight)
                .fontDescriptor.withDesign(.serif)
            font = descriptor.flatMap { NSFont(descriptor: $0, size: size) }
                ?? NSFont.systemFont(ofSize: size, weight: weight)
        case .monospaced:
            font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .menlo:
            font = NSFont(name: "Menlo-Regular", size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
        return font.withEditorCJKCascade()
    }

    func swiftUIFont(size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        Font(nsFont(size: size, weight: weight))
    }
}

enum AgentChatTypography {
    static func lineSpacing(fontSize: CGFloat, lineHeightMultiple: CGFloat) -> CGFloat {
        max(0, fontSize * (lineHeightMultiple - 1))
    }

    static func lineHeight(fontSize: CGFloat, lineHeightMultiple: CGFloat) -> CGFloat {
        fontSize + lineSpacing(fontSize: fontSize, lineHeightMultiple: lineHeightMultiple)
    }

    /// Markdown headings scale from the user's chat body size instead of
    /// switching to a second, fixed typography system. The previous fixed
    /// 22/18/16/14 ladder made H4 smaller than 15 pt body copy and stopped
    /// responding when the user enlarged the transcript.
    static func headingFontSize(level: Int, baseFontSize: CGFloat) -> CGFloat {
        switch level {
        case 1: return baseFontSize + 7
        case 2: return baseFontSize + 4
        case 3: return baseFontSize + 2
        default: return baseFontSize + 1
        }
    }
}
