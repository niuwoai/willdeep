//
//  AuxiliaryWindowCloseShortcut.swift
//  WillDeep
//
//  1.85.0-rc14:把「独立 NSWindowController 起的辅助窗口要支持 Cmd+W
//  关窗」这件事抽成一个小帮手。
//
//  背景:WillDeep 的主菜单挂在 editor 窗口的 scene 上,而我们用
//  NSWindowController 单独 spawn 出来的辅助窗口(Markdown table detail、
//  transcript reader、single-message reader 之类)不在那条响应链里,
//  Cmd+W 默认就没人接,用户只能去点红绿灯关 —— 反映出来就是「打开了关
//  不掉」。
//
//  装一个本地 keyDown 监听把 Cmd+W / Opt+W(以及可选的 Esc)路由到
//  `performClose(_:)` 就能解决。和 Settings 窗口的
//  [SettingsKeyboardShortcutHandler](Xedit/EditorSettingsSupport.swift)
//  同一套路,但拆成函数以方便复用。
//

import AppKit

@MainActor
enum AuxiliaryWindowCloseShortcut {
    /// 给 `window` 装一个本地 keyDown 监听,Cmd+W / Opt+W 触发关窗;
    /// `closesOnEscape == true` 时无修饰键的 Esc 也关。返回 monitor token,
    /// 调用方需要在窗口关闭时(`windowWillClose` / `deinit`)用
    /// `NSEvent.removeMonitor(_:)` 摘掉,否则该 closure 会一直挂着
    /// `window` 的弱引用 + 一个全局事件 hook。
    static func install(on window: NSWindow, closesOnEscape: Bool) -> Any {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard let window, event.window === window else {
                return event
            }
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if chars == "w", modifiers.contains(.command) || modifiers.contains(.option) {
                window.performClose(nil)
                return nil
            }
            if closesOnEscape, event.keyCode == 53, modifiers.isEmpty {
                window.performClose(nil)
                return nil
            }
            return event
        } as Any
    }
}
