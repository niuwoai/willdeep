//
//  AgentChatHistoryRendererTestSupport.swift
//  WillDeepTests
//
//  Attribute/layout probes shared by the renderer suites. They were private
//  helpers of AgentChatHistoryRendererTests until that file was split for the
//  repository size limit; `private` is file-scoped, so the shared ones live
//  here rather than being duplicated into each half.
//

import AppKit
import Foundation
@testable import WillDeep

func firstAttributeRange(
    _ key: NSAttributedString.Key,
    value expectedValue: String,
    in attributed: NSAttributedString
) -> NSRange? {
    var found = NSRange(location: NSNotFound, length: 0)
    let fullRange = NSRange(location: 0, length: attributed.length)
    attributed.enumerateAttribute(key, in: fullRange) { value, range, stop in
        guard (value as? String) == expectedValue else { return }
        found = range
        stop.pointee = true
    }
    return found.location == NSNotFound ? nil : found
}
func attributeCount(
    _ key: NSAttributedString.Key,
    in attributed: NSAttributedString
) -> Int {
    var count = 0
    attributed.enumerateAttribute(
        key,
        in: NSRange(location: 0, length: attributed.length)
    ) { value, _, _ in
        if value != nil { count += 1 }
    }
    return count
}
func occurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return haystack.components(separatedBy: needle).count - 1
}
func lineFragmentHeights(
    in attributed: NSAttributedString,
    width: CGFloat,
    intersecting characterRange: NSRange
) -> [CGFloat] {
    let storage = NSTextStorage(attributedString: attributed)
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer(size: NSSize(width: width, height: 1000))
    textContainer.lineFragmentPadding = 0
    storage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(textContainer)
    layoutManager.ensureLayout(for: textContainer)

    let glyphRange = layoutManager.glyphRange(
        forCharacterRange: characterRange,
        actualCharacterRange: nil
    )
    var heights: [CGFloat] = []
    layoutManager.enumerateLineFragments(
        forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)
    ) { rect, _, _, lineGlyphRange, _ in
        guard NSIntersectionRange(lineGlyphRange, glyphRange).length > 0 else { return }
        heights.append(rect.height)
    }
    return heights
}
func firstAttributeRange(
    _ key: NSAttributedString.Key,
    containing expectedSubstring: String,
    in attributed: NSAttributedString
) -> NSRange? {
    var found = NSRange(location: NSNotFound, length: 0)
    let fullRange = NSRange(location: 0, length: attributed.length)
    attributed.enumerateAttribute(key, in: fullRange) { value, range, stop in
        guard value != nil else { return }
        let rangeText = (attributed.string as NSString).substring(with: range)
        let stringValue = value as? String
        guard stringValue?.contains(expectedSubstring) == true
                || rangeText.contains(expectedSubstring) else { return }
        found = range
        stop.pointee = true
    }
    return found.location == NSNotFound ? nil : found
}
func firstCopyIconRange(in attributed: NSAttributedString) -> NSRange? {
    let fullRange = NSRange(location: 0, length: attributed.length)
    var found = NSRange(location: NSNotFound, length: 0)
    attributed.enumerateAttribute(.attachment, in: fullRange) { value, range, stop in
        guard value != nil else { return }
        found = range
        stop.pointee = true
    }
    if found.location != NSNotFound {
        return found
    }

    for fallbackSymbol in ["⧉", "⎘"] {
        let range = (attributed.string as NSString).range(of: fallbackSymbol)
        if range.location != NSNotFound {
            return range
        }
    }
    return nil
}
func chippedFilePaths(in content: String) -> Set<String> {
    let rendered = AgentChatHistoryRenderer.render(
        messages: [AgentMessage(role: .assistant, content: content)],
        isDark: false
    )
    var paths: Set<String> = []
    rendered.enumerateAttribute(
        .agentChatHistoryFilePath,
        in: NSRange(location: 0, length: rendered.length)
    ) { value, _, _ in
        if let path = value as? String { paths.insert(path) }
    }
    return paths
}
