package agent

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
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

	event := MobileEnvelope{
		ID:        "evt-1",
		Type:      "message.delta",
		SessionID: "session-1",
		Payload:   map[string]any{"delta": "world"},
	}
	if err := desktopConn.WriteJSON(event); err != nil {
		t.Fatalf("write desktop event: %v", err)
	}
	var received MobileEnvelope
	if err := deviceConn.ReadJSON(&received); err != nil {
		t.Fatalf("device read desktop event: %v", err)
	}
	if received.Type != event.Type || received.ID != event.ID {
		t.Fatalf("desktop event = %#v", received)
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
