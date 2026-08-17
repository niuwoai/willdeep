import AppKit
import Testing
@testable import WillDeep

/// 拖进输入框的文件必须变成附件,而不是被 NSTextView 当成一行路径文字插
/// 进缓冲区(那还会因为路径以 "/" 开头弹出斜杠命令面板,显示「没有匹配的
/// 命令」)。这里守的是「哪些拖放该被接管」和「接管后能不能取出内容」。
struct AgentComposerDropTests {
    /// 每个用例一块**唯一**的 pasteboard,不碰用户的剪贴板。
    ///
    /// 必须是 `withUniqueName()` 而不是固定名字:Swift Testing 并行跑用例,
    /// 共用一块命名 pasteboard 时,一个用例 `releaseGlobally()` 而另一个正
    /// 在 `readObjects` 会让 NSPasteboard 的类型缓存越界抛异常——那是
    /// Objective-C 异常,直接 abort 掉整个测试进程,一次带走一千多个无关
    /// 用例(它们全被记成 "crashed with signal abrt")。
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard.withUniqueName()
    }

    @Test("file and image flavors are taken over, plain text is left to the text view")
    func shouldHandleOnlyAttachableFlavors() {
        #expect(ComposerDropSupport.shouldHandle(types: [.fileURL]))
        #expect(ComposerDropSupport.shouldHandle(types: [.png]))
        #expect(ComposerDropSupport.shouldHandle(types: [.tiff]))
        // 拖一段文字进输入框,本来就该变成文字。
        #expect(!ComposerDropSupport.shouldHandle(types: [.string]))
        #expect(!ComposerDropSupport.shouldHandle(types: []))
        // 混合内容(Finder 拖文件通常同时带 string)仍然按附件处理。
        #expect(ComposerDropSupport.shouldHandle(types: [.string, .fileURL]))
    }

    @Test("dropped file URLs come back as file URLs")
    func readsFileURLs() throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        let first = URL(fileURLWithPath: "/tmp/willdeep-drop-a.png")
        let second = URL(fileURLWithPath: "/tmp/willdeep drop b.txt")
        // Finder 拖多个文件时给的是多个 pasteboard item,每个带一条 fileURL
        // ——`writeObjects([NSURL, NSURL])` 在自定义 pasteboard 上只落一条,
        // 模拟不出多选拖放。
        pasteboard.writeObjects([first, second].map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        })

        let urls = ComposerDropSupport.fileURLs(in: pasteboard)
        #expect(urls.map(\.path) == [first.path, second.path])
        pasteboard.releaseGlobally()
    }

    @Test("a pasteboard carrying only image bytes yields PNG data")
    func readsRawImageData() throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 2, height: 2))
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)

        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)

        // 浏览器/预览这类来源只给图片数据,没有文件本体。
        #expect(ComposerDropSupport.fileURLs(in: pasteboard).isEmpty)
        let png = try #require(ComposerDropSupport.imageData(in: pasteboard))
        // TIFF 被转成 PNG:魔数 89 50 4E 47。
        #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        pasteboard.releaseGlobally()
    }

    @Test("a text-only pasteboard offers nothing to attach")
    func textOnlyPasteboardHasNoAttachments() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("just some prose", forType: .string)

        #expect(ComposerDropSupport.fileURLs(in: pasteboard).isEmpty)
        #expect(ComposerDropSupport.imageData(in: pasteboard) == nil)
        pasteboard.releaseGlobally()
    }
}
