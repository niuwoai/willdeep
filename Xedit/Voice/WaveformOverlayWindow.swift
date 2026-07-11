//
//  WaveformOverlayWindow.swift
//  WillDeep
//
//  1.86.0 push-to-talk 浮窗。按住 mic 时屏幕右下角浮出一个毛玻璃小窗,
//  里面是 5 根随 audioLevel 起伏的 bar;松开切转录态时变成旋转 spinner;
//  结束/失败/取消时整体淡出。源代码骨架从 ~/Sites/fastv 的 WaveformView
//  搬来,删掉 AI 修正相关分支。1.89 起位置/尺寸/颜色重新接回 fastv 风格
//  设置。窗口 ignoresMouseEvents,不打扰用户操作。
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
            existing.contentView = nil
            existing.close()
            window = nil
            hostingView = nil
        }

        let content = WaveformOverlayView(manager: self)
        let host = NSHostingView(rootView: content)
        let preferences = UserPreferences.shared
        let size = preferences.waveformOverlayStyle.size
        host.frame = NSRect(origin: .zero, size: size)

        let frame = Self.frame(for: size, position: preferences.waveformOverlayPosition)
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

    private static func frame(
        for size: NSSize,
        position: WaveformOverlayWindowPosition
    ) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let s = screen else {
            return NSRect(origin: .zero, size: size)
        }
        let sf = s.frame
        let margin: CGFloat = 40
        let x: CGFloat
        let y: CGFloat

        switch position {
        case .topLeft:
            x = sf.minX + margin
            y = sf.maxY - size.height - margin
        case .topRight:
            x = sf.maxX - size.width - margin
            y = sf.maxY - size.height - margin
        case .bottomLeft:
            x = sf.minX + margin
            y = sf.minY + margin
        case .bottomRight:
            x = sf.maxX - size.width - margin
            y = sf.minY + margin
        case .bottomCenter:
            x = sf.midX - size.width / 2
            y = sf.minY + margin
        }

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

struct WaveformOverlayView: View {
    @ObservedObject var manager: WaveformOverlayWindowManager
    @ObservedObject private var preferences = UserPreferences.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var rotation: Double = 0
    @State private var containerScale: CGFloat = 0.8
    @State private var containerOpacity: Double = 0

    var body: some View {
        let style = preferences.waveformOverlayStyle
        let waveStyle = preferences.waveformOverlayWaveStyle
        let colorConfig = preferences.waveformOverlayColorStyle.colorConfig(for: colorScheme)
        let barColor = colorConfig.barColor
        let size = style.size
        let cornerRadius = preferences.waveformOverlayCornerStyle.radius(for: size)

        ZStack {
            background(config: colorConfig, cornerRadius: cornerRadius)

            Group {
                switch manager.state {
                case .recording:
                    Group {
                        if style.isMinimal {
                            let scale = 0.6 + CGFloat(manager.audioLevel) * 0.6
                            Circle()
                                .fill(
                                    RadialGradient(
                                        colors: [barColor, barColor.opacity(0.6)],
                                        center: .center,
                                        startRadius: 0,
                                        endRadius: 6
                                    )
                                )
                                .frame(width: 8, height: 8)
                                .scaleEffect(scale)
                                .shadow(color: barColor.opacity(0.5), radius: 3)
                                .animation(.easeOut(duration: 0.12), value: manager.audioLevel)
                        } else {
                            WaveformOverlayBars(
                                windowStyle: style,
                                waveStyle: waveStyle,
                                primaryColor: barColor,
                                accentColor: colorConfig.barAccentColor,
                                audioLevel: CGFloat(manager.audioLevel)
                            )
                        }
                    }
                    .padding(.horizontal, style.horizontalPadding)
                    .padding(.vertical, style.verticalPadding)
                    .transition(.scale.combined(with: .opacity))

                case .transcribing:
                    ZStack {
                        Circle()
                            .stroke(barColor.opacity(0.25), lineWidth: 2.5)
                            .frame(width: style.spinnerSize, height: style.spinnerSize)
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
                            .frame(width: style.spinnerSize, height: style.spinnerSize)
                            .rotationEffect(.degrees(rotation))
                            .shadow(color: barColor.opacity(0.45), radius: 4)
                    }
                    .padding(.horizontal, style.horizontalPadding)
                    .padding(.vertical, style.verticalPadding)
                    .onAppear { startSpin() }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .id(manager.state)
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(containerScale)
        .opacity(containerOpacity)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                containerScale = 1.0
                containerOpacity = 1.0
            }
        }
    }

    @ViewBuilder
    private func background(
        config: WaveformOverlayColorConfig,
        cornerRadius: CGFloat
    ) -> some View {
        if config.useMaterial {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(config.backgroundColor.opacity(config.backgroundOpacity))
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 6)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(config.backgroundColor.opacity(config.backgroundOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(config.borderColor, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 6)
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
