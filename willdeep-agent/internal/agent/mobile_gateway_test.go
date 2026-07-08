package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestMobileGatewayPairingTokenLifecycle(t *testing.T) {
	cfg, err := NewMobileGatewayConfig(MobileGatewayConfigInput{
		Host:         "127.0.0.1",
		Port:         8876,
		DesktopToken: "desktop-secret",
		PairingTTL:   time.Minute,
		AllowPairing: true,
	})
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	gateway, err := NewMobileGateway(cfg)
	if err != nil {
		t.Fatalf("gateway: %v", err)
	}
	now := time.Date(2026, 6, 13, 12, 0, 0, 0, time.UTC)
	gateway.now = func() time.Time { return now }
	gateway.mu.Lock()
	if err := gateway.rotatePairingTokenLocked(now); err != nil {
		t.Fatalf("rotate pairing token: %v", err)
	}
	token := gateway.pairingToken
	gateway.mu.Unlock()

	device, deviceToken, err := gateway.claimPairingToken(token, "Pixel")
	if err != nil {
		t.Fatalf("claim pairing token: %v", err)
	}
	if device.ID == "" || deviceToken == "" {
		t.Fatalf("expected device id and token")
	}
	if _, _, err := gateway.claimPairingToken(token, "Pixel again"); err == nil {
		t.Fatalf("expected one-time pairing token to reject repeat claim")
	}

	gateway.mu.Lock()
	if err := gateway.rotatePairingTokenLocked(now); err != nil {
		t.Fatalf("rotate second pairing token: %v", err)
	}
	expired := gateway.pairingToken
	gateway.mu.Unlock()
	now = now.Add(2 * time.Minute)
	if _, _, err := gateway.claimPairingToken(expired, "Late device"); err == nil {
		t.Fatalf("expected expired pairing token to be rejected")
	}
}

func TestMobileGatewayHealthIncludesVersionHeaders(t *testing.T) {
	gateway := newTestMobileGateway(t)
	server := httptest.NewServer(gateway.routes())
	defer server.Close()

	resp, err := http.Get(server.URL + "/mobile/health")
	if err != nil {
		t.Fatalf("GET health: %v", err)
	}
	defer resp.Body.Close()
	if got := resp.Header.Get("X-App-Version"); got != Version {
		t.Fatalf("X-App-Version = %q, want %q", got, Version)
	}
	if got := resp.Header.Get("X-Server-Version"); got != Version {
		t.Fatalf("X-Server-Version = %q, want %q", got, Version)
	}
	var body APIResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode health: %v", err)
	}
	if !body.OK {
		t.Fatalf("health response not ok: %#v", body)
	}
	data, ok := body.Data.(map[string]any)
	if !ok {
		t.Fatalf("health data = %#v", body.Data)
	}
	if data["desktop_peer_connected"] != false {
		t.Fatalf("desktop_peer_connected = %#v, want false before desktop websocket connects", data["desktop_peer_connected"])
	}
}

func TestMobileGatewayHealthReportsDesktopPeerConnection(t *testing.T) {
	gateway := newTestMobileGateway(t)
	server := httptest.NewServer(gateway.routes())
	defer server.Close()

	desktopHeader := http.Header{}
	desktopHeader.Set("Authorization", "Bearer desktop-secret")
	desktopConn, _, err := websocket.DefaultDialer.Dial(mobileTestWSURL(server.URL)+"/mobile/ws", desktopHeader)
	if err != nil {
		t.Fatalf("dial desktop websocket: %v", err)
	}
	defer desktopConn.Close()

	resp, err := http.Get(server.URL + "/mobile/health")
	if err != nil {
		t.Fatalf("GET health: %v", err)
	}
	defer resp.Body.Close()
	var body APIResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode health: %v", err)
	}
	data, ok := body.Data.(map[string]any)
	if !ok {
		t.Fatalf("health data = %#v", body.Data)
	}
	if data["desktop_peer_connected"] != true {
		t.Fatalf("desktop_peer_connected = %#v, want true after desktop websocket connects", data["desktop_peer_connected"])
	}
}

