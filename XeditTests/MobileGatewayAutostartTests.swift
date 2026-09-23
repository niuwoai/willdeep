//
//  MobileGatewayAutostartTests.swift
//  XeditTests
//
//  The relay connection must have exactly one owner per process. Settings
//  used to drive whichever window's coordinator it was injected with, so
//  "regenerate QR" moved only that window's peer to the new room while the
//  resident connection stayed on the old one.
//

import Testing
@testable import WillDeep

@Suite
struct MobileGatewayAutostartTests {
    @Test @MainActor
    func firstAdoptedAppStateStaysTheRelayOwner() {
        let autostart = MobileGatewayAutostart(registry: EditorAppStateRegistry())
        let first = AppState()
        let second = AppState()

        let owner = autostart.relayOwner(adopting: first)
        let later = autostart.relayOwner(adopting: second)

        #expect(owner === first)
        #expect(later === first)
        #expect(later.mobileGatewayCoordinator === first.mobileGatewayCoordinator)
    }
}
