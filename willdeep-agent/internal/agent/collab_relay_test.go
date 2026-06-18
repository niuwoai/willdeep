package agent

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCollaborationRelayHealthIncludesCallbacks(t *testing.T) {
	relay := newTestCollaborationRelay(t)
	server := httptest.NewServer(relay.routes())
	defer server.Close()

	resp, err := http.Get(server.URL + "/collab/health")
	if err != nil {
		t.Fatalf("GET health: %v", err)
	}
	defer resp.Body.Close()
	if got := resp.Header.Get("X-App-Version"); got != Version {
		t.Fatalf("X-App-Version = %q, want %q", got, Version)
	}

	var body APIResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode health: %v", err)
	}
	data, ok := body.Data.(map[string]any)
	if !ok {
		t.Fatalf("health data = %#v", body.Data)
	}
	callbacks, ok := data["oauth_callbacks"].(map[string]any)
	if !ok {
		t.Fatalf("oauth_callbacks = %#v", data["oauth_callbacks"])
	}
	if callbacks["feishu"] != "https://fly.niuwoai.com/oauth/feishu/callback" {
		t.Fatalf("feishu callback = %#v", callbacks["feishu"])
	}
}

func TestCollaborationRelayOAuthCallbackRedirectsToDesktopScheme(t *testing.T) {
	relay := newTestCollaborationRelay(t)
	server := httptest.NewServer(relay.routes())
	defer server.Close()

	client := server.Client()
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		return http.ErrUseLastResponse
	}
	resp, err := client.Get(server.URL + "/oauth/feishu/callback?code=abc&state=nonce")
	if err != nil {
		t.Fatalf("GET oauth callback: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("status = %d, want 302", resp.StatusCode)
	}
	location := resp.Header.Get("Location")
	if location != "willdeep://oauth/feishu/callback?code=abc&state=nonce" {
		t.Fatalf("Location = %q", location)
	}
}

func TestCollaborationRelayFeishuChallengeReturnsRawChallenge(t *testing.T) {
	relay := newTestCollaborationRelay(t)
	server := httptest.NewServer(relay.routes())
	defer server.Close()

	resp, err := http.Post(
		server.URL+"/events/feishu",
		"application/json",
		strings.NewReader(`{"challenge":"verify-me","type":"url_verification"}`),
	)
	if err != nil {
		t.Fatalf("POST feishu challenge: %v", err)
	}
	defer resp.Body.Close()

	var body map[string]string
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode challenge: %v", err)
	}
	if body["challenge"] != "verify-me" {
		t.Fatalf("challenge = %q", body["challenge"])
	}
}

func TestCollaborationRelayQueuesAndPollsEventsWithAuth(t *testing.T) {
	relay := newTestCollaborationRelay(t)
	server := httptest.NewServer(relay.routes())
	defer server.Close()

	resp, err := http.Post(
		server.URL+"/events/dingtalk",
		"application/json",
		bytes.NewBufferString(`{"EventType":"chat_update","conversationId":"cid"}`),
	)
	if err != nil {
		t.Fatalf("POST dingtalk event: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("event status = %d, want 200", resp.StatusCode)
	}

	resp, err = http.Get(server.URL + "/events/poll")
	if err != nil {
		t.Fatalf("GET poll without auth: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("poll without auth status = %d, want 401", resp.StatusCode)
	}

	req, err := http.NewRequest(http.MethodGet, server.URL+"/events/poll", nil)
	if err != nil {
		t.Fatalf("new poll request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer relay-secret")
	resp, err = server.Client().Do(req)
	if err != nil {
		t.Fatalf("GET poll: %v", err)
	}
	defer resp.Body.Close()

	var body APIResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode poll: %v", err)
	}
	if !body.OK {
		t.Fatalf("poll response not ok: %#v", body)
	}
	data, ok := body.Data.(map[string]any)
	if !ok {
		t.Fatalf("poll data = %#v", body.Data)
	}
	events, ok := data["events"].([]any)
	if !ok || len(events) != 1 {
		t.Fatalf("events = %#v, want one event", data["events"])
	}
	event, ok := events[0].(map[string]any)
	if !ok {
		t.Fatalf("event = %#v", events[0])
	}
	if event["platform"] != "dingtalk" || event["kind"] != "chat_update" {
		t.Fatalf("event = %#v", event)
	}
}

func newTestCollaborationRelay(t *testing.T) *CollaborationRelay {
	t.Helper()
	cfg, err := NewCollaborationRelayConfig(CollaborationRelayConfigInput{
		Host:          "127.0.0.1",
		Port:          8898,
		PublicBaseURL: "https://fly.niuwoai.com",
		Token:         "relay-secret",
		MaxEvents:     10,
	})
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	return NewCollaborationRelay(cfg)
}