func TestMobileGatewayPairingPayloadRequiresDesktopAuth(t *testing.T) {
	gateway := newTestMobileGateway(t)
	server := httptest.NewServer(gateway.routes())
	defer server.Close()

	resp, err := http.Get(server.URL + "/mobile/pairing")
	if err != nil {
		t.Fatalf("GET pairing without auth: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("pairing without auth status = %d, want 401", resp.StatusCode)
	}

	req, err := http.NewRequest(http.MethodGet, server.URL+"/mobile/pairing", nil)
	if err != nil {
		t.Fatalf("new pairing request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer desktop-secret")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET pairing with desktop auth: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("pairing with auth status = %d, want 200", resp.StatusCode)
	}
	var body APIResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode pairing response: %v", err)
	}
	data, ok := body.Data.(map[string]any)
	if !ok {
		t.Fatalf("pairing data = %#v", body.Data)
	}
	if data["pairing_payload"] == nil {
		t.Fatalf("pairing response missing pairing_payload")
	}
}

func TestMobileGatewayPairingRotateRequiresDesktopAuthAndRefreshesToken(t *testing.T) {
	gateway := newTestMobileGateway(t)
	server := httptest.NewServer(gateway.routes())
	defer server.Close()

	gateway.mu.Lock()
	oldToken := gateway.pairingToken
	gateway.mu.Unlock()

	resp, err := http.Post(server.URL+"/mobile/pairing/rotate", "application/json", nil)
	if err != nil {
		t.Fatalf("POST rotate without auth: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("rotate without auth status = %d, want 401", resp.StatusCode)
	}

	req, err := http.NewRequest(http.MethodPost, server.URL+"/mobile/pairing/rotate", nil)
	if err != nil {
		t.Fatalf("new rotate request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer desktop-secret")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST rotate with desktop auth: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("rotate with auth status = %d, want 200", resp.StatusCode)
	}
	var body APIResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode rotate response: %v", err)
	}
	data, ok := body.Data.(map[string]any)
	if !ok {
		t.Fatalf("rotate data = %#v", body.Data)
	}
	payload, ok := data["pairing_payload"].(map[string]any)
	if !ok {
		t.Fatalf("rotate pairing_payload = %#v", data["pairing_payload"])
	}
	newToken, ok := payload["pairing_token"].(string)
	if !ok || newToken == "" {
		t.Fatalf("rotated pairing token missing: %#v", payload["pairing_token"])
	}
	if newToken == oldToken {
		t.Fatalf("expected rotate to issue a new pairing token")
	}
	if _, _, err := gateway.claimPairingToken(oldToken, "Old token phone"); err == nil {
		t.Fatalf("expected old pairing token to be rejected after rotate")
	}
	if _, _, err := gateway.claimPairingToken(newToken, "New token phone"); err != nil {
		t.Fatalf("expected rotated pairing token to claim: %v", err)
	}
}

func TestMobileGatewayDevicesRequiresDesktopAuthAndRedactsTokens(t *testing.T) {
	gateway := newTestMobileGateway(t)
	claimTestDevice(t, gateway, "Pixel")
	server := httptest.NewServer(gateway.routes())
	defer server.Close()

	resp, err := http.Get(server.URL + "/mobile/devices")
	if err != nil {
		t.Fatalf("GET devices without auth: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("devices without auth status = %d, want 401", resp.StatusCode)
	}

	req, err := http.NewRequest(http.MethodGet, server.URL+"/mobile/devices", nil)
	if err != nil {
		t.Fatalf("new devices request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer desktop-secret")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET devices with desktop auth: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("devices with auth status = %d, want 200", resp.StatusCode)
	}
	var raw map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		t.Fatalf("decode devices response: %v", err)
	}
	encoded, err := json.Marshal(raw)
	if err != nil {
		t.Fatalf("marshal decoded devices response: %v", err)
	}
	text := string(encoded)
	if strings.Contains(text, "TokenHash") || strings.Contains(text, "token_hash") || strings.Contains(text, "desktop-secret") {
		t.Fatalf("devices response leaked token material: %s", text)
	}
	data, ok := raw["data"].(map[string]any)
	if !ok {
		t.Fatalf("devices data = %#v", raw["data"])
	}
	devices, ok := data["devices"].([]any)
	if !ok || len(devices) != 1 {
		t.Fatalf("devices = %#v, want one device", data["devices"])
	}
	device, ok := devices[0].(map[string]any)
	if !ok || device["name"] != "Pixel" {
		t.Fatalf("device = %#v", devices[0])
	}
}

