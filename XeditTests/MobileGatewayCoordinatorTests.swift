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
        // rc10 起结构里已经没有 `isEnabled` 字段,但旧持久化 JSON 里残留
        // 该 key 时必须被 Codable 安全忽略,不能抛错。
        let legacyPayload: [String: Any] = [
            "isEnabled": false,
            "host": "0.0.0.0",
            "desktopName": "Legacy Mac"
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyPayload)
        defaults.set(data, forKey: "com.willdeep.mobileGateway.settings.v1")

        let settings = MobileGatewaySettingsStore.load(defaults: defaults)

        #expect(settings.host == "0.0.0.0")
        #expect(settings.port == 8877)
        #expect(settings.desktopName == "Legacy Mac")
        #expect(settings.executablePath == "")
        #expect(settings.allowPairing)
    }

    @Test
    func settingsLoadFallsBackWhenStoredDataIsNotJSONSettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "willdeep-mobile-gateway-corrupt-\(UUID().uuidString)"))
        defaults.set(Data([0x62, 0x70, 0x6c, 0x69, 0x73, 0x74]), forKey: "com.willdeep.mobileGateway.settings.v1")

        let settings = MobileGatewaySettingsStore.load(defaults: defaults)

        #expect(settings == MobileGatewaySettings.default.normalized)
    }

    @Test
    func baseURLsUseLoopbackForDesktopAndLANForPairing() {
        let settings = MobileGatewaySettings(
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
            fallbackBaseURLs: ["http://100.90.80.70:8877"],
            pairingToken: "token",
            protocolVersion: "mobile-gateway.v1",
            desktopName: "Mac",
            expiresAt: expiresAt
        )

        let data = try #require(payload.qrJSONString.data(using: .utf8))
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(raw?["base_url"] as? String == "http://192.168.1.20:8877")
        #expect(raw?["fallback_base_urls"] as? [String] == ["http://100.90.80.70:8877"])
        #expect(raw?["pairing_token"] as? String == "token")
        #expect(raw?["protocol_version"] as? String == "mobile-gateway.v1")
        #expect(raw?["desktop_name"] as? String == "Mac")
    }

    @Test
    func pairingPayloadDecodesLegacyJSONWithoutFallbackBaseURLs() throws {
        let json = """
        {
          "base_url": "http://192.168.1.20:8877",
          "pairing_token": "token",
          "protocol_version": "mobile-gateway.v1",
          "desktop_name": "Mac",
          "expires_at": "2026-06-13T12:02:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(
            MobileGatewayPairingPayload.self,
            from: try #require(json.data(using: .utf8))
        )

        #expect(payload.baseURL == "http://192.168.1.20:8877")
        #expect(payload.fallbackBaseURLs.isEmpty)
    }

    @Test
    func pairingFallbackBaseURLsUseTailscaleRangeOnlyWhenListeningOnWildcard() {
        let settings = MobileGatewaySettings(
            host: "0.0.0.0",
            port: 8877,
            desktopName: "Mac",
            executablePath: "",
            allowPairing: true
        )

        let fallbacks = MobileGatewayCoordinator.pairingFallbackBaseURLs(
            for: settings,
            candidateIPv4Addresses: [
                "192.168.1.20",
                "100.63.255.255",
                "100.64.0.1",
                "100.127.255.254",
                "100.128.0.1",
            ]
        )

        #expect(fallbacks.map(\.absoluteString) == [
            "http://100.64.0.1:8877",
            "http://100.127.255.254:8877",
        ])
    }

    @Test
    func pairingFallbackBaseURLsAreEmptyForExplicitHostBinding() {
        let settings = MobileGatewaySettings(
            host: "192.168.1.20",
            port: 8877,
            desktopName: "Mac",
            executablePath: "",
            allowPairing: true
        )

        let fallbacks = MobileGatewayCoordinator.pairingFallbackBaseURLs(
            for: settings,
            candidateIPv4Addresses: ["100.64.0.1"]
        )

        #expect(fallbacks.isEmpty)
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

    @Test
    func pairingResponseDecodeToleratesNullPayload() throws {
        let json = """
        {
          "ok": true,
          "data": {
            "pairing_payload": null
          }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let envelope = try JSONDecoder().decode(APIEnvelope<MobileGatewayPairingResponse>.self, from: data)

        #expect(envelope.ok)
        #expect(envelope.data?.pairingPayload == nil)
    }

    // MARK: - Reliability helpers (rc112)

    /// With no captured output we keep the original bare status line.
    @Test
    func terminationMessageWithoutOutputIsBare() {
        let message = MobileGatewayCoordinator.terminationMessage(status: 1, output: "")
        #expect(message == "Mobile Gateway exited with status 1.")
    }

    /// Whitespace-only output is treated as empty — no dangling tail.
    @Test
    func terminationMessageIgnoresWhitespaceOnlyOutput() {
        let message = MobileGatewayCoordinator.terminationMessage(status: 1, output: "\n  \n")
        #expect(message == "Mobile Gateway exited with status 1.")
    }

    /// The real reason (e.g. "address already in use") is appended so the
    /// UI shows something actionable instead of just "status 1".
    @Test
    func terminationMessageAppendsOutputTail() {
        let output = "starting gateway\nbind: address already in use\n"
        let message = MobileGatewayCoordinator.terminationMessage(status: 1, output: output)
        #expect(message.hasPrefix("Mobile Gateway exited with status 1."))
        #expect(message.contains("address already in use"))
    }

    /// Only the last few lines are kept so a noisy log doesn't flood the
    /// status field.
    @Test
    func terminationMessageKeepsOnlyLastLines() {
        let output = (1...10).map { "line\($0)" }.joined(separator: "\n")
        let message = MobileGatewayCoordinator.terminationMessage(status: 2, output: output)
        #expect(message.contains("line10"))
        #expect(message.contains("line7"))
        #expect(!message.contains("line6"))
    }

    /// Probing returns a bindable port at or above the preferred one, so a
    /// busy 8877 no longer forces a status-1 launch failure.
    @Test
    func findAvailablePortReturnsBindablePortAtOrAbovePreferred() {
        let preferred = 8877
        let port = MobileGatewayCoordinator.findAvailablePort(preferred: preferred)
        #expect(port != nil)
        if let port {
            #expect(port >= preferred)
            #expect(port <= mobileGatewayPortRange.upperBound)
        }
    }

    /// The loopback session used for gateway probes must disable proxies —
    /// a system HTTP/SOCKS proxy intercepting 127.0.0.1 was exactly what
    /// stranded the gateway on "Starting…".
    @Test
    func loopbackSessionDisablesProxies() {
        let proxies = AgentNetworkSupport.loopbackSession().configuration.connectionProxyDictionary
        #expect(proxies?["HTTPEnable"] as? Int == 0)
        #expect(proxies?["HTTPSEnable"] as? Int == 0)
        #expect(proxies?["SOCKSEnable"] as? Int == 0)
    }

    @Test
    func staleGatewayParserOnlySelectsOrphanedMobileGatewayForSameToken() {
        let tokenPath = "/Users/me/Library/Application Support/com.willdeep.app/MobileGateway/desktop-token"
        let processList = """
          101     1 /Applications/WillDeep.app/Contents/Resources/willdeep-agent serve-mobile --desktop-token-file \(tokenPath) --port 8877
          102  9000 /Applications/WillDeep.app/Contents/Resources/willdeep-agent serve-mobile --desktop-token-file \(tokenPath) --port 8878
          103     1 /Applications/WillDeep.app/Contents/Resources/willdeep-agent other --desktop-token-file \(tokenPath)
          104     1 /Applications/WillDeep.app/Contents/Resources/willdeep-agent serve-mobile --desktop-token-file /tmp/other-token
          105     1 /bin/sleep 100
        """

        let pids = MobileGatewayCoordinator.staleGatewayPIDs(
            from: processList,
            desktopTokenFilePath: tokenPath,
            currentPID: 999
        )

        #expect(pids == [101])
    }
}
