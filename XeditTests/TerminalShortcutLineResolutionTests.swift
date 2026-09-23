import Foundation
import SwiftTerm
import Testing
@testable import WillDeep

/// Shell line editors (fish, zsh, bash) turn ECHO off and draw the line
/// themselves, so the recorder sees them as echo-off input. These tests drive
/// a real SwiftTerm grid the way a shell does and check that the recorder
/// keeps what the screen showed, not the raw Tab/arrow keystrokes.
@MainActor
@Suite
struct TerminalShortcutLineResolutionTests {
    private static let tab: [UInt8] = [0x09]
    private static let enter: [UInt8] = [0x0D]
    private static let upArrow: [UInt8] = [0x1B, 0x5B, 0x41]

    @Test("Tab completion is recorded as the completed command, not ssh + Tab")
    func tabCompletionRecordsCompletedCommand() throws {
        let shell = ShellSession()
        shell.type("ssh ")
        shell.press(Self.tab)
        shell.show("root@h1.niuwoai.com ")
        shell.press(Self.enter)
        shell.show("\r\n")

        let shortcut = try #require(shell.finish())
        #expect(shortcut.eventTexts == ["ssh root@h1.niuwoai.com ", "\r"])
        #expect(!shortcut.hasProtectedInput)
    }

    @Test("A password prompt that draws nothing stays protected")
    func silentPasswordStaysProtected() throws {
        let shell = ShellSession(prompt: "Password: ")
        for character in "hunter2" {
            shell.press(Array(String(character).utf8))
        }
        shell.press(Self.enter)
        shell.show("\r\n")

        let shortcut = try #require(shell.finish())
        let protected = try #require(shortcut.events.first)
        #expect(protected.requiresEchoOff)
        #expect(protected.resolvedBytes() == Array("hunter2".utf8))
        #expect(shortcut.eventTexts.last == "\r")
    }

    @Test("A masked password prompt stays protected")
    func maskedPasswordStaysProtected() throws {
        let shell = ShellSession(prompt: "Token: ")
        for character in "s3cret" {
            shell.press(Array(String(character).utf8))
            shell.show("*")
        }
        shell.press(Self.enter)
        shell.show("\r\n")

        let shortcut = try #require(shell.finish())
        #expect(shortcut.events.first?.requiresEchoOff == true)
        #expect(shortcut.events.first?.resolvedBytes() == Array("s3cret".utf8))
    }

    @Test("An autosuggestion right of the cursor is not recorded")
    func autosuggestionIsDropped() throws {
        let shell = ShellSession()
        shell.type("git status")
        // fish draws the suggestion after the cursor, then moves back.
        shell.show(" --short\u{1B}[8D")
        shell.press(Self.enter)
        // On execute fish repaints the line without the suggestion.
        shell.show("\u{1B}[K\r\n")

        let shortcut = try #require(shell.finish())
        #expect(shortcut.eventTexts == ["git status", "\r"])
    }

    @Test("Enter that accepts a pager candidate does not split the command")
    func pagerAcceptStaysOneLine() throws {
        let shell = ShellSession()
        shell.type("ssh ")
        shell.press(Self.tab)
        // Common prefix, then the pager below the line, then back up.
        shell.show("root@h\u{1B}7\r\n  root@h1.niuwoai.com  root@h2.niuwoai.com\u{1B}8")
        shell.press(Self.tab)
        shell.show("1.niuwoai.com")
        shell.press(Self.enter) // accepts the candidate
        shell.show("\u{1B}[J ")
        shell.press(Self.enter) // runs the line
        shell.show("\r\n")

        let shortcut = try #require(shell.finish())
        #expect(shortcut.eventTexts == ["ssh root@h1.niuwoai.com ", "\r"])
    }