func TestMobileGatewayWebSocketAuthAndForwarding(t *testing.T) {
	gateway := newTestMobileGateway(t)
	_, deviceToken := claimTestDevice(t, gateway, "Pixel")
	server := httptest.NewServer(gateway.routes())
	defer server.Close()
	wsURL := mobileTestWSURL(server.URL)

	if _, _, err := websocket.DefaultDialer.Dial(wsURL+"/mobile/ws", nil); err == nil {
		t.Fatalf("expected missing token websocket dial to fail")
	}

	desktopHeader := http.Header{}
	desktopHeader.Set("Authorization", "Bearer desktop-secret")
	desktopConn, _, err := websocket.DefaultDialer.Dial(wsURL+"/mobile/ws", desktopHeader)
	if err != nil {
		t.Fatalf("dial desktop websocket: %v", err)
	}
	defer desktopConn.Close()

	deviceHeader := http.Header{}
	deviceHeader.Set("Authorization", "Bearer "+deviceToken)
	deviceConn, _, err := websocket.DefaultDialer.Dial(wsURL+"/mobile/ws", deviceHeader)
	if err != nil {
		t.Fatalf("dial device websocket: %v", err)
	}
	defer deviceConn.Close()

	command := MobileEnvelope{
		ID:        "cmd-1",
		Type:      "message.send",
		SessionID: "session-1",
		Payload:   map[string]any{"text": "hello"},
	}
	if err := deviceConn.WriteJSON(command); err != nil {
		t.Fatalf("write device command: %v", err)
	}
	var forwarded MobileEnvelope
	if err := desktopConn.ReadJSON(&forwarded); err != nil {
		t.Fatalf("desktop read forwarded command: %v", err)
	}
	if forwarded.Type != command.Type || forwarded.ID != command.ID {
		t.Fatalf("forwarded command = %#v", forwarded)
	}
	if forwarded.Payload["_device_id"] == "" {
		t.Fatalf("forwarded command missing _device_id")
	}
	var ack MobileEnvelope
	if err := deviceConn.ReadJSON(&ack); err != nil {
		t.Fatalf("device read ack: %v", err)
	}
	if ack.Type != "ack" || ack.ID != command.ID {
		t.Fatalf("ack = %#v", ack)
	}

	events := []MobileEnvelope{
		{
			ID:        "evt-append",
			Type:      "message.append",
			SessionID: "session-1",
			Payload: map[string]any{
				"id":      "m1",
				"role":    "assistant",
				"content": "Editing",
			},
		},
		{
			ID:        "evt-delta",
			Type:      "message.delta",
			SessionID: "session-1",
			Payload:   map[string]any{"message_id": "m1", "delta": " files"},
		},
		{
			ID:        "evt-done",
			Type:      "message.done",
			SessionID: "session-1",
			Payload:   map[string]any{"message_id": "m1"},
		},
	}
	for _, event := range events {
		if err := desktopConn.WriteJSON(event); err != nil {
			t.Fatalf("write desktop event %s: %v", event.Type, err)
		}
		var received MobileEnvelope
		if err := deviceConn.ReadJSON(&received); err != nil {
			t.Fatalf("device read desktop event %s: %v", event.Type, err)
		}
		if received.Type != event.Type || received.ID != event.ID {
			t.Fatalf("desktop event = %#v, want %#v", received, event)
		}
	}
}

