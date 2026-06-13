//
//  MobileGatewayCoordinatorTests.swift
//  XeditTests
//

import Foundation
import Testing
@testable import WillDeep

@MainActor
struct MobileGatewayCoordinatorTests {
    @Test
    func settingsNormalizeHostPortAndDesktopName() {
        let settings = MobileGatewaySettings(
            isEnabled: true,
            host: "  ",
            port: 70_000,
            desktopName: "  ",
            executablePath: "  /tmp/willdeep-agent  ",
            allowPairing: true
        ).normalized

        #expect(settings.host == "0.0.0.0")
        #expect(settings.port == 65_535)
        #expect(!settings.desktopName.isEmpty)
        #expect(settings.executablePath == "/tmp/willdeep-agent")
    }

    @Test
    func baseURLsUseLoopbackForDesktopAndLANForPairing() {
        let settings = MobileGatewaySettings(
            isEnabled: true,
            host: "0.0.0.0",
            port: 8876,
            desktopName: "Mac",
            executablePath: "",
            allowPairing: true
        )

        #expect(MobileGatewayCoordinator.desktopBaseURL(for: settings).absoluteString == "http://127.0.0.1:8876")
        #expect(MobileGatewayCoordinator.pairingBaseURL(for: settings).scheme == "http")
        #expect(MobileGatewayCoordinator.pairingBaseURL(for: settings).port == 8876)
    }

    @Test
    func pairingPayloadQRCodeJSONUsesProtocolFields() throws {
        let expiresAt = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 6,
            day: 13,
            hour: 12,
            minute: 2
        )))
        let payload = MobileGatewayPairingPayload(
            baseURL: "http://192.168.1.20:8876",
            pairingToken: "token",
            protocolVersion: "mobile-gateway.v1",
            desktopName: "Mac",
            expiresAt: expiresAt
        )

        let data = try #require(payload.qrJSONString.data(using: .utf8))
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(raw?["base_url"] as? String == "http://192.168.1.20:8876")
        #expect(raw?["pairing_token"] as? String == "token")
        #expect(raw?["protocol_version"] as? String == "mobile-gateway.v1")
        #expect(raw?["desktop_name"] as? String == "Mac")
    }
}
