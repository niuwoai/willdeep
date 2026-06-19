//
//  ImageWorkflowTests.swift
//  WillDeepTests
//

import AppKit
import CoreGraphics
import Testing
@testable import WillDeep

@Suite(.serialized)
struct ImageWorkflowTests {
    @Test("built-in image workflows are registered in the workflow palette")
    func builtInImageWorkflowsAreRegistered() {
        let commands = Set(WorkflowRegistry.builtIn.map(\.slashCommand))
        for command in [
            "/image-convert",
            "/image-resize",
            "/image-crop",
            "/image-compress",
            "/image-bg-remove",
            "/image-trim-pad",
            "/image-watermark",
            "/image-ocr",
            "/image-redact",
            "/image-contact-sheet",
            "/image-palette",
            "/image-compare",
            "/image-alt-text",
            "/screenshot-to-code",
            "/video-subtitle-export",
        ] {
            #expect(commands.contains(command))
        }
    }

    @Test("image workflow parser keeps quoted paths and key-value options")
    func imageWorkflowParserHandlesQuotesAndOptions() {
        let parsed = ImageWorkflowSupport.parse(#""/tmp/My Shot.png" "hello world" position=tr opacity=0.5"#)
        #expect(parsed.positional == ["/tmp/My Shot.png", "hello world"])
        #expect(parsed.options["position"] == "tr")
        #expect(parsed.options["opacity"] == "0.5")
    }

    @Test("solid background removal and transparent trim shrink the canvas")
    func backgroundRemovalAndTrimWorkTogether() throws {
        let image = ImageWorkflowSupport.render(width: 6, height: 6, background: .white) { context in
            context.setFillColor(ImageWorkflowSupport.RGBAColor.black.nsColor.cgColor)
            context.fill(CGRect(x: 2, y: 2, width: 2, height: 2))
        }
        let transparent = ImageWorkflowSupport.removeSolidBackground(
            image,
            target: try ImageWorkflowSupport.parseColor("#ffffff"),
            tolerance: 0
        )
        let trimmed = ImageWorkflowSupport.trimTransparent(transparent)
        #expect(trimmed.width == 2)
        #expect(trimmed.height == 2)
    }
}