func TestMobileGatewayWorkspaceListRoundTrip(t *testing.T) {
	gateway := newTestMobileGateway(t)
	_, deviceToken := claimTestDevice(t, gateway, "Pixel")
	server := httptest.NewServer(gateway.routes())
	defer server.Close()
	wsURL := mobileTestWSURL(server.URL)

	desktopHeader := http.Header{}
	desktopHeader.Set("Authorization", "Bearer desktop-secret")
	desktopConn, _, err := websocket.DefaultDialer.Dial(wsURL+"/mobile/ws", desktopHeader)
	if err != nil {
		t.Fatalf("dial desktop websocket: %v", err)
	}
	defer desktopConn.Close()

	deviceHeader := http.Header{}
	deviceHeader.Set("Authorization", "Bearer "+deviceToken)
	deviceConn, _, err := websocket.DefaultDialer.Dial(wsURL+"/mobile/ws", deviceHeader)
	if err != nil {
		t.Fatalf("dial device websocket: %v", err)
	}
	defer deviceConn.Close()

	command := MobileEnvelope{
		ID:      "wl-1",
		Type:    "workspace.list",
		Payload: map[string]any{},
	}
	if err := deviceConn.WriteJSON(command); err != nil {
		t.Fatalf("write workspace.list command: %v", err)
	}

	var forwarded MobileEnvelope
	if err := desktopConn.ReadJSON(&forwarded); err != nil {
		t.Fatalf("desktop read forwarded workspace.list: %v", err)
	}
	if forwarded.Type != "workspace.list" || forwarded.ID != command.ID {
		t.Fatalf("forwarded workspace.list = %#v", forwarded)
	}
	if forwarded.Payload["_device_id"] == "" {
		t.Fatalf("forwarded workspace.list missing _device_id")
	}

	var ack MobileEnvelope
	if err := deviceConn.ReadJSON(&ack); err != nil {
		t.Fatalf("device read ack for workspace.list: %v", err)
	}
	if ack.Type != "ack" || ack.ID != command.ID {
		t.Fatalf("workspace.list ack = %#v", ack)
	}
	if ackType, _ := ack.Payload["type"].(string); ackType != "workspace.list" {
		t.Fatalf("workspace.list ack payload.type = %#v, want \"workspace.list\"", ack.Payload["type"])
	}

	event := MobileEnvelope{
		ID:   "wl-evt",
		Type: "workspace.list",
		Payload: map[string]any{
			"workspaces": []any{
				map[string]any{
					"path":          "/Users/rocky/Sites/Xedit",
					"name":          "Xedit",
					"last_used_at":  "2026-06-17T03:21:08Z",
					"session_count": 2,
					"is_current":    true,
					"is_git_repo":   true,
				},
			},
		},
	}
	if err := desktopConn.WriteJSON(event); err != nil {
		t.Fatalf("write desktop workspace.list event: %v", err)
	}
	var received MobileEnvelope
	if err := deviceConn.ReadJSON(&received); err != nil {
		t.Fatalf("device read workspace.list event: %v", err)
	}
	if received.Type != "workspace.list" || received.ID != event.ID {
		t.Fatalf("workspace.list event = %#v, want %#v", received, event)
	}
	workspaces, ok := received.Payload["workspaces"].([]any)
	if !ok || len(workspaces) != 1 {
		t.Fatalf("workspace.list event payload.workspaces = %#v", received.Payload["workspaces"])
	}
}

func TestMobileGatewayWorkspaceListWithoutDesktopPeerReturnsError(t *testing.T) {
	gateway := newTestMobileGateway(t)
	_, deviceToken := claimTestDevice(t, gateway, "Pixel")
	server := httptest.NewServer(gateway.routes())
	defer server.Close()

	header := http.Header{}
	header.Set("Authorization", "Bearer "+deviceToken)
	conn, _, err := websocket.DefaultDialer.Dial(mobileTestWSURL(server.URL)+"/mobile/ws", header)
	if err != nil {
		t.Fatalf("dial device websocket: %v", err)
	}
	defer conn.Close()

	if err := conn.WriteJSON(MobileEnvelope{ID: "wl-orphan", Type: "workspace.list"}); err != nil {
		t.Fatalf("write workspace.list command: %v", err)
	}
	var response MobileEnvelope
	if err := conn.ReadJSON(&response); err != nil {
		t.Fatalf("read workspace.list error response: %v", err)
	}
	if response.Type != "error" {
		t.Fatalf("workspace.list response type = %q, want error", response.Type)
	}
	if response.ID != "wl-orphan" {
		t.Fatalf("workspace.list error envelope id = %q, want wl-orphan", response.ID)
	}
}

