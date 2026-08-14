//
//  AppRelaunch.swift
//  WillDeep
//
//  切换界面语言后需要重启才能生效(Bundle 的 .lproj 在进程启动时就定住
//  了)。让用户自己「退出 → 再打开」摩擦太大,这里提供一个「立即重启」:
//  先 fork 一个守候进程等本进程真正退出,再 `open` 回自己。
//
//  为什么不是 `sleep 1; open`:退出可能被未保存的编辑器、正在跑的 Agent
//  卡住,固定睡眠要么太短(open 撞上仍在运行的旧实例,LaunchServices 只会
//  把旧窗口拿到前台)要么太长(用户干等)。改成轮询父进程 pid,退出即拉起。
//
//  命令通过 `sh -c '…' sh <pid> <path>` 的位置参数传入,路径永远不进
//  脚本正文,含空格/引号的 bundle 路径也不会被 shell 重新解析。
//

import AppKit
import Foundation

@MainActor
enum AppRelaunch {
    /// 守候脚本:$1 = 旧进程 pid,$2 = app bundle 路径。
    /// `kill -0` 只探测进程是否还在,不发真实信号。
    nonisolated static let watchdogScript = """
    while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
    exec /usr/bin/open "$2"
    """

    /// 构造 `/bin/sh` 的参数列表。抽成纯函数是为了能在单测里断言
    /// 「路径以独立参数传递、没有被拼进脚本正文」。
    nonisolated static func relaunchArguments(pid: Int32, bundlePath: String) -> [String] {
        ["-c", watchdogScript, "sh", String(pid), bundlePath]
    }

    /// 拉起守候进程并请求退出。`NSApp.terminate` 走正常退出流程,所以
    /// 未保存的编辑器仍会弹确认框——用户取消的话本进程不退出,守候进程
    /// 就一直等着;这属于可接受的悬挂(它只在轮询 sleep,几乎不耗资源,
    /// 且用户下次真正退出 App 时它会把 App 再拉起一次)。
    ///
    /// - Returns: 守候进程是否成功拉起。失败时不发退出请求,让调用方
    ///   保留「请手动重启」的提示,而不是把 App 关掉却起不来。
    @discardableResult
    static func relaunch() -> Bool {
        let bundlePath = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = relaunchArguments(
            pid: ProcessInfo.processInfo.processIdentifier,
            bundlePath: bundlePath
        )
        do {
            try process.run()
        } catch {
            NSLog("[AppRelaunch] failed to spawn relaunch watchdog: \(error)")
            return false
        }
        NSApp.terminate(nil)
        return true
    }
}
