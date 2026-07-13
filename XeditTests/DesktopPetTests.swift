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
    func typingAnimationShowsLaptopAndKeystrokes() {
        let animation = DesktopPetAnimationValues(
            mood: .typing,
            date: Date(timeIntervalSinceReferenceDate: 123)
        )

        #expect(animation.showsLaptop)
        #expect(animation.typingPetLift > 0)
        #expect(animation.typingPulse >= 0)
        #expect(animation.typingPulse <= 1)
    }

    @Test
    func walkingAnimationDoesNotShowLaptop() {
        let animation = DesktopPetAnimationValues(
            mood: .walking,
            date: Date(timeIntervalSinceReferenceDate: 123)
        )

        #expect(!animation.showsLaptop)
        #expect(animation.typingPetLift == 0)
    }
}
