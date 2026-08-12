//
//  EditorTerminalFontResolutionTests.swift
//  WillDeepTests
//
//  Guard rails for the startup-path font id resolution: `byID` must resolve
//  built-in ids from its fixed table and Nerd Font ids by probing only the
//  named family — never by enumerating the installed font library (that
//  enumeration cost 0.3–0.9s before the app's first frame). Semantics must
//  match the old full-table lookup: an id pointing at an uninstalled font
//  still resolves to nil so `normalized()` falls back to the default.
//

import AppKit
import Testing
@testable import WillDeep

@Suite("终端字体 ID 解析（启动路径短路）")
struct EditorTerminalFontResolutionTests {

    @Test("内建字体 ID 从固定表解析出正确字体")
    func builtInIDsResolveFromFixedTable() {
        let builtIns: [EditorTerminalFont] = [.systemMono, .sfMono, .menlo, .monaco]
        for expected in builtIns {
            let resolved = EditorTerminalFont.byID(expected.id)
            #expect(resolved == expected)
        }
    }

    @Test("默认字体 ID 永远可解析")
    func preferredDefaultIDAlwaysResolves() {
        #expect(EditorTerminalFont.byID(EditorTerminalFont.preferredDefaultID) != nil)
    }

    @Test("指向未安装 Nerd Font 的 nf: ID 返回 nil")
    func missingDiscoveredNerdFontIDReturnsNil() {
        // A family name that cannot exist on any machine — the probe must
        // fail and byID must report "not installed", same as the old
        // full-enumeration lookup did.
        #expect(EditorTerminalFont.byID("nf:WillDeep Bogus Nerd Font 9F3A") == nil)
    }

    @Test("未知 ID 返回 nil")
    func unknownIDReturnsNil() {
        #expect(EditorTerminalFont.byID("totally-unknown-font-id") == nil)
        #expect(EditorTerminalFont.byID("") == nil)
    }

    @Test("normalized() 把未安装字体的设置回退到默认字体")
    func normalizedFallsBackForMissingFont() {
        var settings = EditorTerminalSettings.default
        settings.fontName = "nf:WillDeep Bogus Nerd Font 9F3A"
        let normalized = settings.normalized()
        #expect(normalized.fontName == EditorTerminalFont.preferredDefaultID)
    }

    @Test("normalized() 保留合法的内建字体选择")
    func normalizedKeepsValidBuiltInChoice() {
        var settings = EditorTerminalSettings.default
        settings.fontName = EditorTerminalFont.menlo.id
        #expect(settings.normalized().fontName == EditorTerminalFont.menlo.id)
    }

    @Test("短路解析与全量枚举表逐项一致")
    func shortCircuitAgreesWithFullEnumeration() {
        // `all` intentionally forces the Settings-only enumeration; every
        // entry it offers must round-trip through the short-circuit byID
        // with identical id / display name / PostScript name, or a font
        // picked in Settings would fail to resolve after relaunch.
        for font in EditorTerminalFont.all {
            let resolved = EditorTerminalFont.byID(font.id)
            #expect(resolved == font)
        }
    }
}
