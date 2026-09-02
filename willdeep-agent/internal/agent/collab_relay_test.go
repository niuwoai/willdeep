package agent

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/larksuite/oapi-sdk-go/v3/event/dispatcher"
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
	if got := resp.Header.Get("X-WillDeep-App-Version"); got != Version {
		t.Fatalf("X-WillDeep-App-Version = %q, want %q", got, Version)
	}
	if got := resp.Header.Get("X-App-Version"); got != "" {
		t.Fatalf("X-App-Version = %q, want empty for relay responses", got)
	}
	if got := resp.Header.Get("X-WillDeep-Relay-Protocol"); got != CollaborationRelayProtocolVersion {
		t.Fatalf("X-WillDeep-Relay-Protocol = %q, want %q", got, CollaborationRelayProtocolVersion)
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
	setupURLs, ok := data["setup_urls"].(map[string]any)
	if !ok {
		t.Fatalf("setup_urls = %#v", data["setup_urls"])
	}
	if setupURLs["feishu"] != "https://fly.niuwoai.com/connectors/feishu/setup" {
		t.Fatalf("feishu setup url = %#v", setupURLs["feishu"])
	}
}

func TestCollaborationRelayFeishuSetupRedirectsToAuthorization(t *testing.T) {
	relay := newTestCollaborationRelay(t)
	server := httptest.NewServer(relay.routes())
	defer server.Close()

	client := server.Client()
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		return http.ErrUseLastResponse
	}
	resp, err := client.Get(server.URL + "/connectors/feishu/setup?state=nonce")
	if err != nil {
		t.Fatalf("GET setup: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("status = %d, want 302", resp.StatusCode)
	}
	location := resp.Header.Get("Location")
	if !strings.HasPrefix(location, "https://open.feishu.cn/open-apis/authen/v1/index?") {
		t.Fatalf("Location = %q", location)
	}
	if !strings.Contains(location, "app_id=cli_test") {
		t.Fatalf("Location missing app_id: %q", location)
	}
	if !strings.Contains(location, "redirect_uri=https%3A%2F%2Ffly.niuwoai.com%2Foauth%2Ffeishu%2Fcallback") {
		t.Fatalf("Location missing redirect_uri: %q", location)
	}
	if !strings.Contains(location, "state=nonce") {
		t.Fatalf("Location missing state: %q", location)
	}
}