    @Test("A pager that scrolls the prompt up still resolves the line")
    func pagerScrollingPromptResolves() throws {
        let shell = ShellSession(rows: 4, prompt: "a\r\nb\r\nc\r\n~> ")
        shell.type("ssh ")
        shell.press(Self.tab)
        // The prompt sits on the last row; the pager scrolls it up by one.
        shell.show("root@h\r\n  root@h1  root@h2\u{1B}[1A\r\u{1B}[13C")
        shell.press(Self.tab)
        shell.show("1.niuwoai.com")
        shell.press(Self.enter)
        shell.show("\u{1B}[J ")
        shell.press(Self.enter)
        shell.show("\r\n")

        let shortcut = try #require(shell.finish())
        #expect(shortcut.eventTexts == ["ssh root@h1.niuwoai.com ", "\r"])
    }

    @Test("History recall records the recalled command")
    func historyRecallResolves() throws {
        let shell = ShellSession()
        shell.press(Self.upArrow)
        shell.show("ssh root@h1.niuwoai.com")
        shell.press(Self.enter)
        shell.show("\r\n")

        let shortcut = try #require(shell.finish())
        #expect(shortcut.eventTexts == ["ssh root@h1.niuwoai.com", "\r"])
    }

    @Test("A fish abbreviation records its expansion")
    func abbreviationExpansionResolves() throws {
        let shell = ShellSession()
        shell.type("gco", echo: true)
        shell.press(Array(" ".utf8))
        shell.show("\r~> git checkout ")
        shell.type("main")
        shell.press(Self.enter)
        shell.show("\r\n")

        let shortcut = try #require(shell.finish())
        #expect(shortcut.eventTexts == ["git checkout main", "\r"])
    }

    @Test("A command that wraps across rows resolves as one line")
    func wrappedCommandResolves() throws {
        let shell = ShellSession(columns: 20, prompt: "rocky@mac ~/Site> ")
        shell.type("ssh ")
        shell.press(Self.tab)
        shell.show("root@h1.niuwoai.com ")
        shell.press(Self.enter)
        shell.show("\r\n")

        let shortcut = try #require(shell.finish())
        #expect(shortcut.eventTexts == ["ssh root@h1.niuwoai.com ", "\r"])
    }

    @Test("Wide characters are read once")
    func wideCharactersResolve() throws {
        let shell = ShellSession()
        shell.type("cd 文档")
        shell.press(Self.tab)
        shell.show("/")
        shell.press(Self.enter)
        shell.show("\r\n")

        let shortcut = try #require(shell.finish())
        #expect(shortcut.eventTexts == ["cd 文档/", "\r"])
    }

    @Test("A right prompt is not part of the command")
    func rightPromptIsIgnored() throws {
        let shell = ShellSession(prompt: "~> \u{1B}7\u{1B}[55G12:00\u{1B}8")
        shell.type("ls sr")
        shell.press(Self.tab)
        shell.show("c/")
        shell.press(Self.enter)
        shell.show("\r\n")

        let shortcut = try #require(shell.finish())
        #expect(shortcut.eventTexts == ["ls src/", "\r"])
    }

    @Test("Text after the cursor keeps the line protected")
    func cursorInsideLineFallsBack() throws {
        let shell = ShellSession()
        shell.type("ssh")
        // zsh history-beginning-search: the match is shown, the cursor stays.
        shell.press(Self.upArrow)
        shell.show(" root@h1\u{1B}[8D")
        shell.press(Self.enter)
        shell.show("\r\n")

        let shortcut = try #require(shell.finish())
        #expect(shortcut.events.first?.requiresEchoOff == true)
        #expect(shortcut.events.first?.resolvedBytes() == Array("ssh".utf8) + Self.upArrow)
    }

    @Test("A completion that lands after Enter keeps the line protected")
    func lateCompletionFallsBack() throws {
        let shell = ShellSession()
        shell.type("cd /va")
        shell.press(Self.tab)
        shell.press(Self.enter)
        // A remote shell echoes the completion only after Enter was sent.
        shell.show("r/\r\n")

        let shortcut = try #require(shell.finish())
        #expect(shortcut.events.first?.requiresEchoOff == true)
        #expect(shortcut.events.first?.resolvedBytes() == Array("cd /va".utf8) + Self.tab)
    }

