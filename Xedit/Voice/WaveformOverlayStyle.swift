//
//  WaveformOverlayStyle.swift
//  WillDeep
//
//  fastv-derived style presets for the push-to-talk floating transcription bar.
//

import Foundation
import SwiftUI

struct WaveformOverlayColorConfig {
    let backgroundColor: Color
    let barColor: Color
    let barAccentColor: Color
    let borderColor: Color
    let backgroundOpacity: Double
    let useMaterial: Bool

    init(
        backgroundColor: Color,
        barColor: Color,
        barAccentColor: Color? = nil,
        borderColor: Color? = nil,
        backgroundOpacity: Double = 0.25,
        useMaterial: Bool = true
    ) {
        self.backgroundColor = backgroundColor
        self.barColor = barColor
        self.barAccentColor = barAccentColor ?? barColor
        self.borderColor = borderColor ?? Color.primary.opacity(0.08)
        self.backgroundOpacity = backgroundOpacity
        self.useMaterial = useMaterial
    }
}

enum WaveformOverlayWindowPosition: String, CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case bottomCenter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .topLeft: return L10n.Settings.Voice.overlayPositionTopLeft
        case .topRight: return L10n.Settings.Voice.overlayPositionTopRight
        case .bottomLeft: return L10n.Settings.Voice.overlayPositionBottomLeft
        case .bottomRight: return L10n.Settings.Voice.overlayPositionBottomRight
        case .bottomCenter: return L10n.Settings.Voice.overlayPositionBottomCenter
        }
    }
}

enum WaveformOverlayWindowStyle: String, CaseIterable, Identifiable {
    case minimal
    case compact
    case normal
    case large

    var id: String { rawValue }
    var isMinimal: Bool { self == .minimal }

    var displayName: String {
        switch self {
        case .minimal: return L10n.Settings.Voice.overlayStyleMinimal
        case .compact: return L10n.Settings.Voice.overlayStyleCompact
        case .normal: return L10n.Settings.Voice.overlayStyleNormal
        case .large: return L10n.Settings.Voice.overlayStyleLarge
        }
    }

    var size: CGSize {
        switch self {
        case .minimal: return CGSize(width: 24, height: 24)
        case .compact: return CGSize(width: 88, height: 32)
        case .normal: return CGSize(width: 108, height: 36)
        case .large: return CGSize(width: 128, height: 44)
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .minimal: return 4
        case .compact: return 8
        case .normal: return 10
        case .large: return 12
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .minimal: return 4
        case .compact: return 6
        case .normal: return 7
        case .large: return 8
        }
    }

    var barWidth: CGFloat {
        switch self {
        case .minimal: return 0
        case .compact: return 3.5
        case .normal: return 4
        case .large: return 4.5
        }
    }

    var barSpacing: CGFloat {
        switch self {
        case .minimal: return 0
        case .compact: return 3
        case .normal: return 3.5
        case .large: return 4
        }
    }

    var maxBarHeight: CGFloat {
        switch self {
        case .minimal: return 0
        case .compact: return 16
        case .normal: return 18
        case .large: return 24
        }
    }

    var spinnerSize: CGFloat {
        switch self {
        case .minimal: return 12
        case .compact: return 18
        case .normal: return 20
        case .large: return 24
        }
    }
}

enum WaveformOverlayCornerStyle: String, CaseIterable, Identifiable {
    case subtle
    case rounded
    case soft
    case capsule

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .subtle: return L10n.Settings.Voice.overlayCornerSubtle
        case .rounded: return L10n.Settings.Voice.overlayCornerRounded
        case .soft: return L10n.Settings.Voice.overlayCornerSoft
        case .capsule: return L10n.Settings.Voice.overlayCornerCapsule
        }
    }

    func radius(for size: CGSize) -> CGFloat {
        switch self {
        case .subtle: return 6
        case .rounded: return 12
        case .soft: return 18
        case .capsule: return min(size.width, size.height) / 2
        }
    }
}