func TestCollaborationRelayFeishuSetupRequiresAppID(t *testing.T) {
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
	relay := NewCollaborationRelay(cfg)
	server := httptest.NewServer(relay.routes())
	defer server.Close()

	resp, err := http.Get(server.URL + "/connectors/feishu/setup?state=nonce")
	if err != nil {
		t.Fatalf("GET setup: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", resp.StatusCode)
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

	resp := authorizedRelayJSONRequest(
		t,
		server,
		http.MethodPost,
		"/events/feishu",
		`{"challenge":"verify-me","type":"url_verification"}`,
	)
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

	unauthorized, err := http.Post(
		server.URL+"/events/dingtalk",
		"application/json",
		strings.NewReader(`{"EventType":"chat_update"}`),
	)
	if err != nil {
		t.Fatalf("POST unauthorized event: %v", err)
	}
	_ = unauthorized.Body.Close()
	if unauthorized.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthorized event status = %d, want 401", unauthorized.StatusCode)
	}

	resp := authorizedRelayJSONRequest(
		t,
		server,
		http.MethodPost,
		"/events/dingtalk",
		`{"EventType":"chat_update","eventId":"evt-42","conversationId":"cid"}`,
	)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("event status = %d, want 200", resp.StatusCode)
	}

	duplicate := authorizedRelayJSONRequest(
		t,
		server,
		http.MethodPost,
		"/events/dingtalk",
		`{"EventType":"chat_update","eventId":"evt-42","conversationId":"cid"}`,
	)
	var duplicateBody APIResponse
	if err := json.NewDecoder(duplicate.Body).Decode(&duplicateBody); err != nil {
		t.Fatalf("decode duplicate event response: %v", err)
	}
	_ = duplicate.Body.Close()
	duplicateData, ok := duplicateBody.Data.(map[string]any)
	if !ok || duplicateData["queued"] != false {
		t.Fatalf("duplicate event response = %#v, want queued=false", duplicateBody.Data)
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
	if event["authenticated_ingress"] != true {
		t.Fatalf("authenticated_ingress = %#v, want true", event["authenticated_ingress"])
	}
	eventID, ok := event["id"].(string)
	if !ok || eventID == "" {
		t.Fatalf("event id = %#v", event["id"])
	}
	_ = resp.Body.Close()

	// Polling leases nothing and deletes nothing. A consumer must persist the
	// event locally and explicitly acknowledge it.
	secondPoll := authorizedRelayJSONRequest(t, server, http.MethodGet, "/events/poll", "")
	var secondBody APIResponse
	if err := json.NewDecoder(secondPoll.Body).Decode(&secondBody); err != nil {
		t.Fatalf("decode second poll: %v", err)
	}
	_ = secondPoll.Body.Close()
	secondData := secondBody.Data.(map[string]any)
	if secondEvents := secondData["events"].([]any); len(secondEvents) != 1 {
		t.Fatalf("second poll events = %#v, want one retained event", secondEvents)
	}

	ack := authorizedRelayJSONRequest(
		t,
		server,
		http.MethodPost,
		"/events/ack",
		`{"event_ids":["`+eventID+`"]}`,
	)
	if ack.StatusCode != http.StatusOK {
		t.Fatalf("ack status = %d", ack.StatusCode)
	}
	_ = ack.Body.Close()

	finalPoll := authorizedRelayJSONRequest(t, server, http.MethodGet, "/events/poll", "")
	var finalBody APIResponse
	if err := json.NewDecoder(finalPoll.Body).Decode(&finalBody); err != nil {
		t.Fatalf("decode final poll: %v", err)
	}
	_ = finalPoll.Body.Close()
	finalData := finalBody.Data.(map[string]any)
	if finalEvents := finalData["events"].([]any); len(finalEvents) != 0 {
		t.Fatalf("final poll events = %#v, want empty after ack", finalEvents)
	}
}