func TestMobileGatewayPushRegisterStoresDeviceTokenWithoutDesktopPeer(t *testing.T) {
	gateway := newTestMobileGateway(t)
	device, deviceToken := claimTestDevice(t, gateway, "Pixel")
	server := httptest.NewServer(gateway.routes())
	defer server.Close()

	header := http.Header{}
	header.Set("Authorization", "Bearer "+deviceToken)
	conn, _, err := websocket.DefaultDialer.Dial(mobileTestWSURL(server.URL)+"/mobile/ws", header)
	if err != nil {
		t.Fatalf("dial device websocket: %v", err)
	}
	defer conn.Close()

	command := MobileEnvelope{
		ID:   "push-1",
		Type: "push.register",
		Payload: map[string]any{
			"provider":  "umeng",
			"client_id": "umeng-device-token",
			"app_id":    "umeng-app",
		},
	}
	if err := conn.WriteJSON(command); err != nil {
		t.Fatalf("write push.register: %v", err)
	}
	var ack MobileEnvelope
	if err := conn.ReadJSON(&ack); err != nil {
		t.Fatalf("read push.register ack: %v", err)
	}
	if ack.Type != "ack" || ack.ID != "push-1" {
		t.Fatalf("push.register ack = %#v", ack)
	}

	gateway.mu.Lock()
	stored := gateway.devices[device.ID]
	gateway.mu.Unlock()
	if stored == nil || stored.PushProvider != "umeng" || stored.PushClientID != "umeng-device-token" || stored.PushAppID != "umeng-app" {
		t.Fatalf("stored push registration = %#v", stored)
	}
}

func TestMobileGatewayRemotePushFiresOnceForAttentionEvent(t *testing.T) {
	gateway := newTestMobileGateway(t)
	sender := &fakeMobilePushSender{}
	gateway.pushSender = sender
	device, _ := claimTestDevice(t, gateway, "Pixel")
	gateway.mu.Lock()
	gateway.devices[device.ID].PushProvider = "umeng"
	gateway.devices[device.ID].PushClientID = "umeng-device-token"
	gateway.mu.Unlock()

	event := MobileEnvelope{
		Type:      "tool.pending",
		SessionID: "session-1",
		Payload: map[string]any{
			"id":                    "tool-1",
			"title":                 "Approval needed",
			"summary":               "Review the pending command.",
			"tool_name":             "terminal_send_command",
			"input_preview":         "git status",
			"requires_confirmation": true,
		},
	}
	gateway.handleDesktopEnvelope(event)
	gateway.handleDesktopEnvelope(event)
	if !sender.waitForCount(1, time.Second) {
		t.Fatalf("timed out waiting for remote push send")
	}

	if got := sender.count(); got != 1 {
		t.Fatalf("remote push send count = %d, want 1", got)
	}
	sent := sender.payloadAt(0)
	if sent.TargetType != "tool" || sent.TargetID != "tool-1" || sent.SessionID != "session-1" || !sent.RequiresConfirmation {
		t.Fatalf("remote push payload = %#v", sent)
	}
}

func TestMobileGatewayUnknownCommandReturnsError(t *testing.T) {
	gateway := newTestMobileGateway(t)
	_, deviceToken := claimTestDevice(t, gateway, "Pixel")
	server := httptest.NewServer(gateway.routes())
	defer server.Close()

	header := http.Header{}
	header.Set("Authorization", "Bearer "+deviceToken)
	conn, _, err := websocket.DefaultDialer.Dial(mobileTestWSURL(server.URL)+"/mobile/ws", header)
	if err != nil {
		t.Fatalf("dial device websocket: %v", err)
	}
	defer conn.Close()

	if err := conn.WriteJSON(MobileEnvelope{ID: "cmd-1", Type: "unknown.command"}); err != nil {
		t.Fatalf("write unknown command: %v", err)
	}
	var response MobileEnvelope
	if err := conn.ReadJSON(&response); err != nil {
		t.Fatalf("read error response: %v", err)
	}
	if response.Type != "error" {
		t.Fatalf("response type = %q, want error", response.Type)
	}
}