enum WaveformOverlayWaveStyle: String, CaseIterable, Identifiable {
    case classic
    case equalizer
    case spectrum
    case pulse
    case digital
    case skyline
    case sine
    case cosine
    case ecg

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return L10n.Settings.Voice.overlayWaveClassic
        case .equalizer: return L10n.Settings.Voice.overlayWaveEqualizer
        case .spectrum: return L10n.Settings.Voice.overlayWaveSpectrum
        case .pulse: return L10n.Settings.Voice.overlayWavePulse
        case .digital: return L10n.Settings.Voice.overlayWaveDigital
        case .skyline: return L10n.Settings.Voice.overlayWaveSkyline
        case .sine: return L10n.Settings.Voice.overlayWaveSine
        case .cosine: return L10n.Settings.Voice.overlayWaveCosine
        case .ecg: return L10n.Settings.Voice.overlayWaveECG
        }
    }

    var usesContinuousPath: Bool {
        switch self {
        case .sine, .cosine, .ecg: return true
        case .classic, .equalizer, .spectrum, .pulse, .digital, .skyline: return false
        }
    }

    var barCount: Int {
        switch self {
        case .classic: return 5
        case .equalizer: return 9
        case .spectrum: return 13
        case .pulse: return 7
        case .digital: return 11
        case .skyline: return 9
        case .sine, .cosine, .ecg: return 0
        }
    }

    func barHeight(at index: Int, audioLevel: CGFloat) -> CGFloat {
        let level = min(max(audioLevel, 0), 1)
        let profile: [CGFloat]
        switch self {
        case .classic: profile = [0.36, 0.62, 1, 0.62, 0.36]
        case .equalizer: profile = [0.28, 0.55, 0.86, 0.48, 1, 0.66, 0.92, 0.52, 0.3]
        case .spectrum: profile = [0.2, 0.35, 0.52, 0.72, 0.9, 1, 0.86, 0.68, 0.48, 0.7, 0.5, 0.32, 0.2]
        case .pulse: profile = [0.18, 0.28, 0.58, 1, 0.58, 0.28, 0.18]
        case .digital: profile = [0.24, 0.48, 0.74, 0.4, 0.92, 0.62, 0.98, 0.45, 0.76, 0.5, 0.26]
        case .skyline: profile = [0.24, 0.42, 0.72, 1, 0.56, 0.84, 0.48, 0.7, 0.3]
        case .sine, .cosine, .ecg: return 0
        }
        let floor: CGFloat = self == .digital ? 0.18 : 0.12
        return floor + profile[index] * (0.25 + level * 0.75)
    }

    func barWidth(for style: WaveformOverlayWindowStyle) -> CGFloat {
        switch self {
        case .spectrum, .digital: return max(2, style.barWidth * 0.58)
        case .equalizer, .skyline: return max(2.5, style.barWidth * 0.78)
        case .classic, .pulse: return style.barWidth
        case .sine, .cosine, .ecg: return max(1.6, style.barWidth * 0.5)
        }
    }

    func spacing(for style: WaveformOverlayWindowStyle) -> CGFloat {
        switch self {
        case .spectrum, .digital: return max(1.5, style.barSpacing * 0.48)
        case .equalizer, .skyline: return max(2, style.barSpacing * 0.68)
        case .classic, .pulse: return style.barSpacing
        case .sine, .cosine, .ecg: return 0
        }
    }

    func normalizedSample(at progress: CGFloat, phase: CGFloat) -> CGFloat {
        let wrappedProgress = progress - floor(progress)
        switch self {
        case .sine:
            return sin(wrappedProgress * .pi * 4 + phase)
        case .cosine:
            return cos(wrappedProgress * .pi * 4 + phase)
        case .ecg:
            let shifted = wrappedProgress + phase / (.pi * 2)
            return ecgSample(at: shifted - floor(shifted))
        case .classic, .equalizer, .spectrum, .pulse, .digital, .skyline:
            return 0
        }
    }

    private func ecgSample(at progress: CGFloat) -> CGFloat {
        let points: [(CGFloat, CGFloat)] = [
            (0.00, 0.00), (0.22, 0.00),
            (0.29, 0.10), (0.34, -0.14),
            (0.39, 0.00), (0.43, 0.92),
            (0.47, -0.72), (0.52, 0.18),
            (0.60, 0.00), (1.00, 0.00),
        ]
        guard let segment = zip(points, points.dropFirst()).first(where: {
            progress >= $0.0.0 && progress <= $0.1.0
        }) else { return 0 }
        let start = segment.0
        let end = segment.1
        let distance = max(end.0 - start.0, 0.0001)
        let interpolation = (progress - start.0) / distance
        return start.1 + (end.1 - start.1) * interpolation
    }
}

