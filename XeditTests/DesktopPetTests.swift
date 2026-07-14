import Testing
@testable import WillDeep

struct DesktopPetTests {
    @Test
    func messagePreviewCollapsesWhitespace() {
        let preview = DesktopPetMessageFormatter.makePreview("  First line\n\nsecond\tline  ")

        #expect(preview == "First line second line")
    }

    @Test
    func messagePreviewTruncatesLongMessages() {
        let source = String(repeating: "a", count: DesktopPetMessageFormatter.maximumCharacters + 1)
        let preview = DesktopPetMessageFormatter.makePreview(source)

        #expect(preview.count == DesktopPetMessageFormatter.maximumCharacters + 1)
        #expect(preview.hasSuffix("…"))
    }

    @Test
    func petAppearancesHaveStableAssetNames() {
        #expect(DesktopPetAppearance.robotFox.assetName == "DesktopPet")
        #expect(DesktopPetAppearance.penguin.assetName == "DesktopPetPenguin")
        #expect(DesktopPetAppearance.bearGirl.assetName == "DesktopPetBearGirl")
        #expect(DesktopPetAppearance.starRaccoon.assetName == "DesktopPetStarRaccoon")
        #expect(DesktopPetAppearance.paranormalTech.assetName == "DesktopPetParanormalTech")
        #expect(DesktopPetAppearance.cyberDrifter.assetName == "DesktopPetCyberDrifter")
        #expect(DesktopPetAppearance.whistleCaptain.assetName == "DesktopPetWhistleCaptain")
        #expect(DesktopPetAppearance.cloudForge.assetName == "DesktopPetCloudForge")
        #expect(DesktopPetAppearance.allCases.count == 22)
    }

    @Test
    func typingAnimationKeepsPetOnlyPose() {
        let animation = DesktopPetAnimationValues(
            mood: .typing,
            date: Date(timeIntervalSinceReferenceDate: 123)
        )

        #expect(animation.scale == 1)
        #expect(animation.facesRight)
        #expect(animation.yawRotation == 0)
    }

    @Test
    func walkingAnimationKeepsPetOnlyPose() {
        let animation = DesktopPetAnimationValues(
            mood: .walking,
            date: Date(timeIntervalSinceReferenceDate: 123)
        )

        #expect(animation.scale == 1)
        #expect(animation.yawRotation == 0)
    }

    @Test
    func spinningAnimationTurnsAroundVerticalAxis() {
        let animation = DesktopPetAnimationValues(
            mood: .spinning,
            date: Date(timeIntervalSinceReferenceDate: 123)
        )

        #expect(animation.rotation == 0)
        #expect(animation.yawRotation != 0)
    }

    @Test
    func outputFreshnessKeepsOnlyRecentAssistantOutput() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(DesktopPetOutputFreshness.isFresh(updatedAt: now.addingTimeInterval(-59), now: now))
        #expect(DesktopPetOutputFreshness.isFresh(updatedAt: now.addingTimeInterval(-60), now: now))
        #expect(!DesktopPetOutputFreshness.isFresh(updatedAt: now.addingTimeInterval(-61), now: now))
    }
}