    @Test("A completed line that was never submitted is recorded as shown")
    func unsubmittedLineUsesScreen() throws {
        let shell = ShellSession()
        shell.type("ssh ")
        shell.press(Self.tab)
        shell.show("root@h1.niuwoai.com ")

        let shortcut = try #require(shell.finish())
        #expect(shortcut.eventTexts == ["ssh root@h1.niuwoai.com "])
    }

    @Test("Password after a resolved command stays protected")
    func commandThenPassword() throws {
        let shell = ShellSession()
        shell.type("ssh ")
        shell.press(Self.tab)
        shell.show("root@h1.niuwoai.com ")
        shell.press(Self.enter)
        shell.show("\r\nroot@h1.niuwoai.com's password: ")
        for character in "pw" {
            shell.press(Array(String(character).utf8))
        }
        shell.press(Self.enter)
        shell.show("\r\n")

        let shortcut = try #require(shell.finish())
        #expect(shortcut.events.count == 4)
        #expect(shortcut.eventTexts[0] == "ssh root@h1.niuwoai.com ")
        #expect(shortcut.events[2].requiresEchoOff)
        #expect(shortcut.events[2].resolvedBytes() == Array("pw".utf8))
    }

    @Test("Typed keys are classified by what they can do to the line")
    func typedLineClassification() {
        let completion = TerminalShortcutTypedLine(bytes: Array("ssh ".utf8) + Self.tab)
        #expect(completion.requiredText == "ssh ")
        #expect(completion.hasContextKeys)
        #expect(completion.mayOpenPager)

        let corrected = TerminalShortcutTypedLine(bytes: Array("lx".utf8) + [0x7F] + Array("s".utf8))
        #expect(corrected.requiredText == "ls")
        #expect(!corrected.hasContextKeys)

        let cleared = TerminalShortcutTypedLine(bytes: Array("oops".utf8) + [0x15] + Array("ls".utf8))
        #expect(cleared.requiredText == "ls")
        #expect(!cleared.hasContextKeys)

        let history = TerminalShortcutTypedLine(bytes: Self.upArrow)
        #expect(history.hasContextKeys)
        #expect(!history.mayOpenPager)

        let shiftTab = TerminalShortcutTypedLine(bytes: [0x1B, 0x5B, 0x5A])
        #expect(shiftTab.mayOpenPager)
    }
}

/// A shell on a real SwiftTerm grid. `press` is the user's key reaching the
/// recorder (which sees the screen as it was before the key); `show` is the
/// shell drawing output.
@MainActor
private final class ShellSession {
    let terminal: Terminal
    let recorder = TerminalShortcutRecorder(startedAt: Date(timeIntervalSince1970: 0))
    private let delegate = SilentTerminalDelegate()
    private var clock: TimeInterval = 1

    init(columns: Int = 60, rows: Int = 10, prompt: String = "~> ") {
        terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: columns, rows: rows, scrollback: 100))
        show(prompt)
    }

    var screen: AgentTerminalShortcutScreen {
        AgentTerminalShortcutScreen(terminal: terminal, isShowingLiveBottom: true)
    }

    func press(_ bytes: [UInt8], echoEnabled: Bool = false) {
        clock += 0.2
        recorder.record(data: bytes, echoEnabled: echoEnabled, now: Date(timeIntervalSince1970: clock), screen: screen)
    }

    /// Types one key at a time; the line editor echoes each one.
    func type(_ text: String, echo: Bool = true) {
        for character in text {
            press(Array(String(character).utf8))
            if echo { show(String(character)) }
        }
    }

    func show(_ text: String) {
        terminal.feed(text: text)
        if recorder.isAwaitingSubmittedLine {
            recorder.screenDidUpdate(screen)
        }
    }

    func finish() -> TerminalShortcut? {
        recorder.finish(title: "Shell", finishedAt: Date(timeIntervalSince1970: clock + 1), screen: screen)
    }
}

private final class SilentTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

private extension TerminalShortcut {
    var eventTexts: [String] {
        events.map { String(decoding: $0.bytes, as: UTF8.self) }
    }
}