struct WaveformOverlayBars: View {
    let windowStyle: WaveformOverlayWindowStyle
    let waveStyle: WaveformOverlayWaveStyle
    let primaryColor: Color
    let accentColor: Color
    let audioLevel: CGFloat

    var body: some View {
        Group {
            if waveStyle.usesContinuousPath {
                continuousSignal
            } else {
                barSignal
            }
        }
        .animation(.easeOut(duration: 0.12), value: audioLevel)
    }

    private var barSignal: some View {
        HStack(spacing: waveStyle.spacing(for: windowStyle)) {
            ForEach(0..<waveStyle.barCount, id: \.self) { index in
                let width = waveStyle.barWidth(for: windowStyle)
                RoundedRectangle(cornerRadius: width / 2, style: .continuous)
                    .fill(signalGradient)
                    .frame(
                        width: width,
                        height: waveStyle.barHeight(at: index, audioLevel: audioLevel) * windowStyle.maxBarHeight
                    )
                    .shadow(color: primaryColor.opacity(0.42), radius: 2)
            }
        }
    }

    private var continuousSignal: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                let phase = CGFloat(seconds.truncatingRemainder(dividingBy: 2.4) / 2.4) * .pi * 2
                let amplitude = max(2, size.height * (0.22 + min(max(audioLevel, 0), 1) * 0.28))
                let centerY = size.height / 2
                let sampleCount = max(80, Int(size.width * 2))
                var path = Path()

                for index in 0...sampleCount {
                    let progress = CGFloat(index) / CGFloat(sampleCount)
                    let x = progress * size.width
                    let sample = waveStyle.normalizedSample(at: progress, phase: phase)
                    let y = centerY - sample * amplitude
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }

