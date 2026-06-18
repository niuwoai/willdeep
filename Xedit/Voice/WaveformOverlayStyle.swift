//
//  WaveformOverlayStyle.swift
//  WillDeep
//
//  fastv-derived style presets for the push-to-talk floating transcription bar.
//

import SwiftUI

struct WaveformOverlayColorConfig {
    let backgroundColor: Color
    let barColor: Color
    let backgroundOpacity: Double
    let useMaterial: Bool

    init(
        backgroundColor: Color,
        barColor: Color,
        backgroundOpacity: Double = 0.25,
        useMaterial: Bool = true
    ) {
        self.backgroundColor = backgroundColor
        self.barColor = barColor
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

    var cornerRadius: CGFloat {
        switch self {
        case .minimal: return 12
        case .compact: return 12
        case .normal: return 14
        case .large: return 16
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

enum WaveformOverlayWindowColorStyle: String, CaseIterable, Identifiable {
    case blue
    case purple
    case pink
    case green
    case orange
    case red
    case blackWhite
    case whiteBlack
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
        }
    }
}