func TestMobileGatewayRevokeDeviceDisconnectsWebSocket(t *testing.T) {
	gateway := newTestMobileGateway(t)
	device, deviceToken := claimTestDevice(t, gateway, "Pixel")
	server := httptest.NewServer(gateway.routes())
	defer server.Close()

	header := http.Header{}
	header.Set("Authorization", "Bearer "+deviceToken)
	conn, _, err := websocket.DefaultDialer.Dial(mobileTestWSURL(server.URL)+"/mobile/ws", header)
	if err != nil {
		t.Fatalf("dial device websocket: %v", err)
	}
	defer conn.Close()

	body, err := json.Marshal(mobileRevokeRequest{DeviceID: device.ID})
	if err != nil {
		t.Fatalf("marshal revoke request: %v", err)
	}
	req, err := http.NewRequest(http.MethodPost, server.URL+"/mobile/devices/revoke", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("new revoke request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer desktop-secret")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST revoke: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("revoke status = %d, want 200", resp.StatusCode)
	}

	_ = conn.SetReadDeadline(time.Now().Add(time.Second))
	var message MobileEnvelope
	if err := conn.ReadJSON(&message); err == nil {
		t.Fatalf("expected revoked websocket to close")
	}

	if _, _, err := websocket.DefaultDialer.Dial(mobileTestWSURL(server.URL)+"/mobile/ws", header); err == nil {
		t.Fatalf("expected revoked device token to reject reconnect")
	}
}

func newTestMobileGateway(t *testing.T) *MobileGateway {
	t.Helper()
	cfg, err := NewMobileGatewayConfig(MobileGatewayConfigInput{
		Host:         "127.0.0.1",
		Port:         8876,
		DesktopName:  "Test Mac",
		DesktopToken: "desktop-secret",
		PairingTTL:   time.Minute,
		AllowPairing: true,
	})
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	gateway, err := NewMobileGateway(cfg)
	if err != nil {
		t.Fatalf("gateway: %v", err)
	}
	now := time.Date(2026, 6, 13, 12, 0, 0, 0, time.UTC)
	gateway.now = func() time.Time { return now }
	gateway.mu.Lock()
	if err := gateway.rotatePairingTokenLocked(now); err != nil {
		t.Fatalf("rotate pairing token: %v", err)
	}
	gateway.mu.Unlock()
	return gateway
}

func claimTestDevice(t *testing.T, gateway *MobileGateway, name string) (mobileDevice, string) {
	t.Helper()
	gateway.mu.Lock()
	token := gateway.pairingToken
	gateway.mu.Unlock()
	device, deviceToken, err := gateway.claimPairingToken(token, name)
	if err != nil {
		t.Fatalf("claim test device: %v", err)
	}
	return device, deviceToken
}

func mobileTestWSURL(httpURL string) string {
	return "ws" + strings.TrimPrefix(httpURL, "http")
}

type fakeMobilePushSender struct {
	mu       sync.Mutex
	payloads []mobileRemoteAttentionPayload
	notify   chan struct{}
}

func (s *fakeMobilePushSender) Send(_ context.Context, _ string, payload mobileRemoteAttentionPayload) error {
	s.mu.Lock()
	if s.notify == nil {
		s.notify = make(chan struct{})
	}
	s.payloads = append(s.payloads, payload)
	close(s.notify)
	s.notify = make(chan struct{})
	s.mu.Unlock()
	return nil
}

func (s *fakeMobilePushSender) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.payloads)
}

func (s *fakeMobilePushSender) payloadAt(index int) mobileRemoteAttentionPayload {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.payloads[index]
}

func (s *fakeMobilePushSender) waitForCount(count int, timeout time.Duration) bool {
	deadline := time.After(timeout)
	for {
		s.mu.Lock()
		if len(s.payloads) >= count {
			s.mu.Unlock()
			return true
		}
		if s.notify == nil {
			s.notify = make(chan struct{})
		}
		notify := s.notify
		s.mu.Unlock()
		select {
		case <-notify:
		case <-deadline:
			return false
		}
	}
}
