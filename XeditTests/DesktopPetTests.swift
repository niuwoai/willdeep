import AppKit
import Testing
import SwiftUI
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
        #expect(DesktopPetAppearance.codeShiba.assetName == "DesktopPetCodeShiba")
        #expect(DesktopPetAppearance.moonRabbit.assetName == "DesktopPetMoonRabbit")
        #expect(DesktopPetAppearance.allCases.count == 24)
    }

    @Test
    func typingAnimationKeepsPetOnlyPose() {
        let animation = DesktopPetAnimationValues(
            mood: .typing,
            date: Date(timeIntervalSinceReferenceDate: 123)
        )

        #expect(animation.scale == 1)
        #expect(animation.facesRight)
        #expect(animation.verticalOffset < 0)
    }

    @Test
    func idleAnimationPeriodicallyPerformsCuteAction() {
        let quietAnimation = DesktopPetAnimationValues(
            mood: .idle,
            date: Date(timeIntervalSinceReferenceDate: 2)
        )
        let cuteAnimation = DesktopPetAnimationValues(
            mood: .idle,
            date: Date(timeIntervalSinceReferenceDate: 7.5)
        )

        #expect(quietAnimation.cuteEffectOpacity == 0)
        #expect(cuteAnimation.cuteEffectOpacity > 0.99)
        #expect(cuteAnimation.verticalOffset < quietAnimation.verticalOffset)
    }

    @Test
    func walkingAnimationKeepsPetOnlyPose() {
        let animation = DesktopPetAnimationValues(
            mood: .walking,
            date: Date(timeIntervalSinceReferenceDate: 123)
        )

        #expect(animation.scale == 1)
    }

    @Test
    func readyAnimationUsesGentleIdleMotion() {
        let animation = DesktopPetAnimationValues(
            mood: .ready,
            date: Date(timeIntervalSinceReferenceDate: 123)
        )

        #expect(animation.scale == 1)
        #expect(abs(animation.rotation) < 12)
    }

    @Test
    func outputFreshnessKeepsOnlyRecentAssistantOutput() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(DesktopPetOutputFreshness.isFresh(updatedAt: now.addingTimeInterval(-59), now: now))
        #expect(DesktopPetOutputFreshness.isFresh(updatedAt: now.addingTimeInterval(-60), now: now))
        #expect(!DesktopPetOutputFreshness.isFresh(updatedAt: now.addingTimeInterval(-61), now: now))
    }

    @Test
    func hibernationEndsExactlyAtDeadline() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(DesktopPetHibernation.duration == 5 * 60)
        #expect(!DesktopPetHibernation.isActive(endsAt: nil, now: now))
        #expect(DesktopPetHibernation.isActive(endsAt: now.addingTimeInterval(1), now: now))
        #expect(!DesktopPetHibernation.isActive(endsAt: now, now: now))
        #expect(!DesktopPetHibernation.isActive(endsAt: now.addingTimeInterval(-1), now: now))
    }

    @Test
    func nextMorningWakesUpAtNineTomorrow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 22, minute: 30))!

        let wakeUp = DesktopPetHibernation.nextMorning(after: now, calendar: calendar)

        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wakeUp)
        #expect(components.year == 2026)
        #expect(components.month == 7)
        #expect(components.day == 16)
        #expect(components.hour == DesktopPetHibernation.wakeUpHour)
        #expect(components.minute == 0)
        #expect(components.second == 0)
        #expect(wakeUp > now)
    }

    @Test
    func messageCardsRequireBackgroundOutputSessions() {
        #expect(!DesktopPetMessageCardVisibility.shouldShowMessageCards(
            appIsActive: true,
            outputSessionCount: 1
        ))
        #expect(!DesktopPetMessageCardVisibility.shouldShowMessageCards(
            appIsActive: false,
            outputSessionCount: 0
        ))
        #expect(DesktopPetMessageCardVisibility.shouldShowMessageCards(
            appIsActive: false,
            outputSessionCount: 1
        ))
    }

    @Test @MainActor
    func desktopPetAcceptsTheFirstMouseEventWhileAppIsInactive() {
        #expect(DesktopPetFirstMousePolicy.accepts(nil))
    }

    @Test
    func desktopPetSettingsUseReadableBodyTypography() {
        #expect(DesktopPetSettingsDesign.bodyFontSize == 14)
        #expect(DesktopPetSettingsDesign.appearanceNameMinimumHeight >= 36)
    }

    @Test @MainActor
    func renderDesktopPetSettingsForDesignQA() throws {
        let outputPath = ProcessInfo.processInfo.environment["WILLDEEP_DESKTOP_PET_QA_OUTPUT"]
            ?? "/tmp/Xedit-desktop-pet-settings-design-qa.png"
        let manager = DesktopPetWindowManager.shared
        let originalEnabled = manager.isEnabled
        let originalAppearance = manager.appearance
        defer {
            manager.selectAppearance(originalAppearance)
            manager.setEnabled(originalEnabled)
        }
        manager.setEnabled(false)
        manager.selectAppearance(.robotFox)

        let size = NSSize(width: 806, height: 848)
        let root = ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)

            VStack(alignment: .leading, spacing: 14) {
                Text(SettingsGroup.pet.title)
                    .font(.title3.weight(.semibold))

                DesktopPetSettingsPage()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(20)
        }
            .frame(width: size.width, height: size.height)
            .preferredColorScheme(.light)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    @Test @MainActor
    func renderDesktopPetAnimationShowcaseForDesignQA() throws {
        let outputPath = ProcessInfo.processInfo.environment["WILLDEEP_DESKTOP_PET_ANIMATION_QA_OUTPUT"]
            ?? "/tmp/Xedit-desktop-pet-animation-design-qa.png"
        let size = NSSize(width: 580, height: 260)
        let root = HStack(alignment: .top, spacing: 26) {
            animationPreview(
                title: L10n.DesktopPet.statusTyping,
                appearance: .codeShiba,
                mood: .typing,
                time: 123
            )
            animationPreview(
                title: L10n.DesktopPet.statusTyping,
                appearance: .moonRabbit,
                mood: .typing,
                time: 123.08
            )
            animationPreview(
                title: L10n.DesktopPet.statusIdle,
                appearance: .robotFox,
                mood: .idle,
                time: 7.5
            )
        }
        .padding(24)
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.light)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    @MainActor
    private func animationPreview(
        title: String,
        appearance: DesktopPetAppearance,
        mood: DesktopPetMood,
        time: TimeInterval
    ) -> some View {
        VStack(spacing: 8) {
            DesktopPetSceneView(
                appearance: appearance,
                animation: DesktopPetAnimationValues(
                    mood: mood,
                    date: Date(timeIntervalSinceReferenceDate: time)
                )
            )

            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