func TestCollaborationRelayPersistsUnacknowledgedEventsAcrossRestart(t *testing.T) {
	journalPath := filepath.Join(t.TempDir(), "relay-events.json")
	cfg, err := NewCollaborationRelayConfig(CollaborationRelayConfigInput{
		Host:           "127.0.0.1",
		Port:           8898,
		PublicBaseURL:  "https://fly.niuwoai.com",
		Token:          "relay-secret",
		MaxEvents:      10,
		EventStoreFile: journalPath,
	})
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	first := NewCollaborationRelay(cfg)
	if first.startupError != nil {
		t.Fatalf("first startup: %v", first.startupError)
	}
	event := CollaborationRelayEvent{
		ID:                   "evt-persisted",
		Platform:             "feishu",
		Kind:                 "im.message.receive_v1",
		ReceivedAt:           time.Now().UTC(),
		Body:                 json.RawMessage(`{"message":"hello"}`),
		AuthenticatedIngress: true,
	}
	if _, err := first.enqueue(event); err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	info, err := os.Stat(journalPath)
	if err != nil {
		t.Fatalf("stat journal: %v", err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("journal permissions = %o, want 600", got)
	}

	second := NewCollaborationRelay(cfg)
	if second.startupError != nil {
		t.Fatalf("second startup: %v", second.startupError)
	}
	second.mu.Lock()
	defer second.mu.Unlock()
	if len(second.events) != 1 || second.events[0].ID != event.ID {
		t.Fatalf("restored events = %#v", second.events)
	}
}

func TestCollaborationRelayLongConnectionRequiresSecret(t *testing.T) {
	_, err := NewCollaborationRelayConfig(CollaborationRelayConfigInput{
		Host:                        "127.0.0.1",
		Port:                        8898,
		PublicBaseURL:               "https://fly.niuwoai.com",
		Token:                       "relay-secret",
		FeishuAppID:                 "cli_test",
		FeishuLongConnectionEnabled: true,
		MaxEvents:                   10,
	})
	if err == nil || !strings.Contains(err.Error(), "feishu app secret") {
		t.Fatalf("err = %v, want feishu app secret error", err)
	}
}

func TestCollaborationRelayFeishuLongConnectionQueuesEvents(t *testing.T) {
	originalFactory := newFeishuLongConnectionClient
	defer func() {
		newFeishuLongConnectionClient = originalFactory
	}()

	started := make(chan *dispatcher.EventDispatcher, 1)
	newFeishuLongConnectionClient = func(config CollaborationRelayConfig, eventHandler *dispatcher.EventDispatcher, callbacks feishuLongConnectionCallbacks) feishuLongConnectionClient {
		return &fakeFeishuLongConnectionClient{
			handler:   eventHandler,
			callbacks: callbacks,
			started:   started,
		}
	}

	cfg, err := NewCollaborationRelayConfig(CollaborationRelayConfigInput{
		Host:                           "127.0.0.1",
		Port:                           8898,
		PublicBaseURL:                  "https://fly.niuwoai.com",
		Token:                          "relay-secret",
		FeishuAppID:                    "cli_test",
		FeishuAppSecret:                "secret",
		FeishuLongConnectionEnabled:    true,
		FeishuLongConnectionEventTypes: "im.message.receive_v1",
		MaxEvents:                      10,
	})
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	relay := NewCollaborationRelay(cfg)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := relay.StartBackgroundTransports(ctx); err != nil {
		t.Fatalf("start transports: %v", err)
	}

	var handler *dispatcher.EventDispatcher
	select {
	case handler = <-started:
	case <-time.After(time.Second):
		t.Fatal("long connection client did not start")
	}
	longConnectionEvent := []byte(`{"schema":"2.0","header":{"event_id":"evt-long-1","event_type":"im.message.receive_v1"},"event":{"message":{"chat_id":"oc_test"}}}`)
	_, err = handler.Do(context.Background(), longConnectionEvent)
	if err != nil {
		t.Fatalf("dispatch event: %v", err)
	}
	_, err = handler.Do(context.Background(), longConnectionEvent)
	if err != nil {
		t.Fatalf("dispatch duplicate event: %v", err)
	}

	req, err := http.NewRequest(http.MethodGet, "/events/poll", nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer relay-secret")
	recorder := httptest.NewRecorder()
	relay.withAuth(relay.handlePollEvents)(recorder, req)
	if recorder.Code != http.StatusOK {
		t.Fatalf("poll status = %d, body = %s", recorder.Code, recorder.Body.String())
	}

	var body APIResponse
	if err := json.NewDecoder(recorder.Body).Decode(&body); err != nil {
		t.Fatalf("decode poll: %v", err)
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
	if event["platform"] != "feishu" || event["kind"] != "im.message.receive_v1" {
		t.Fatalf("event = %#v", event)
	}
	if event["remote_addr"] != "feishu-long-connection" {
		t.Fatalf("remote_addr = %#v", event["remote_addr"])
	}
}

func newTestCollaborationRelay(t *testing.T) *CollaborationRelay {
	t.Helper()
	cfg, err := NewCollaborationRelayConfig(CollaborationRelayConfigInput{
		Host:          "127.0.0.1",
		Port:          8898,
		PublicBaseURL: "https://fly.niuwoai.com",
		Token:         "relay-secret",
		FeishuAppID:   "cli_test",
		MaxEvents:     10,
	})
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	return NewCollaborationRelay(cfg)
}

func authorizedRelayJSONRequest(
	t *testing.T,
	server *httptest.Server,
	method string,
	path string,
	body string,
) *http.Response {
	t.Helper()
	var reader *strings.Reader
	if body == "" {
		reader = strings.NewReader("")
	} else {
		reader = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, server.URL+path, reader)
	if err != nil {
		t.Fatalf("new %s %s request: %v", method, path, err)
	}
	req.Header.Set("Authorization", "Bearer relay-secret")
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := server.Client().Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	return resp
}

type fakeFeishuLongConnectionClient struct {
	handler   *dispatcher.EventDispatcher
	callbacks feishuLongConnectionCallbacks
	started   chan<- *dispatcher.EventDispatcher
}

func (c *fakeFeishuLongConnectionClient) Start(ctx context.Context) error {
	c.callbacks.OnReady()
	c.started <- c.handler
	<-ctx.Done()
	return nil
}

func (c *fakeFeishuLongConnectionClient) Close() {}
