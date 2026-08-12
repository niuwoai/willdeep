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
        #expect(MobileGatewaySettings.default.relayBaseURL == "https://j.niuwoai.com")
    }

    @Test
    func defaultTransportModeIsRelay() {
        #expect(MobileGatewaySettings.default.transportMode == .relay)
    }

    @Test
    func legacySettingsWithoutTransportModeDefaultToRelay() throws {
        let suiteName = "willdeep-mobile-gateway-mode-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: suiteName) }
        // Installs predating the transportMode field must migrate to relay.
        let legacyPayload: [String: Any] = ["host": "0.0.0.0", "port": 8877]
        let data = try JSONSerialization.data(withJSONObject: legacyPayload)
        defaults.set(data, forKey: "com.willdeep.mobileGateway.settings.v1")

        #expect(MobileGatewaySettingsStore.load(defaults: defaults).transportMode == .relay)
    }

    /// 1.195.0-rc22：手机网关固定走互联网中继。旧持久化里遗留的 `lanGateway`
    /// 值仍能被解码（枚举保留），但归一化后必须强制回到 `.relay`，保证「开机
    /// 自连中继」这条唯一线路不被历史配置污染。
    @Test
    func lanGatewayModeDecodesButNormalizesBackToRelay() throws {
        let payload: [String: Any] = ["transportMode": "lanGateway", "host": "0.0.0.0"]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(MobileGatewaySettings.self, from: data)
        // 解码保真：枚举本身没删。
        #expect(decoded.transportMode == .lanGateway)
        // 归一化强制回中继。
        #expect(decoded.normalized.transportMode == .relay)
    }

    /// 通过 store 落盘再读回也必须是中继：手动改过 JSON 或旧版本写入的
    /// `lanGateway` 不能再让运行时进入局域网模式。
    @Test
    func storedLanGatewaySettingsLoadBackAsRelay() throws {
        let suiteName = "willdeep-mobile-gateway-forcerelay-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: suiteName) }
        let payload: [String: Any] = ["transportMode": "lanGateway", "host": "0.0.0.0", "port": 8877]
        let data = try JSONSerialization.data(withJSONObject: payload)
        defaults.set(data, forKey: "com.willdeep.mobileGateway.settings.v1")

        #expect(MobileGatewaySettingsStore.load(defaults: defaults).transportMode == .relay)
    }

    @Test
    func relayPairingPayloadCarriesRelayCoordinates() {
        let settings = MobileGatewaySettings(
            transportMode: .relay,
            host: "0.0.0.0",
            port: 8877,
            desktopName: "Rocky Mac",
            executablePath: "",
            allowPairing: true,
            relayBaseURL: "https://j.niuwoai.com/",
            relayRoom: "willdeep-abc"
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = MobileGatewayCoordinator.relayPairingPayload(
            for: settings,
            relayToken: "relay-secret",
            now: now
        )

        // Relay coordinates the phone actually joins with.
        #expect(payload.relayBaseURL == "https://j.niuwoai.com")
        #expect(payload.relayRoom == "willdeep-abc")
        #expect(payload.relayToken == "relay-secret")
        // No LAN gateway in relay mode: these stay nil so the QR payload does
        // not carry a second copy of the relay URL and token.
        #expect(payload.baseURL == nil)
        #expect(payload.pairingToken == nil)
        #expect(payload.protocolVersion == "mobile-gateway.v1")
        #expect(payload.fallbackBaseURLs.isEmpty)
        // Long-lived: no meaningful countdown (rotate to revoke).
        #expect(payload.expiresAt > now.addingTimeInterval(60 * 60 * 24 * 365))
        // Round-trips through the QR JSON encoder without losing relay fields,
        // and without re-encoding them a second time as base_url / pairing_token.
        let json = payload.qrJSONString
        #expect(json.contains("relay_room"))
        #expect(json.contains("relay_token"))
        #expect(!json.contains("\"base_url\""))
        #expect(!json.contains("\"pairing_token\""))
    }

    @Test
    func pairingPayloadQRCodeURLUsesCompactParamsForH5AndAppScanners() throws {
        let payload = MobileGatewayPairingPayload(
            baseURL: "https://j.niuwoai.com",
            pairingToken: "relay-secret",
            protocolVersion: "mobile-gateway.v1",
            desktopName: "Rocky Mac",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            relayBaseURL: "https://j.niuwoai.com",
            relayRoom: "room-a",
            relayToken: "relay-secret"
        )
        let url = payload.qrURLString(h5BaseURL: try #require(URL(string: "https://h5.example.com/mobile")))
        let components = try #require(URLComponents(string: url))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(components.scheme == "https")
        #expect(components.host == "h5.example.com")
        #expect(items["r"] == "room-a")
        #expect(items["t"] == "relay-secret")
        #expect(items["p"] == nil)
        #expect(url.count < 70)
    }

    @Test
    func regenerateRelayRoomProducesFreshRoom() throws {
        let suiteName = "willdeep-mobile-gateway-room-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: suiteName) }
        let first = MobileGatewaySettingsStore.regenerateRelayRoom(defaults: defaults)
        let second = MobileGatewaySettingsStore.regenerateRelayRoom(defaults: defaults)
        #expect(first.starts(with: "willdeep-"))
        #expect(second.starts(with: "willdeep-"))
        #expect(first != second)
    }

    @Test
    func settingsNormalizeHostPortAndDesktopName() {
        let settings = MobileGatewaySettings(
            host: "  ",
            port: 70_000,
            desktopName: "  ",
            executablePath: "  /tmp/willdeep-agent  ",
            allowPairing: true,
            relayBaseURL: "  https://relay.example.com  ",
            relayRoom: "  room-a  "
        ).normalized

        #expect(settings.host == "0.0.0.0")
        #expect(settings.port == 65_535)
        #expect(!settings.desktopName.isEmpty)
        #expect(settings.executablePath == "/tmp/willdeep-agent")
        #expect(settings.relayBaseURL == "https://relay.example.com")
        #expect(settings.relayRoom == "room-a")
    }

    @Test
    func settingsLoadToleratesLegacyMissingFields() throws {
        let suiteName = "willdeep-mobile-gateway-legacy-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: suiteName) }
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
        #expect(settings.relayBaseURL == "https://j.niuwoai.com")
        #expect(settings.relayRoom.starts(with: "willdeep-"))
        #expect(MobileGatewaySettingsStore.load(defaults: defaults).relayRoom == settings.relayRoom)
    }

    @Test
    func settingsLoadFallsBackWhenStoredDataIsNotJSONSettings() throws {
        let suiteName = "willdeep-mobile-gateway-corrupt-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: suiteName) }
        defaults.set(Data([0x62, 0x70, 0x6c, 0x69, 0x73, 0x74]), forKey: "com.willdeep.mobileGateway.settings.v1")

        let settings = MobileGatewaySettingsStore.load(defaults: defaults)

        #expect(settings.host == "0.0.0.0")
        #expect(settings.port == 8877)
        #expect(settings.relayBaseURL == "https://j.niuwoai.com")
        #expect(settings.relayRoom.starts(with: "willdeep-"))
    }

    @Test
    func settingsLoadReplacesLegacyDefaultRelayRoomWithInstallRoom() throws {
        let suiteName = "willdeep-mobile-gateway-relay-room-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsHygiene.cleanup(suite: defaults, named: suiteName) }
        var settings = MobileGatewaySettings.default
        settings.relayRoom = MobileGatewaySettings.legacyDefaultRelayRoom
        MobileGatewaySettingsStore.save(settings, defaults: defaults)

        let loaded = MobileGatewaySettingsStore.load(defaults: defaults)

        #expect(loaded.relayBaseURL == "https://j.niuwoai.com")
        #expect(loaded.relayRoom.starts(with: "willdeep-"))
        #expect(loaded.relayRoom != MobileGatewaySettings.legacyDefaultRelayRoom)
        #expect(MobileGatewaySettingsStore.load(defaults: defaults).relayRoom == loaded.relayRoom)
    }

    @Test
    func baseURLsUseLoopbackForDesktopAndLANForPairing() {
        let settings = MobileGatewaySettings(
            host: "0.0.0.0",
            port: 8877,
            desktopName: "Mac",
            executablePath: "",
            allowPairing: true,
            relayBaseURL: "",
            relayRoom: "room-a"
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
            expiresAt: expiresAt,
            relayBaseURL: "https://j.niuwoai.com",
            relayRoom: "room-a",
            relayToken: "relay-secret"
        )

        let data = try #require(payload.qrJSONString.data(using: .utf8))
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(raw?["base_url"] as? String == "http://192.168.1.20:8877")
        #expect(raw?["fallback_base_urls"] as? [String] == ["http://100.90.80.70:8877"])
        #expect(raw?["pairing_token"] as? String == "token")
        #expect(raw?["protocol_version"] as? String == "mobile-gateway.v1")
        #expect(raw?["desktop_name"] as? String == "Mac")
        #expect(raw?["relay_base_url"] as? String == "https://j.niuwoai.com")
        #expect(raw?["relay_room"] as? String == "room-a")
        #expect(raw?["relay_token"] as? String == "relay-secret")
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
        #expect(payload.relayBaseURL == nil)
    }

    @Test
    func pairingFallbackBaseURLsUseTailscaleRangeOnlyWhenListeningOnWildcard() {
        let settings = MobileGatewaySettings(
            host: "0.0.0.0",
            port: 8877,
            desktopName: "Mac",
            executablePath: "",
            allowPairing: true,
            relayBaseURL: "",
            relayRoom: "room-a"
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
            allowPairing: true,
            relayBaseURL: "",
            relayRoom: "room-a"
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
