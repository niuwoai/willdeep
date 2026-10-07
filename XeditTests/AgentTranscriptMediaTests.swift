//
//  AgentTranscriptMediaTests.swift
//  WillDeepTests
//
//  Inline media in the transcript: which lines count as media, what the
//  TextKit formatter emits for playable / missing / unsupported / remote
//  sources, that both render caches notice the file changing, and that copy
//  and search treat the placeholder as the Markdown it came from.
//

import AppKit
import Foundation
import Testing
@testable import WillDeep

@Suite
@MainActor
struct AgentTranscriptMediaTests {

    // MARK: - Recognition

    @Test
    func kindComesFromTheFileTypeRegardlessOfCase() {
        for ext in ["mp4", "MOV", "m4v", "Mp4"] {
            #expect(AgentTranscriptMediaFormat.kind(forSource: "/tmp/clip.\(ext)") == .video, "\(ext)")
        }
        for ext in ["mp3", "M4A", "wav", "aac", "aiff", "caf", "flac"] {
            #expect(AgentTranscriptMediaFormat.kind(forSource: "/tmp/sound.\(ext)") == .audio, "\(ext)")
        }
    }

    @Test
    func queryStringAndFragmentAreNotPartOfTheExtension() {
        #expect(AgentTranscriptMediaFormat.kind(forSource: "/tmp/clip.mp4?t=30") == .video)
        #expect(AgentTranscriptMediaFormat.kind(forSource: "file:///tmp/a.m4a#intro") == .audio)
        #expect(AgentTranscriptMediaFormat.isPlayable(source: "/tmp/clip.MP4?x=1", kind: .video))
    }

    @Test
    func nonMediaAndUnknownExtensionsAreNotMedia() {
        #expect(AgentTranscriptMediaFormat.kind(forSource: "/tmp/shot.png") == nil)
        #expect(AgentTranscriptMediaFormat.kind(forSource: "/tmp/report.pdf") == nil)
        #expect(AgentTranscriptMediaFormat.kind(forSource: "/tmp/README") == nil)
        #expect(AgentTranscriptMediaFormat.kind(forSource: "/tmp/data.zzmedia") == nil)
    }

    @Test
    func recognisedButUnplayableFormatsStayMediaButAreNotPlayable() {
        // An .avi is still a video (so it can say "can't play this format"),
        // but AVPlayer is never pointed at it.
        #expect(AgentTranscriptMediaFormat.kind(forSource: "/tmp/old.avi") == .video)
        #expect(!AgentTranscriptMediaFormat.isPlayable(source: "/tmp/old.avi", kind: .video))
        #expect(AgentTranscriptMediaFormat.isPlayable(source: "/tmp/new.m4v", kind: .video))
        #expect(AgentTranscriptMediaFormat.isPlayable(source: "/tmp/a.flac", kind: .audio))
    }

    // MARK: - Parsing

    @Test
    func imageSyntaxToAVideoBecomesAMediaBlock() {
        let blocks = MarkdownPreviewParser.blocks(from: "![演示](/tmp/demo.mp4)")
        #expect(blocks.map(\.kind) == [.media])
        #expect(blocks[0].media?.syntax == .image)
        #expect(blocks[0].media?.kind == .video)
        #expect(blocks[0].media?.label == "演示")
        #expect(blocks[0].media?.markdown == "![演示](/tmp/demo.mp4)")
    }

    @Test
    func standaloneLinkToAudioBecomesAMediaBlockEvenRightAfterProse() {
        let blocks = MarkdownPreviewParser.blocks(from: "录音在这里：\n[会议录音](/tmp/meeting.m4a)")
        #expect(blocks.map(\.kind) == [.paragraph, .media])
        #expect(blocks[1].media?.syntax == .link)
        #expect(blocks[1].media?.kind == .audio)
        #expect(blocks[1].media?.displayName == "会议录音")
    }

    @Test
    func mediaInsideProseListsOrCodeStaysText() {
        #expect(MarkdownPreviewParser.blocks(from: "see [clip](/tmp/a.mp4) here").map(\.kind) == [.paragraph])
        #expect(MarkdownPreviewParser.blocks(from: "- [clip](/tmp/a.mp4)").map(\.kind) == [.unorderedList])
        #expect(MarkdownPreviewParser.blocks(from: "```\n![x](/tmp/a.mp4)\n```").map(\.kind) == [.code])
    }

