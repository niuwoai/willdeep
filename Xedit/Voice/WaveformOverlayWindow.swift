//
//  WaveformOverlayWindow.swift
//  WillDeep
//
//  1.86.0 push-to-talk 浮窗。按住 mic 时屏幕右下角浮出一个毛玻璃小窗,
//  里面是 5 根随 audioLevel 起伏的 bar;松开切转录态时变成旋转 spinner;
//  结束/失败/取消时整体淡出。源代码骨架从 ~/Sites/fastv 的 WaveformView
//  搬来,删掉 AI 修正相关分支、不依赖 UserPreferences,改成固定 240x80
//  尺寸 + bottomCenter 位置。窗口 ignoresMouseEvents,不打扰用户操作。
//

import SwiftUI
import AppKit
import Combine

enum WaveformOverlayState: Equatable {
    case recording
    case transcribing
}

@MainActor
final class WaveformOverlayWindowManager: ObservableObject {
    static let shared = WaveformOverlayWindowManager()

    @Published var audioLevel: Float = 0.0
    @Published var state: WaveformOverlayState = .recording

    private var window: NSWindow?
    private var hostingView: NSHostingView<WaveformOverlayView>?
    private var hideTask: DispatchWorkItem?

    private init() {}

    func show() {
        hideTask?.cancel()
        hideTask = nil

        state = .recording
        audioLevel = 0.0

        if let existing = window {
            existing.orderFrontRegardless()
            return
        }

        let content = WaveformOverlayView(manager: self)
        let host = NSHostingView(rootView: content)
        let size = NSSize(width: 240, height: 80)
        host.frame = NSRect(origin: .zero, size: size)

        let frame = Self.frame(for: size)
        let win = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.contentView = host
        win.backgroundColor = .clear
        win.isOpaque = false
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        win.ignoresMouseEvents = true
        win.hasShadow = false
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false

        window = win
        hostingView = host
        win.orderFrontRegardless()
    }

    func setTranscribing() {
        state = .transcribing
        audioLevel = 0.0
    }

    func updateAudioLevel(_ level: Float) {
        guard state == .recording else { return }
        audioLevel = level
    }

    func hide() {
        hideTask?.cancel()
        guard let win = window else { return }
        let toClose = win
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            toClose.contentView = nil
            toClose.close()
            if self.window === toClose {
                self.window = nil
                self.hostingView = nil
            }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }

    private static func frame(for size: NSSize) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let s = screen else {
            return NSRect(origin: .zero, size: size)
        }
        let sf = s.frame
        let margin: CGFloat = 48
        let x = sf.midX - size.width / 2
        let y = sf.minY + margin
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

struct WaveformOverlayView: View {
    @ObservedObject var manager: WaveformOverlayWindowManager
    @State private var bars: [CGFloat] = [0.35, 0.55, 0.75, 0.55, 0.35]
    @State private var rotation: Double = 0
    @State private var containerScale: CGFloat = 0.8
    @State private var containerOpacity: Double = 0

    private let barColor: Color = .accentColor
    private let barWidth: CGFloat = 6
    private let barSpacing: CGFloat = 6
    private let maxBarHeight: CGFloat = 40
    private let spinnerSize: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 6)

            Group {
                switch manager.state {
                case .recording:
                    HStack(spacing: barSpacing) {
                        ForEach(0..<bars.count, id: \.self) { i in
                            RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            barColor.opacity(0.95),
                                            barColor.opacity(0.7),
                                            barColor.opacity(0.45),
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: barWidth, height: bars[i] * maxBarHeight)
                                .shadow(color: barColor.opacity(0.35), radius: 2)
                        }
                    }
                    .onAppear { animateBars() }
                    .onChange(of: manager.audioLevel) { _, level in
                        updateBars(level)
                    }
                    .transition(.scale.combined(with: .opacity))

                case .transcribing:
                    ZStack {
                        Circle()
                            .stroke(barColor.opacity(0.25), lineWidth: 2.5)
                            .frame(width: spinnerSize, height: spinnerSize)
                        Circle()
                            .trim(from: 0, to: 0.75)
                            .stroke(
                                AngularGradient(
                                    gradient: Gradient(colors: [
                                        barColor.opacity(1.0),
                                        barColor.opacity(0.8),
                                        barColor.opacity(0.4),
                                        barColor.opacity(0.1),
                                    ]),
                                    center: .center
                                ),
                                style: StrokeStyle(lineWidth: 2.6, lineCap: .round)
                            )
                            .frame(width: spinnerSize, height: spinnerSize)
                            .rotationEffect(.degrees(rotation))
                            .shadow(color: barColor.opacity(0.45), radius: 4)
                    }
                    .onAppear { startSpin() }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .id(manager.state)
        }
        .frame(width: 240, height: 80)
        .scaleEffect(containerScale)
        .opacity(containerOpacity)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                containerScale = 1.0
                containerOpacity = 1.0
            }
        }
    }

    private func animateBars() {
        let base: [CGFloat] = [0.35, 0.55, 0.75, 0.55, 0.35]
        for i in 0..<bars.count {
            let delay = Double(i) * 0.08
            let duration = 0.4 + Double(i) * 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
                    let v: CGFloat = 0.15
                    bars[i] = base[i] + CGFloat.random(in: -v...v)
                }
            }
        }
    }

    private func updateBars(_ level: Float) {
        let n = min(max(level, 0), 1)
        if bars.count >= 5 {
            bars[2] = CGFloat(n * 0.7 + 0.3)
            bars[1] = CGFloat(n * 0.5 + 0.3)
            bars[3] = CGFloat(n * 0.5 + 0.3)
            bars[0] = CGFloat(n * 0.4 + 0.2)
            bars[4] = CGFloat(n * 0.4 + 0.2)
        }
    }

    private func startSpin() {
        rotation = 0
        DispatchQueue.main.async {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}
