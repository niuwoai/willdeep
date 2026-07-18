import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import WillDeep

struct WaveformOverlayStyleTests {
    @Test func stylePresetsMatchFastvSizes() {
        #expect(WaveformOverlayWindowStyle.minimal.size == CGSize(width: 24, height: 24))
        #expect(WaveformOverlayWindowStyle.compact.size == CGSize(width: 88, height: 32))
        #expect(WaveformOverlayWindowStyle.normal.size == CGSize(width: 108, height: 36))
        #expect(WaveformOverlayWindowStyle.large.size == CGSize(width: 128, height: 44))
    }

    @Test func colorPresetsKeepFastvPaletteShape() {
        let expectedColorPresetCount = 41
        #expect(WaveformOverlayWindowColorStyle.allCases.count == expectedColorPresetCount)

        let fastvDefault = WaveformOverlayWindowColorStyle.darkGrayBlue.colorConfig(for: .dark)
        #expect(fastvDefault.useMaterial == false)
        #expect(fastvDefault.backgroundOpacity == 0.85)

        let adaptiveBlue = WaveformOverlayWindowColorStyle.blue.colorConfig(for: .light)
        #expect(adaptiveBlue.useMaterial == true)
        #expect(adaptiveBlue.backgroundOpacity == 0.2)

        let lightPresets: [WaveformOverlayWindowColorStyle] = [
            .skyGlass, .mintCream, .lavenderMist, .peachSorbet,
            .roseQuartz, .lemonCream, .aquaGlass, .warmSand,
        ]
        #expect(lightPresets.allSatisfy { !$0.displayName.isEmpty })
        #expect(lightPresets.allSatisfy { !$0.colorConfig(for: .light).useMaterial })
        #expect(lightPresets.allSatisfy { $0.colorConfig(for: .light).backgroundOpacity == 0.94 })
    }

    @Test func continuousSignalPresetsExposeDistinctProfiles() {
        #expect(WaveformOverlayWaveStyle.allCases.count == 9)
        #expect(WaveformOverlayWaveStyle.sine.usesContinuousPath)
        #expect(WaveformOverlayWaveStyle.cosine.usesContinuousPath)
        #expect(WaveformOverlayWaveStyle.ecg.usesContinuousPath)
        #expect(WaveformOverlayWaveStyle.classic.usesContinuousPath == false)
        #expect(abs(WaveformOverlayWaveStyle.sine.normalizedSample(at: 0, phase: 0)) < 0.0001)
        #expect(abs(WaveformOverlayWaveStyle.cosine.normalizedSample(at: 0, phase: 0) - 1) < 0.0001)
        #expect(WaveformOverlayWaveStyle.ecg.normalizedSample(at: 0.43, phase: 0) > 0.9)
        #expect(WaveformOverlayWaveStyle.allCases.allSatisfy { !$0.displayName.isEmpty })
    }

    @Test("render continuous signals and light backgrounds for design QA")
    @MainActor
    func renderNewWaveformPresetsForDesignQA() throws {
        let waveStyles: [WaveformOverlayWaveStyle] = [.sine, .cosine, .ecg]
        let colorStyles: [WaveformOverlayWindowColorStyle] = [
            .skyGlass, .mintCream, .lavenderMist, .peachSorbet,
            .roseQuartz, .lemonCream, .aquaGlass, .warmSand,
        ]
        let size = NSSize(width: 520, height: 230)
        let root = VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(waveStyles.enumerated()), id: \.offset) { index, waveStyle in
                let config = colorStyles[index].colorConfig(for: .light)
                HStack(spacing: 12) {
                    Text(waveStyle.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 72, alignment: .trailing)
                    WaveformOverlayBars(
                        windowStyle: .large,
                        waveStyle: waveStyle,
                        primaryColor: config.barColor,
                        accentColor: config.barAccentColor,
                        audioLevel: 0.78
                    )
                    .padding(.horizontal, 12)
                    .frame(width: 360, height: 44)
                    .background(config.backgroundColor.opacity(config.backgroundOpacity))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(config.borderColor, lineWidth: 1)
                    }
                }
            }

            HStack(spacing: 8) {
                ForEach(colorStyles) { colorStyle in
                    let config = colorStyle.colorConfig(for: .light)
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(config.backgroundColor.opacity(config.backgroundOpacity))
                        .frame(width: 48, height: 28)
                        .overlay {
                            Capsule()
                                .fill(config.barColor)
                                .frame(width: 28, height: 4)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(config.borderColor, lineWidth: 1)
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(18)
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.light)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let outputPath = ProcessInfo.processInfo.environment["WILLDEEP_WAVEFORM_QA_OUTPUT"]
            ?? "/tmp/Xedit-waveform-style-qa.png"
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}