                context.addFilter(.shadow(color: primaryColor.opacity(0.5), radius: 2))
                context.stroke(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [primaryColor, accentColor, primaryColor.opacity(0.82)]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: 0)
                    ),
                    style: StrokeStyle(
                        lineWidth: waveStyle.barWidth(for: windowStyle),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
        .frame(
            width: max(36, windowStyle.size.width - windowStyle.horizontalPadding * 2),
            height: windowStyle.maxBarHeight
        )
    }

    private var signalGradient: LinearGradient {
        LinearGradient(
            colors: [
                primaryColor.opacity(0.98),
                accentColor.opacity(0.78),
                primaryColor.opacity(0.42),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

enum WaveformOverlayWindowColorStyle: String, CaseIterable, Identifiable {
    case blue
    case purple
    case pink
    case green
    case orange
    case red
    case blackWhite
    case whiteBlack
    case skyGlass
    case mintCream
    case lavenderMist
    case peachSorbet
    case roseQuartz
    case lemonCream
    case aquaGlass
    case warmSand
    case darkGrayWhite
    case darkBlueCyan
    case darkPurplePink
    case darkGreenLime
    case darkRedCoral
    case darkGrayBlue
    case darkGrayGreen
    case darkGrayOrange
    case darkGrayPink
    case darkGrayPurple
    case darkGrayRed
    case darkGrayYellow
    case darkGrayCyan
    case quantumCyan
    case neonTokyo
    case auroraMint
    case ionStorm
    case plasmaCore
    case solarFlare
    case hologram
    case laserGrid
    case deepSpace
    case cyberSunset
    case lunarSignal
    case cosmicGrape

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blue: return L10n.Settings.Voice.overlayColorBlue
        case .purple: return L10n.Settings.Voice.overlayColorPurple
        case .pink: return L10n.Settings.Voice.overlayColorPink
        case .green: return L10n.Settings.Voice.overlayColorGreen
        case .orange: return L10n.Settings.Voice.overlayColorOrange
        case .red: return L10n.Settings.Voice.overlayColorRed
        case .blackWhite: return L10n.Settings.Voice.overlayColorBlackWhite
        case .whiteBlack: return L10n.Settings.Voice.overlayColorWhiteBlack
        case .skyGlass: return L10n.Settings.Voice.overlayColorSkyGlass
        case .mintCream: return L10n.Settings.Voice.overlayColorMintCream
        case .lavenderMist: return L10n.Settings.Voice.overlayColorLavenderMist
        case .peachSorbet: return L10n.Settings.Voice.overlayColorPeachSorbet
        case .roseQuartz: return L10n.Settings.Voice.overlayColorRoseQuartz
        case .lemonCream: return L10n.Settings.Voice.overlayColorLemonCream
        case .aquaGlass: return L10n.Settings.Voice.overlayColorAquaGlass
        case .warmSand: return L10n.Settings.Voice.overlayColorWarmSand
        case .darkGrayWhite: return L10n.Settings.Voice.overlayColorDarkGrayWhite
        case .darkBlueCyan: return L10n.Settings.Voice.overlayColorDarkBlueCyan
        case .darkPurplePink: return L10n.Settings.Voice.overlayColorDarkPurplePink
        case .darkGreenLime: return L10n.Settings.Voice.overlayColorDarkGreenLime
        case .darkRedCoral: return L10n.Settings.Voice.overlayColorDarkRedCoral
        case .darkGrayBlue: return L10n.Settings.Voice.overlayColorDarkGrayBlue
        case .darkGrayGreen: return L10n.Settings.Voice.overlayColorDarkGrayGreen
        case .darkGrayOrange: return L10n.Settings.Voice.overlayColorDarkGrayOrange
        case .darkGrayPink: return L10n.Settings.Voice.overlayColorDarkGrayPink
        case .darkGrayPurple: return L10n.Settings.Voice.overlayColorDarkGrayPurple
        case .darkGrayRed: return L10n.Settings.Voice.overlayColorDarkGrayRed
        case .darkGrayYellow: return L10n.Settings.Voice.overlayColorDarkGrayYellow
        case .darkGrayCyan: return L10n.Settings.Voice.overlayColorDarkGrayCyan
        case .quantumCyan: return L10n.Settings.Voice.overlayColorQuantumCyan
        case .neonTokyo: return L10n.Settings.Voice.overlayColorNeonTokyo
        case .auroraMint: return L10n.Settings.Voice.overlayColorAuroraMint
        case .ionStorm: return L10n.Settings.Voice.overlayColorIonStorm
        case .plasmaCore: return L10n.Settings.Voice.overlayColorPlasmaCore
        case .solarFlare: return L10n.Settings.Voice.overlayColorSolarFlare
        case .hologram: return L10n.Settings.Voice.overlayColorHologram
        case .laserGrid: return L10n.Settings.Voice.overlayColorLaserGrid
        case .deepSpace: return L10n.Settings.Voice.overlayColorDeepSpace
        case .cyberSunset: return L10n.Settings.Voice.overlayColorCyberSunset
        case .lunarSignal: return L10n.Settings.Voice.overlayColorLunarSignal
        case .cosmicGrape: return L10n.Settings.Voice.overlayColorCosmicGrape
        }
    }

    func colorConfig(for colorScheme: ColorScheme) -> WaveformOverlayColorConfig {
        switch self {
        case .blue:
            let color = Color(red: 0.0, green: 0.48, blue: 1.0)
            return WaveformOverlayColorConfig(
                backgroundColor: color,
                barColor: color,
                backgroundOpacity: colorScheme == .dark ? 0.3 : 0.2
            )
        case .purple:
            let color = Color(red: 0.69, green: 0.32, blue: 0.87)
            return WaveformOverlayColorConfig(
                backgroundColor: color,
                barColor: color,
                backgroundOpacity: colorScheme == .dark ? 0.3 : 0.2
            )
        case .pink:
            let color = Color(red: 1.0, green: 0.22, blue: 0.37)
            return WaveformOverlayColorConfig(
                backgroundColor: color,
                barColor: color,
                backgroundOpacity: colorScheme == .dark ? 0.3 : 0.2
            )
        case .green:
            let color = Color(red: 0.20, green: 0.78, blue: 0.35)
            return WaveformOverlayColorConfig(
                backgroundColor: color,
                barColor: color,
                backgroundOpacity: colorScheme == .dark ? 0.3 : 0.2
            )
        case .orange:
            let color = Color(red: 1.0, green: 0.58, blue: 0.0)
            return WaveformOverlayColorConfig(
                backgroundColor: color,
                barColor: color,
                backgroundOpacity: colorScheme == .dark ? 0.3 : 0.2
            )
        case .red:
            let color = Color(red: 1.0, green: 0.27, blue: 0.23)
            return WaveformOverlayColorConfig(
                backgroundColor: color,
                barColor: color,
                backgroundOpacity: colorScheme == .dark ? 0.3 : 0.2
            )
        case .blackWhite:
            return WaveformOverlayColorConfig(
                backgroundColor: .black,
                barColor: .white,
                backgroundOpacity: 0.85,
                useMaterial: false
            )
        case .whiteBlack:
            return WaveformOverlayColorConfig(
                backgroundColor: .white,
                barColor: .black,
                backgroundOpacity: 0.9,
                useMaterial: false
            )
        case .skyGlass:
            return lightConfig(background: Color(red: 0.78, green: 0.90, blue: 1.0), primary: Color(red: 0.04, green: 0.34, blue: 0.72), accent: Color(red: 0.0, green: 0.62, blue: 0.92))
        case .mintCream:
            return lightConfig(background: Color(red: 0.80, green: 0.97, blue: 0.89), primary: Color(red: 0.02, green: 0.43, blue: 0.32), accent: Color(red: 0.0, green: 0.67, blue: 0.48))
        case .lavenderMist:
            return lightConfig(background: Color(red: 0.90, green: 0.85, blue: 1.0), primary: Color(red: 0.34, green: 0.18, blue: 0.68), accent: Color(red: 0.65, green: 0.30, blue: 0.82))
        case .peachSorbet:
            return lightConfig(background: Color(red: 1.0, green: 0.86, blue: 0.76), primary: Color(red: 0.68, green: 0.20, blue: 0.10), accent: Color(red: 0.94, green: 0.42, blue: 0.20))
        case .roseQuartz:
            return lightConfig(background: Color(red: 1.0, green: 0.84, blue: 0.90), primary: Color(red: 0.64, green: 0.12, blue: 0.34), accent: Color(red: 0.90, green: 0.30, blue: 0.52))
        case .lemonCream:
            return lightConfig(background: Color(red: 1.0, green: 0.96, blue: 0.72), primary: Color(red: 0.46, green: 0.35, blue: 0.02), accent: Color(red: 0.78, green: 0.58, blue: 0.0))
        case .aquaGlass:
            return lightConfig(background: Color(red: 0.75, green: 0.96, blue: 0.98), primary: Color(red: 0.0, green: 0.35, blue: 0.43), accent: Color(red: 0.0, green: 0.68, blue: 0.72))
        case .warmSand:
            return lightConfig(background: Color(red: 0.96, green: 0.89, blue: 0.75), primary: Color(red: 0.40, green: 0.25, blue: 0.08), accent: Color(red: 0.70, green: 0.43, blue: 0.12))
        case .darkGrayWhite:
            return WaveformOverlayColorConfig(
                backgroundColor: Color(red: 0.15, green: 0.15, blue: 0.15),
                barColor: .white,
                backgroundOpacity: 0.85,
                useMaterial: false
            )
        case .darkBlueCyan:
            return WaveformOverlayColorConfig(
                backgroundColor: Color(red: 0.1, green: 0.2, blue: 0.35),
                barColor: Color(red: 0.0, green: 0.9, blue: 1.0),
                backgroundOpacity: 0.85,
                useMaterial: false
            )
        case .darkPurplePink:
            return WaveformOverlayColorConfig(
                backgroundColor: Color(red: 0.25, green: 0.1, blue: 0.35),
                barColor: Color(red: 1.0, green: 0.4, blue: 0.7),
                backgroundOpacity: 0.85,
                useMaterial: false
            )
        case .darkGreenLime:
            return WaveformOverlayColorConfig(
                backgroundColor: Color(red: 0.1, green: 0.3, blue: 0.15),
                barColor: Color(red: 0.5, green: 1.0, blue: 0.3),
                backgroundOpacity: 0.85,
                useMaterial: false
            )
        case .darkRedCoral:
            return WaveformOverlayColorConfig(
                backgroundColor: Color(red: 0.35, green: 0.1, blue: 0.1),
                barColor: Color(red: 1.0, green: 0.5, blue: 0.4),
                backgroundOpacity: 0.85,
                useMaterial: false
            )
        case .darkGrayBlue:
            return WaveformOverlayColorConfig(
                backgroundColor: Color(red: 0.2, green: 0.2, blue: 0.2),
                barColor: Color(red: 0.0, green: 0.6, blue: 1.0),
                backgroundOpacity: 0.85,
                useMaterial: false
            )
        case .darkGrayGreen:
            return WaveformOverlayColorConfig(
                backgroundColor: Color(red: 0.2, green: 0.2, blue: 0.2),
                barColor: Color(red: 0.2, green: 0.8, blue: 0.4),
                backgroundOpacity: 0.85,
                useMaterial: false
            )
        case .darkGrayOrange:
            return WaveformOverlayColorConfig(
                backgroundColor: Color(red: 0.2, green: 0.2, blue: 0.2),
                barColor: Color(red: 1.0, green: 0.6, blue: 0.0),
                backgroundOpacity: 0.85,
                useMaterial: false
            )
        case .darkGrayPink:
            return WaveformOverlayColorConfig(
                backgroundColor: Color(red: 0.2, green: 0.2, blue: 0.2),
                barColor: Color(red: 1.0, green: 0.3, blue: 0.5),
                backgroundOpacity: 0.85,
                useMaterial: false
            )
        case .darkGrayPurple:
            return WaveformOverlayColorConfig(
                backgroundColor: Color(red: 0.2, green: 0.2, blue: 0.2),
                barColor: Color(red: 0.7, green: 0.4, blue: 0.9),
                backgroundOpacity: 0.85,
                useMaterial: false
            )
        case .darkGrayRed:
            return WaveformOverlayColorConfig(
                backgroundColor: Color(red: 0.2, green: 0.2, blue: 0.2),
                barColor: Color(red: 1.0, green: 0.3, blue: 0.3),
                backgroundOpacity: 0.85,
                useMaterial: false
            )
        case .darkGrayYellow:
            return WaveformOverlayColorConfig(
                backgroundColor: Color(red: 0.2, green: 0.2, blue: 0.2),
                barColor: Color(red: 1.0, green: 0.9, blue: 0.2),
                backgroundOpacity: 0.85,
                useMaterial: false
            )
        case .darkGrayCyan:
            return WaveformOverlayColorConfig(
                backgroundColor: Color(red: 0.2, green: 0.2, blue: 0.2),
                barColor: Color(red: 0.0, green: 0.8, blue: 0.9),
                backgroundOpacity: 0.85,
                useMaterial: false
            )
        case .quantumCyan:
            return neonConfig(background: Color(red: 0.025, green: 0.08, blue: 0.15), primary: Color(red: 0.0, green: 0.95, blue: 1.0), accent: Color(red: 0.27, green: 0.4, blue: 1.0))
        case .neonTokyo:
            return neonConfig(background: Color(red: 0.09, green: 0.02, blue: 0.14), primary: Color(red: 1.0, green: 0.12, blue: 0.72), accent: Color(red: 0.0, green: 0.88, blue: 1.0))
        case .auroraMint:
            return neonConfig(background: Color(red: 0.01, green: 0.12, blue: 0.16), primary: Color(red: 0.22, green: 1.0, blue: 0.72), accent: Color(red: 0.15, green: 0.66, blue: 1.0))
        case .ionStorm:
            return neonConfig(background: Color(red: 0.06, green: 0.05, blue: 0.2), primary: Color(red: 0.38, green: 0.55, blue: 1.0), accent: Color(red: 0.72, green: 0.27, blue: 1.0))
        case .plasmaCore:
            return neonConfig(background: Color(red: 0.16, green: 0.02, blue: 0.2), primary: Color(red: 1.0, green: 0.24, blue: 0.88), accent: Color(red: 1.0, green: 0.52, blue: 0.2))
        case .solarFlare:
            return neonConfig(background: Color(red: 0.18, green: 0.035, blue: 0.01), primary: Color(red: 1.0, green: 0.2, blue: 0.04), accent: Color(red: 1.0, green: 0.78, blue: 0.04))
        case .hologram:
            return neonConfig(background: Color(red: 0.025, green: 0.11, blue: 0.18), primary: Color(red: 0.25, green: 0.95, blue: 1.0), accent: Color(red: 0.6, green: 0.42, blue: 1.0))
        case .laserGrid:
            return neonConfig(background: Color(red: 0.015, green: 0.025, blue: 0.02), primary: Color(red: 0.62, green: 1.0, blue: 0.0), accent: Color(red: 0.0, green: 1.0, blue: 0.55))
        case .deepSpace:
            return neonConfig(background: Color(red: 0.015, green: 0.025, blue: 0.09), primary: Color(red: 0.62, green: 0.75, blue: 1.0), accent: Color(red: 0.92, green: 0.95, blue: 1.0))
        case .cyberSunset:
            return neonConfig(background: Color(red: 0.12, green: 0.025, blue: 0.12), primary: Color(red: 1.0, green: 0.32, blue: 0.38), accent: Color(red: 1.0, green: 0.62, blue: 0.1))
        case .lunarSignal:
            return neonConfig(background: Color(red: 0.1, green: 0.12, blue: 0.16), primary: Color(red: 0.86, green: 0.96, blue: 1.0), accent: Color(red: 0.48, green: 0.7, blue: 1.0))
        case .cosmicGrape:
            return neonConfig(background: Color(red: 0.1, green: 0.025, blue: 0.18), primary: Color(red: 0.86, green: 0.38, blue: 1.0), accent: Color(red: 0.44, green: 0.7, blue: 1.0))
        }
    }

    private func neonConfig(background: Color, primary: Color, accent: Color) -> WaveformOverlayColorConfig {
        WaveformOverlayColorConfig(
            backgroundColor: background,
            barColor: primary,
            barAccentColor: accent,
            borderColor: primary.opacity(0.62),
            backgroundOpacity: 0.96,
            useMaterial: false
        )
    }

    private func lightConfig(background: Color, primary: Color, accent: Color) -> WaveformOverlayColorConfig {
        WaveformOverlayColorConfig(
            backgroundColor: background,
            barColor: primary,
            barAccentColor: accent,
            borderColor: primary.opacity(0.22),
            backgroundOpacity: 0.94,
            useMaterial: false
        )
    }
}
