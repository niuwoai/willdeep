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
        #expect(WaveformOverlayWindowColorStyle.allCases.count == 21)

        let fastvDefault = WaveformOverlayWindowColorStyle.darkGrayBlue.colorConfig(for: .dark)
        #expect(fastvDefault.useMaterial == false)
        #expect(fastvDefault.backgroundOpacity == 0.85)

        let adaptiveBlue = WaveformOverlayWindowColorStyle.blue.colorConfig(for: .light)
        #expect(adaptiveBlue.useMaterial == true)
        #expect(adaptiveBlue.backgroundOpacity == 0.2)
    }
}