    @Test
    func remoteMediaIsNeverAMediaBlock() {
        // Image syntax keeps the existing (non-fetching) image fallback;
        // a plain link stays an ordinary link.
        #expect(MarkdownPreviewParser.blocks(from: "![x](https://example.com/a.mp4)").map(\.kind) == [.image])
        #expect(MarkdownPreviewParser.blocks(from: "[x](https://example.com/a.mp4)").map(\.kind) == [.paragraph])
    }

    @Test
    func picturesAreUnaffected() {
        #expect(MarkdownPreviewParser.blocks(from: "![shot](/tmp/a.png)").map(\.kind) == [.image])
        #expect(MarkdownPreviewParser.blocks(from: "[report](/tmp/a.pdf)").map(\.kind) == [.paragraph])
    }

    // A model writing the `<…>` half of `![](</path with spaces.png>)` on its
    // own used to leave the raw path on screen (video-studio replies with
    // "Application Support" paths, 2026-10-07).
    @Test
    func standaloneAngleBracketLocalPathBecomesAnImageLine() {
        let path = "/Users/me/Library/Application Support/WillDeep/a b.png"
        let normalized = AgentMarkdownNormalizer.normalizedForChatRendering("首帧：\n\n<\(path)>\n\n完毕")
        #expect(normalized == "首帧：\n\n![](<\(path)>)\n\n完毕")
        #expect(MarkdownPreviewParser.blocks(from: normalized).map(\.kind) == [.paragraph, .image, .paragraph])
    }

    @Test
    func angleBracketLinesThatAreNotLocalMediaStayUntouched() {
        for line in [
            "<https://example.com/a.png>",
            "</div>",
            "<relative/a.png>",
            "</Users/me/notes.txt>",
            "看这里 </Users/me/a.png> 的图",
        ] {
            #expect(AgentMarkdownNormalizer.standaloneAngleBracketMediaLine(line) == nil, "\(line)")
        }
        let fenced = "```\n</Users/me/a.png>\n```"
        #expect(AgentMarkdownNormalizer.normalizedForChatRendering(fenced) == fenced)
    }

    @Test
    func standaloneAngleBracketAudioPathRendersAsMedia() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let voice = try fixture.file("Application Support/voice.wav")
        let content = "一句配音：\n\n<\(voice.path)>"

        let references = AgentTranscriptMediaFingerprint.parseReferences(in: content)
        #expect(references.map(\.kind) == [.audio])
        #expect(references.first?.source == voice.path)

