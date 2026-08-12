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
        #expect(DesktopPetAppearance.allCases.first == .bearGirl)
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
        #expect(DesktopPetAppearance.cosmicDownsizer.assetName == "DesktopPetCosmicDownsizer")
        #expect(DesktopPetAppearance.allCases.count == 25)
    }

    @Test @MainActor
    func cosmicDownsizerAssetKeepsTransparentCorners() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetURL = repositoryRoot
            .appendingPathComponent("Xedit/Assets.xcassets/DesktopPetCosmicDownsizer.imageset")
            .appendingPathComponent("DesktopPetCosmicDownsizer.png")
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: assetURL)))

        #expect(bitmap.pixelsWide == 1_254)
        #expect(bitmap.pixelsHigh == 1_254)
        #expect(bitmap.hasAlpha)

        let cornerPixels = [
            (x: 0, y: 0),
            (x: bitmap.pixelsWide - 1, y: 0),
            (x: 0, y: bitmap.pixelsHigh - 1),
            (x: bitmap.pixelsWide - 1, y: bitmap.pixelsHigh - 1)
        ]
        for pixel in cornerPixels {
            let color = try #require(bitmap.colorAt(x: pixel.x, y: pixel.y))
            #expect(color.alphaComponent == 0)
        }
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
            date: Date(timeIntervalSinceReferenceDate: 5.2)
        )

        #expect(quietAnimation.ambientEffectPlan == nil)
        #expect(cuteAnimation.ambientEffectPlan != nil)
        #expect(cuteAnimation.verticalOffset < quietAnimation.verticalOffset)
    }

    @Test
    func ambientEffectsChooseExactlyOneKindPerCycle() {
        let plans = (0..<64).map {
            DesktopPetAmbientEffectPlan.make(cycleIndex: $0, progress: 0.5)
        }

        #expect(Set(plans.map(\.kind)).count == DesktopPetAmbientEffectKind.allCases.count)
        #expect(plans.allSatisfy { $0.particleCount > 0 })
    }

    @Test
    func lipEffectsVaryBetweenOneAndManyParticles() {
        let lipPlans = (0..<256)
            .map { DesktopPetAmbientEffectPlan.make(cycleIndex: $0, progress: 0.5) }
            .filter { $0.kind == .lips }

        #expect(lipPlans.contains { $0.particleCount == 1 })
        #expect(lipPlans.contains { $0.particleCount > 1 })
    }

    @Test
    func ambientParticlesGrowThenShrinkAndFade() {
        let plan = DesktopPetAmbientEffectPlan.make(cycleIndex: 3, progress: 0.5)

        #expect(plan.particleProgress(at: 0) == 0.5)
        #expect(sin(plan.particleProgress(at: 0) * .pi) > 0.99)
        #expect(sin(DesktopPetAmbientEffectPlan.make(cycleIndex: 3, progress: 1).particleProgress(at: 0) * .pi) < 0.001)
    }

    @Test
    func automaticJumpDelayStaysInsidePlayfulRange() {
        #expect(DesktopPetAutonomy.jumpDelay(unitInterval: -1) == DesktopPetAutonomy.minimumJumpDelay)
        #expect(DesktopPetAutonomy.jumpDelay(unitInterval: 1) == DesktopPetAutonomy.maximumJumpDelay)
        #expect(DesktopPetAutonomy.jumpDelay(unitInterval: 0.5) == 23)
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

    @Test
    func animationCadenceCapsForegroundAndBackgroundRedraws() {
        #expect(DesktopPetAnimationCadence.framesPerSecond(appIsActive: true) == 4)
        #expect(DesktopPetAnimationCadence.framesPerSecond(appIsActive: false) == 4)
        #expect(
            DesktopPetAnimationCadence.minimumInterval(appIsActive: true)
                >= 1.0 / 4.0
        )
        #expect(
            DesktopPetAnimationCadence.minimumInterval(appIsActive: false)
                >= 1.0 / 4.0
        )
    }

    /// The background cadence used to be *faster* than the foreground one. A CA
    /// transaction flush lays out every window with pending work, so the pet's
    /// timeline sets the display-cycle beat for the whole app — including the
    /// far larger main window. Backgrounded is precisely when that cost buys
    /// the least, so it must never outpace the foreground.
    @Test
    func backgroundCadenceNeverOutpacesForeground() {
        #expect(
            DesktopPetAnimationCadence.framesPerSecond(appIsActive: false)
                <= DesktopPetAnimationCadence.framesPerSecond(appIsActive: true)
        )
    }

    @Test
    func animationParksWhenPanelIsOffScreenOrDisabled() {
        #expect(DesktopPetAnimationGate.shouldAnimate(
            isEnabled: true,
            isWindowVisible: true,
            mood: .walking
        ))
        #expect(!DesktopPetAnimationGate.shouldAnimate(
            isEnabled: true,
            isWindowVisible: false,
            mood: .walking
        ))
        #expect(!DesktopPetAnimationGate.shouldAnimate(
            isEnabled: false,
            isWindowVisible: true,
            mood: .walking
        ))
        #expect(!DesktopPetAnimationGate.shouldAnimate(
            isEnabled: false,
            isWindowVisible: false,
            mood: .walking
        ))
    }

    /// Resting is the mood the pet holds almost all the time, and its breathing
    /// drives an app-wide CA flush per frame for motion nobody is waiting on.
    /// Everything that actually reports state must keep animating — including
    /// the automatic jump, which is what brings a parked pet back to life.
    @Test
    func idleMoodParksTheTimelineWhileSignallingMoodsKeepAnimating() {
        #expect(!DesktopPetAnimationGate.requiresTimeline(mood: .idle))
        #expect(!DesktopPetAnimationGate.shouldAnimate(
            isEnabled: true,
            isWindowVisible: true,
            mood: .idle
        ))

        for mood: DesktopPetMood in [.walking, .typing, .jumping, .ready, .attention, .celebrating] {
            #expect(DesktopPetAnimationGate.requiresTimeline(mood: mood))
            #expect(DesktopPetAnimationGate.shouldAnimate(
                isEnabled: true,
                isWindowVisible: true,
                mood: mood
            ))
        }
    }

    /// Previews walk every runtime and every stored session and split message
    /// bodies; that is the most expensive thing on the 0.4s refresh timer and
    /// the part that least needs to be immediate.
    @Test
    func outputPreviewsRecomputeOnASlowerBeatThanTheRefreshTimer() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(DesktopPetOutputPreviewCadence.shouldRecompute(lastComputedAt: nil, now: start))
        #expect(!DesktopPetOutputPreviewCadence.shouldRecompute(
            lastComputedAt: start,
            now: start.addingTimeInterval(0.4)
        ))
        #expect(!DesktopPetOutputPreviewCadence.shouldRecompute(
            lastComputedAt: start,
            now: start.addingTimeInterval(1.9)
        ))
        #expect(DesktopPetOutputPreviewCadence.shouldRecompute(
            lastComputedAt: start,
            now: start.addingTimeInterval(2)
        ))
        // A backwards clock jump must not strand the cache forever.
        #expect(DesktopPetOutputPreviewCadence.shouldRecompute(
            lastComputedAt: start,
            now: start.addingTimeInterval(-60)
        ))
        #expect(DesktopPetOutputPreviewCadence.refreshInterval > 0.4)
    }

    @Test @MainActor
    func desktopPetAcceptsTheFirstMouseEventWhileAppIsInactive() {
        #expect(DesktopPetFirstMousePolicy.accepts(nil))
    }

    @Test
    func desktopPetDragTracksGlobalMousePositionWithoutAccumulatedLag() {
        let mouseDown = CGPoint(x: 400, y: 300)
        let windowOrigin = CGPoint(x: 240, y: 120)
        let anchor = DesktopPetDragAnchor(
            mouseLocation: mouseDown,
            windowOrigin: windowOrigin
        )

        let movedOrigin = DesktopPetDragPositioning.windowOrigin(
            anchor: anchor,
            currentMouseLocation: CGPoint(x: 575, y: 390)
        )

        #expect(movedOrigin == CGPoint(x: 415, y: 210))
    }

    @Test
    func desktopPetDragConvertsInitialSwiftUITranslationToScreenCoordinates() {
        let mouseDown = DesktopPetDragPositioning.mouseDownLocation(
            currentMouseLocation: CGPoint(x: 515, y: 285),
            initialTranslation: CGSize(width: 15, height: 15)
        )

        #expect(mouseDown == CGPoint(x: 500, y: 300))
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
        let size = NSSize(width: 1_090, height: 260)
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
                time: 5.2
            )
            animationPreview(
                title: L10n.DesktopPet.appearanceCosmicDownsizer,
                appearance: .cosmicDownsizer,
                mood: .idle,
                time: 13.2
            )
            animationPreview(
                title: L10n.DesktopPet.statusIdle,
                appearance: .starRaccoon,
                mood: .idle,
                time: 29.2
            )
            animationPreview(
                title: L10n.DesktopPet.statusIdle,
                appearance: .moonRabbit,
                mood: .idle,
                time: 37.2
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
