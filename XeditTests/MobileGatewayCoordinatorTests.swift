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
    func defaultSettingsUseLANMobileGatewayPort8877() {
        #expect(MobileGatewaySettings.default.port == 8877)
    }

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
    func settingsLoadToleratesLegacyMissingFields() throws {
        let defaults = try #require(UserDefaults(suiteName: "willdeep-mobile-gateway-legacy-\(UUID().uuidString)"))
        let legacyPayload: [String: Any] = [
            "isEnabled": true,
            "host": "0.0.0.0",
            "desktopName": "Legacy Mac"
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyPayload)
        defaults.set(data, forKey: "com.willdeep.mobileGateway.settings.v1")

        let settings = MobileGatewaySettingsStore.load(defaults: defaults)

        #expect(settings.isEnabled)
        #expect(settings.host == "0.0.0.0")
        #expect(settings.port == 8877)
        #expect(settings.desktopName == "Legacy Mac")
        #expect(settings.executablePath == "")
        #expect(settings.allowPairing)
    }

    @Test
    func baseURLsUseLoopbackForDesktopAndLANForPairing() {
        let settings = MobileGatewaySettings(
            isEnabled: true,
            host: "0.0.0.0",
            port: 8877,
            desktopName: "Mac",
            executablePath: "",
            allowPairing: true
        )

        #expect(MobileGatewayCoordinator.desktopBaseURL(for: settings).absoluteString == "http://127.0.0.1:8877")
        #expect(MobileGatewayCoordinator.pairingBaseURL(for: settings).scheme == "http")
        #expect(MobileGatewayCoordinator.pairingBaseURL(for: settings).port == 8877)
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
            baseURL: "http://192.168.1.20:8877",
            pairingToken: "token",
            protocolVersion: "mobile-gateway.v1",
            desktopName: "Mac",
            expiresAt: expiresAt
        )

        let data = try #require(payload.qrJSONString.data(using: .utf8))
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(raw?["base_url"] as? String == "http://192.168.1.20:8877")
        #expect(raw?["pairing_token"] as? String == "token")
        #expect(raw?["protocol_version"] as? String == "mobile-gateway.v1")
        #expect(raw?["desktop_name"] as? String == "Mac")
    }

    @Test
    func apiEnvelopeDecodesSuccessfulResponseWithoutErrorField() throws {
        let json = """
        {
          "ok": true,
          "data": {
            "version": {
              "name": "willdeep-agent",
              "version": "1.78.0-rc20",
              "protocol_version": "mobile-gateway.v1"
            },
            "protocol_version": "mobile-gateway.v1",
            "desktop_name": "Mac",
            "pairing_allowed": true,
            "desktop_peer_connected": true
          }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let envelope = try JSONDecoder().decode(APIEnvelope<MobileGatewayHealth>.self, from: data)

        #expect(envelope.ok)
        #expect(envelope.error == "")
        #expect(envelope.data?.desktopName == "Mac")
        #expect(envelope.data?.pairingAllowed == true)
        #expect(envelope.data?.desktopPeerConnected == true)
    }

    @Test
    func healthDecodeToleratesGoVersionInfoWithoutNestedProtocolVersion() throws {
        let json = """
        {
          "ok": true,
          "data": {
            "version": {
              "name": "willdeep-agent",
              "version": "1.78.0-rc24",
              "go_version": "go1.23.x",
              "os": "darwin",
              "arch": "arm64"
            },
            "protocol_version": "mobile-gateway.v1",
            "desktop_name": "Mac",
            "pairing_allowed": true,
            "desktop_peer_connected": false
          }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let envelope = try JSONDecoder().decode(APIEnvelope<MobileGatewayHealth>.self, from: data)

        #expect(envelope.ok)
        #expect(envelope.data?.version.version == "1.78.0-rc24")
        #expect(envelope.data?.version.protocolVersion == nil)
        #expect(envelope.data?.protocolVersion == "mobile-gateway.v1")
        #expect(envelope.data?.desktopPeerConnected == false)
    }
}