        let rendered = render(content)
        let payloads = mediaPayloads(in: rendered)
        #expect(payloads.map(\.kind) == [.audio])
        #expect(payloads.first?.url == voice.standardizedFileURL)
    }

    // MARK: - Formatter output

    @Test
    func playableVideoRendersAPlaceholderAttachmentWithACaption() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let clip = try fixture.file("clip.mp4")
        let rendered = render("视频如下：\n\n![产品演示](\(clip.path))\n\n完毕")

        let payloads = mediaPayloads(in: rendered)
        #expect(payloads.count == 1)
        #expect(payloads.first?.kind == .video)
        #expect(payloads.first?.url == clip.standardizedFileURL)
        let location = try #require(firstLocation(of: .agentChatHistoryMediaID, in: rendered))
        #expect((rendered.string as NSString).character(at: location) == 0xFFFC)
        let attachment = rendered.attribute(.attachment, at: location, effectiveRange: nil) as? NSTextAttachment
        #expect(attachment?.attachmentCell is AgentTranscriptMediaAttachmentCell)
        #expect(rendered.string.contains("产品演示"))
    }

    @Test
    func audioLinkRendersACompactBar() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let song = try fixture.file("song.m4a")
        let rendered = render("听一下：\n\n[试听](\(song.path))")

        let location = try #require(firstLocation(of: .agentChatHistoryMediaID, in: rendered))
        let attachment = rendered.attribute(.attachment, at: location, effectiveRange: nil) as? NSTextAttachment
        let cell = try #require(attachment?.attachmentCell as? AgentTranscriptMediaAttachmentCell)
        #expect(cell.payload.kind == .audio)
        #expect(cell.cellSize().height == AgentTranscriptMediaControlMetrics.barHeight)
    }

    @Test
    func relativePathResolvesAgainstTheWorkspaceOnly() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        _ = try fixture.file("out/clip.mov")
        let content = "结果：\n\n![片段](out/clip.mov)"

        let withBase = render(content, mediaBaseURL: fixture.root)
        #expect(mediaPayloads(in: withBase).count == 1)

        let withoutBase = render(content, mediaBaseURL: nil)
        #expect(mediaPayloads(in: withoutBase).isEmpty)
        #expect(withoutBase.string.contains(L10n.TranscriptMedia.fileNotFound))
    }

    @Test
    func missingFileDegradesToALineWithAShowInFinderLink() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("gone.mp4")
        let rendered = render("看：\n\n![](\(missing.path))")

        #expect(mediaPayloads(in: rendered).isEmpty)
        #expect(rendered.string.contains("gone.mp4"))
        #expect(rendered.string.contains(L10n.TranscriptMedia.fileNotFound))
        let revealLocation = try #require(firstLocation(of: .agentChatHistoryMediaRevealPath, in: rendered))
        let revealPath = rendered.attribute(.agentChatHistoryMediaRevealPath, at: revealLocation, effectiveRange: nil) as? String
        #expect(revealPath == fixture.root.standardizedFileURL.path)
    }

    @Test
    func unplayableFormatDegradesAndRevealsTheFileItself() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let avi = try fixture.file("old.avi")
        let rendered = render("旧格式：\n\n[录像](\(avi.path))")

        #expect(mediaPayloads(in: rendered).isEmpty)
        #expect(rendered.string.contains(L10n.TranscriptMedia.unsupportedFormat))
        let revealLocation = try #require(firstLocation(of: .agentChatHistoryMediaRevealPath, in: rendered))
        let revealPath = rendered.attribute(.agentChatHistoryMediaRevealPath, at: revealLocation, effectiveRange: nil) as? String
        #expect(revealPath == avi.standardizedFileURL.path)
    }

    @Test
    func remoteMediaNeverProducesAPlaceholder() {
        let rendered = render("远程：\n\n![clip](https://example.com/\(UUID().uuidString).mp4)")
        #expect(mediaPayloads(in: rendered).isEmpty)
        #expect(firstLocation(of: .agentChatHistoryMediaRevealPath, in: rendered) == nil)
    }

    @Test
    func twoMessagesEmbeddingTheSameFileGetIndependentPlaceholders() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let clip = try fixture.file("same.mp4")
        let rendered = AgentChatHistoryRenderer.render(
            messages: [
                AgentMessage(role: .assistant, content: "第一次：\n\n![a](\(clip.path))\n\n![b](\(clip.path))"),
                AgentMessage(role: .user, content: "再发一次"),
                AgentMessage(role: .assistant, content: "第二次：\n\n![c](\(clip.path))"),
            ],
            isDark: false
        )
        let ids = placeholderKeys(in: rendered)
        #expect(ids.count == 3)
        #expect(Set(ids).count == 3)
    }

    // MARK: - Cache keys

    @Test
    func rendererCacheNoticesTheFileAppearing() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let later = fixture.root.appendingPathComponent("later.mp4")
        let message = AgentMessage(role: .assistant, content: "稍后生成：\n\n![](\(later.path))")

        let before = AgentChatHistoryRenderer.render(messages: [message], isDark: false)
        #expect(mediaPayloads(in: before).isEmpty)

        try Data([0x00, 0x01]).write(to: later)
        let after = AgentChatHistoryRenderer.render(messages: [message], isDark: false)
        #expect(mediaPayloads(in: after).count == 1)
    }

    @Test
    func fingerprintChangesWithFileExistenceAndModification() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let clip = fixture.root.appendingPathComponent("fp.mp4")
        let message = AgentMessage(role: .assistant, content: "看：\n\n![](\(clip.path))")

        let missing = fingerprint(message)
        try Data([0x00]).write(to: clip)
        let present = fingerprint(message)
        #expect(missing != present)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
            ofItemAtPath: clip.path
        )
        let touched = fingerprint(message)
        #expect(touched != present)
        #expect(fingerprint(message) == touched)
    }

    @Test
    func textViewFingerprintNoticesTheFileAppearing() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let later = fixture.root.appendingPathComponent("view-later.m4a")
        let messages = [AgentMessage(role: .assistant, content: "音频：\n\n[录音](\(later.path))")]
        let view = AgentChatHistoryNSTextView()
        view.setFrameSize(NSSize(width: 700, height: 400))

        view.applyMessages(messages, isDark: false)
        let storage = try #require(view.textStorage)
        #expect(mediaPayloads(in: storage).isEmpty)

        try Data([0x00]).write(to: later)
        view.applyMessages(messages, isDark: false)
        #expect(mediaPayloads(in: storage).count == 1)
    }

    // MARK: - Copy and search

    @Test
    func copyingAcrossAPlayerRestoresTheMarkdownLine() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let clip = try fixture.file("copy.mp4")
        let markdown = "![演示](\(clip.path))"
        let rendered = render("开头\n\n\(markdown)\n\n结尾")

        let plain = AgentTranscriptCopySubstitution.plainText(of: rendered)
        // Role avatars are attachments too; exactly the player's U+FFFC goes.
        #expect(occurrences(of: "\u{FFFC}", in: rendered.string) - occurrences(of: "\u{FFFC}", in: plain) == 1)
        #expect(occurrences(of: markdown, in: plain) == 1)
        #expect(plain.contains("开头"))
        #expect(plain.contains("结尾"))

        // Selecting only the caption still copies the whole reference.
        let captionRange = (rendered.string as NSString).range(of: "演示")
        let partial = AgentTranscriptCopySubstitution.plainText(of: rendered.attributedSubstring(from: captionRange))
        #expect(partial == markdown)
    }

    @Test
    func degradedLinesCopyBackAsMarkdownToo() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let markdown = "[录音](\(fixture.root.appendingPathComponent("nope.wav").path))"
        let rendered = render("说明\n\n\(markdown)")
        let plain = AgentTranscriptCopySubstitution.plainText(of: rendered)
        #expect(plain.contains(markdown))
        #expect(!plain.contains(L10n.TranscriptMedia.fileNotFound))
    }

    @Test
    func transcriptCopyWritesTheMarkdownToBothPasteboardFlavors() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let clip = try fixture.file("pb.mp4")
        let markdown = "![片段](\(clip.path))"
        let view = AgentChatHistoryNSTextView()
        view.setFrameSize(NSSize(width: 700, height: 400))
        view.applyMessages([AgentMessage(role: .assistant, content: "前\n\n\(markdown)\n\n后")], isDark: false)
        view.setSelectedRange(NSRange(location: 0, length: view.textStorage?.length ?? 0))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("agent-transcript-media-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let legacyString = NSPasteboard.PasteboardType("NSStringPboardType")
        #expect(view.writeSelection(to: pasteboard, type: legacyString))
        let plain = try #require(pasteboard.string(forType: legacyString))
        #expect(plain.contains(markdown))
        let storageString = view.textStorage?.string ?? ""
        #expect(occurrences(of: "\u{FFFC}", in: storageString) - occurrences(of: "\u{FFFC}", in: plain) == 1)

        pasteboard.clearContents()
        #expect(view.writeSelection(to: pasteboard, type: .rtf))
        let rtf = try #require(pasteboard.data(forType: .rtf))
        let decoded = try NSAttributedString(
            data: rtf,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
        #expect(decoded.string.contains(markdown))
    }

    @Test
    func searchNeverMatchesThePlaceholderButFindsTheCaption() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let clip = try fixture.file("find-me.mp4")
        let rendered = render("找：\n\n![](\(clip.path))")
        #expect(AgentTranscriptSearch.matchRanges(in: rendered.string, query: "\u{FFFC}").isEmpty)
        #expect(AgentTranscriptSearch.matchRanges(in: "a\u{FFFC}b", query: "\u{FFFC}b").isEmpty)
        #expect(AgentTranscriptSearch.matchRanges(in: rendered.string, query: "find-me.mp4").count == 1)
    }

    // MARK: - Streaming and geometry

    @Test
    func streamingPlaceholderNamesTheFile() throws {
        let reference = try #require(MarkdownInlineMedia.parseStandaloneMediaLine("[会议](/tmp/a.m4a)"))
        let label = AgentTranscriptMediaHistoryRenderer.streamingPlaceholderLabel(for: reference)
        #expect(label.contains("会议"))
        #expect(label == "♪ " + L10n.TranscriptMedia.streamingAudio("会议"))
    }

    @Test
    func streamingBubbleShowsTheNameAndNeverAnAttachment() throws {
        let fixture = try MediaFixture()
        defer { fixture.remove() }
        let clip = try fixture.file("streaming.mp4")
        let rendered = AgentAssistantMarkdownRenderer.render(
            "生成好了：\n\n![成片](\(clip.path))",
            isDark: false
        )
        let text = String(rendered.characters)
        #expect(text.contains(L10n.TranscriptMedia.streamingVideo("成片")))
        #expect(!text.contains("\u{FFFC}"))
    }

    @Test
    func videoKeepsItsAspectRatioInsideThePictureCap() {
        let budget = AgentTranscriptMediaLayout.widthBudget(layoutWidth: 1040)
        #expect(budget == AgentTranscriptMediaMetrics.maxDisplayWidth)

        // Picture keeps its ratio; the control strip is added underneath.
        let bar = AgentTranscriptMediaControlMetrics.barHeight
        let unknown = AgentTranscriptMediaLayout.displaySize(kind: .video, presentationSize: nil, widthBudget: 560)
        #expect(unknown == NSSize(width: 560, height: 315 + bar))

        let portrait = AgentTranscriptMediaLayout.displaySize(
            kind: .video,
            presentationSize: CGSize(width: 1080, height: 1920),
            widthBudget: 560
        )
        #expect(portrait.height == AgentTranscriptMediaMetrics.maxVideoHeight + bar)
        #expect(portrait.width == (AgentTranscriptMediaMetrics.maxVideoHeight * 1080 / 1920).rounded())

        let audio = AgentTranscriptMediaLayout.displaySize(kind: .audio, presentationSize: nil, widthBudget: 400)
        #expect(audio == NSSize(width: 400, height: bar))
    }

    @Test
    func mediaUsesTheSameColumnCapAsPictures() {
        #expect(AgentTranscriptMediaMetrics.maxDisplayWidth == MarkdownInlineImage.maxDisplayWidth)
        #expect(AgentTranscriptMediaMetrics.maxVideoHeight == MarkdownInlineImage.maxDisplayHeight)
    }

    @Test
    func narrowColumnsNeverSqueezeThePlayerBelowItsControls() {
        #expect(AgentTranscriptMediaLayout.widthBudget(layoutWidth: 200) == AgentTranscriptMediaMetrics.minimumWidth)
    }

    // MARK: - Helpers

    private func render(_ content: String, mediaBaseURL: URL? = nil) -> NSAttributedString {
        AgentChatHistoryRenderer.render(
            messages: [AgentMessage(role: .assistant, content: content)],
            isDark: false,
            mediaBaseURL: mediaBaseURL
        )
    }

    private func fingerprint(_ message: AgentMessage) -> Int {
        var hasher = Hasher()
        AgentTranscriptMediaFingerprint.combine(message: message, baseURL: nil, into: &hasher)
        return hasher.finalize()
    }

    private func mediaPayloads(in attributed: NSAttributedString) -> [AgentTranscriptMediaPayload] {
        var payloads: [AgentTranscriptMediaPayload] = []
        attributed.enumerateAttribute(
            .agentChatHistoryMedia,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            if let payload = value as? AgentTranscriptMediaPayload { payloads.append(payload) }
        }
        return payloads
    }

    private func placeholderKeys(in attributed: NSAttributedString) -> [String] {
        var keys: [String] = []
        attributed.enumerateAttribute(
            .agentChatHistoryMediaID,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            guard let local = value as? String else { return }
            let message = attributed.attribute(.agentChatHistoryMessageID, at: range.location, effectiveRange: nil) as? String
            keys.append("\(message ?? "")#\(local)")
        }
        return keys
    }

    private func firstLocation(of key: NSAttributedString.Key, in attributed: NSAttributedString) -> Int? {
        var found: Int?
        attributed.enumerateAttribute(key, in: NSRange(location: 0, length: attributed.length)) { value, range, stop in
            if value != nil {
                found = range.location
                stop.pointee = true
            }
        }
        return found
    }
}

/// A throwaway folder of stub media files; each test removes it in a
/// `defer`. The formatter only checks that the file exists and has a
/// playable extension, so a few bytes stand in for a real clip.
struct MediaFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-transcript-media-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func file(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x00, 0x00, 0x00, 0x18]).write(to: url)
        return url
    }
}
