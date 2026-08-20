//
//  MarkdownInlineImageTests.swift
//  WillDeepTests
//
//  Covers the `![alt](path)` → picture pipeline: which lines become image
//  blocks, which sources are allowed to render, and how a Retina capture
//  is fitted to the chat column.
//

import Testing
import Foundation
import AppKit
@testable import WillDeep

@Suite
@MainActor
struct MarkdownInlineImageTests {

    // MARK: - Line parsing

    @Test
    func standaloneImageLineParses() {
        let parsed = MarkdownInlineImage.parseStandaloneImageLine("![a shot](/tmp/shot.png)")
        #expect(parsed?.alt == "a shot")
        #expect(parsed?.source == "/tmp/shot.png")
    }

    @Test
    func emptyAltIsAllowed() {
        let parsed = MarkdownInlineImage.parseStandaloneImageLine("![](/tmp/shot.png)")
        #expect(parsed?.alt == "")
        #expect(parsed?.source == "/tmp/shot.png")
    }

    @Test
    func titleAfterPathIsDropped() {
        let parsed = MarkdownInlineImage.parseStandaloneImageLine(#"![alt](/tmp/a.png "a title")"#)
        #expect(parsed?.source == "/tmp/a.png")
    }

    @Test
    func angleBracketedPathIsUnwrapped() {
        let parsed = MarkdownInlineImage.parseStandaloneImageLine("![alt](</tmp/my shot.png>)")
        #expect(parsed?.source == "/tmp/my shot.png")
    }

    @Test
    func leadingAndTrailingWhitespaceIsTolerated() {
        let parsed = MarkdownInlineImage.parseStandaloneImageLine("   ![alt](/tmp/a.png)   ")
        #expect(parsed?.source == "/tmp/a.png")
    }

    @Test
    func imageInsideProseIsNotAStandaloneImage() {
        // A block-level attachment mid-sentence wrecks line layout, so
        // these keep their existing alt-text rendering.
        #expect(MarkdownInlineImage.parseStandaloneImageLine("see ![alt](/tmp/a.png) here") == nil)
        #expect(MarkdownInlineImage.parseStandaloneImageLine("![a](/x.png) ![b](/y.png)") == nil)
    }

    @Test
    func plainLinkIsNotAnImage() {
        #expect(MarkdownInlineImage.parseStandaloneImageLine("[alt](/tmp/a.png)") == nil)
    }

    @Test
    func zeroWidthBreakpointsAreStrippedFromPath() {
        // AgentLongTokenBreaker injects U+200B before the parser runs.
        let line = "![alt](/tmp/\u{200B}shot.png)"
        #expect(MarkdownInlineImage.parseStandaloneImageLine(line)?.source == "/tmp/shot.png")
    }

    // MARK: - Source policy

    @Test
    func remoteSourcesAreRejected() {
        // Assistant prose is model-controlled. Fetching a remote image
        // would turn every reply into a possible tracking pixel.
        #expect(MarkdownInlineImage.isRemoteSource("https://example.com/a.png"))
        #expect(MarkdownInlineImage.isRemoteSource("http://example.com/a.png"))
        #expect(MarkdownInlineImage.isRemoteSource("data:image/png;base64,AAAA"))
        #expect(MarkdownInlineImage.localFileURL(for: "https://example.com/a.png") == nil)
        #expect(MarkdownInlineImage.localFileURL(for: "data:image/png;base64,AAAA") == nil)
    }

    @Test
    func localPathsAreNotRemote() {
        #expect(!MarkdownInlineImage.isRemoteSource("/tmp/a.png"))
        #expect(!MarkdownInlineImage.isRemoteSource("shot.png"))
        #expect(!MarkdownInlineImage.isRemoteSource("file:///tmp/a.png"))
    }

    @Test
    func missingFileResolvesToNil() {
        let path = NSTemporaryDirectory() + "/willdeep-not-here-\(UUID().uuidString).png"
        #expect(MarkdownInlineImage.localFileURL(for: path) == nil)
    }

    @Test
    func relativePathWithoutBaseResolvesToNil() {
        // Guessing at a CWD would render an arbitrary unrelated file.
        #expect(MarkdownInlineImage.localFileURL(for: "shot.png") == nil)
    }

    @Test
    func existingFileResolves() throws {
        let url = try Self.writeTemporaryPNG(width: 4, height: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(MarkdownInlineImage.localFileURL(for: url.path) == url.standardizedFileURL)
    }

    @Test
    func directoryDoesNotResolve() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        #expect(MarkdownInlineImage.localFileURL(for: dir.path) == nil)
    }

    // MARK: - Sizing

    @Test
    func retinaCaptureIsScaledIntoTheColumn() {
        // A 2560×1600 window grab must not render at 2560pt wide.
        let size = MarkdownInlineImage.displaySize(
            pixelSize: NSSize(width: 2560, height: 1600),
            contentWidth: 600
        )
        #expect(size.width <= MarkdownInlineImage.maxDisplayWidth)
        #expect(size.height <= MarkdownInlineImage.maxDisplayHeight)
        #expect(size.width > MarkdownInlineImage.thumbnailMaxSide)
    }

    @Test
    func tallScreenshotIsBoundedByHeight() {
        let size = MarkdownInlineImage.displaySize(
            pixelSize: NSSize(width: 400, height: 8000),
            contentWidth: 600
        )
        #expect(size.height <= MarkdownInlineImage.maxDisplayHeight)
    }

    @Test
    func narrowColumnConstrainsWidth() {
        let size = MarkdownInlineImage.displaySize(
            pixelSize: NSSize(width: 2000, height: 1000),
            contentWidth: 200
        )
        #expect(size.width <= 200)
    }

    @Test
    func smallImageIsNotUpscaled() {
        // Blowing a 32×32 icon up to column width just renders it blurry.
        let scale = max(1, NSScreen.main?.backingScaleFactor ?? 2)
        let size = MarkdownInlineImage.displaySize(
            pixelSize: NSSize(width: 32, height: 32),
            contentWidth: 600
        )
        #expect(size.width <= 32 / scale + 1)
    }

    @Test
    func degenerateSizeDoesNotCrash() {
        let size = MarkdownInlineImage.displaySize(
            pixelSize: NSSize(width: 0, height: 0),
            contentWidth: 600
        )
        #expect(size.width == 0)
        #expect(size.height == 0)
    }

    // MARK: - Loading

    @Test
    func loadsARealFile() throws {
        let url = try Self.writeTemporaryPNG(width: 10, height: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = MarkdownInlineImage.loadImage(at: url)
        #expect(image != nil)
    }

    @Test
    func fallbackLabelPrefersAltText() {
        #expect(MarkdownInlineImage.fallbackLabel(alt: "chart", source: "/tmp/a.png") == "▧ chart")
        #expect(MarkdownInlineImage.fallbackLabel(alt: "", source: "/tmp/a.png") == "▧ /tmp/a.png")
        #expect(MarkdownInlineImage.fallbackLabel(alt: "", source: "") == "▧ Image")
    }

    // MARK: - Helpers

    private static func writeTemporaryPNG(width: Int, height: Int) throws -> URL {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("willdeep-image-test-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }
}

@Suite
@MainActor
struct MarkdownImageBlockParsingTests {

    @Test
    func standaloneImageLineBecomesAnImageBlock() {
        let blocks = MarkdownPreviewParser.blocks(from: "![shot](/tmp/a.png)")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .image)
        #expect(blocks[0].text == "shot")
        #expect(blocks[0].imageSource == "/tmp/a.png")
    }

    @Test
    func imageBlockSeparatesSurroundingParagraphs() {
        let md = """
        before

        ![shot](/tmp/a.png)

        after
        """
        let blocks = MarkdownPreviewParser.blocks(from: md)
        #expect(blocks.map(\.kind) == [.paragraph, .image, .paragraph])
        #expect(blocks[0].text == "before")
        #expect(blocks[2].text == "after")
    }

    @Test
    func imageDirectlyAfterProseStillSplitsTheParagraph() {
        let blocks = MarkdownPreviewParser.blocks(from: "here it is:\n![shot](/tmp/a.png)")
        #expect(blocks.map(\.kind) == [.paragraph, .image])
    }

    @Test
    func imageInsideFencedCodeStaysCode() {
        let md = """
        ```markdown
        ![shot](/tmp/a.png)
        ```
        """
        let blocks = MarkdownPreviewParser.blocks(from: md)
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .code)
    }

    @Test
    func inlineImageStaysInParagraph() {
        let blocks = MarkdownPreviewParser.blocks(from: "look at ![shot](/tmp/a.png) closely")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .paragraph)
    }

    @Test
    func remoteImageStillParsesAsBlockButCarriesRemoteSource() {
        // The block exists; the renderer is what refuses to fetch it.
        let blocks = MarkdownPreviewParser.blocks(from: "![x](https://example.com/a.png)")
        #expect(blocks[0].kind == .image)
        #expect(MarkdownInlineImage.localFileURL(for: blocks[0].imageSource ?? "") == nil)
    }
}
