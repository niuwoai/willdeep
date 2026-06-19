package agent

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const CollaborationRelayProtocolVersion = "collab-relay.v1"

const (
	defaultCollaborationRelayBaseURL   = "https://fly.niuwoai.com"
	defaultCollaborationRelayMaxEvents = 500
	collaborationRelayMaxBodyBytes     = 1 * 1024 * 1024
)

type CollaborationRelayConfigInput struct {
	Host                           string
	Port                           int
	PublicBaseURL                  string
	Token                          string
	TokenFile                      string
	FeishuAppID                    string
	FeishuAppSecret                string
	FeishuAppSecretFile            string
	FeishuLongConnectionEnabled    bool
	FeishuLongConnectionEventTypes string
	MaxEvents                      int
}

type CollaborationRelayConfig struct {
	Host                           string
	Port                           int
	PublicBaseURL                  string
	Token                          string
	FeishuAppID                    string
	FeishuAppSecret                string
	FeishuLongConnectionEnabled    bool
	FeishuLongConnectionEventTypes []string
	MaxEvents                      int
}

type CollaborationRelay struct {
	config CollaborationRelayConfig

	mu                         sync.Mutex
	events                     []CollaborationRelayEvent
	feishuLongConnectionStatus CollaborationRelayTransportStatus
	now                        func() time.Time
}

type CollaborationRelayEvent struct {
	ID         string          `json:"id"`
	Platform   string          `json:"platform"`
	Kind       string          `json:"kind"`
	ReceivedAt time.Time       `json:"received_at"`
	RemoteAddr string          `json:"remote_addr"`
	Headers    map[string]any  `json:"headers,omitempty"`
	Body       json.RawMessage `json:"body,omitempty"`
}

type CollaborationRelayTransportStatus struct {
	Enabled    bool      `json:"enabled"`
	Configured bool      `json:"configured"`
	State      string    `json:"state"`
	EventTypes []string  `json:"event_types,omitempty"`
	LastError  string    `json:"last_error,omitempty"`
	UpdatedAt  time.Time `json:"updated_at,omitempty"`
}

type collaborationRelayPlatform struct {
	name string
}

var collaborationRelayPlatforms = map[string]collaborationRelayPlatform{
	"feishu":   {name: "feishu"},
	"dingtalk": {name: "dingtalk"},
	"wecom":    {name: "wecom"},
}

func NewCollaborationRelayConfig(input CollaborationRelayConfigInput) (CollaborationRelayConfig, error) {
	host := strings.TrimSpace(input.Host)
	if host == "" {
		host = "127.0.0.1"
	}
	port := input.Port
	if port <= 0 || port > 65535 {
		return CollaborationRelayConfig{}, fmt.Errorf("invalid port: %d", port)
	}
	baseURL := strings.TrimRight(strings.TrimSpace(input.PublicBaseURL), "/")
	if baseURL == "" {
		baseURL = defaultCollaborationRelayBaseURL
	}
	parsedBaseURL, err := url.Parse(baseURL)
	if err != nil || parsedBaseURL.Scheme == "" || parsedBaseURL.Host == "" {
		return CollaborationRelayConfig{}, fmt.Errorf("invalid public base url: %q", baseURL)
	}
	token, err := loadToken(input.Token, input.TokenFile)
	if err != nil {
		return CollaborationRelayConfig{}, err
	}
	if token == "" {
		token, err = randomToken()
		if err != nil {
			return CollaborationRelayConfig{}, err
		}
	}
	feishuAppID := strings.TrimSpace(input.FeishuAppID)
	feishuAppSecret, err := loadSecret(input.FeishuAppSecret, input.FeishuAppSecretFile, "WILLDEEP_FEISHU_APP_SECRET")
	if err != nil {
		return CollaborationRelayConfig{}, err
	}
	feishuLongConnectionEventTypes := normalizeList(input.FeishuLongConnectionEventTypes)
	if len(feishuLongConnectionEventTypes) == 0 {
		feishuLongConnectionEventTypes = defaultFeishuLongConnectionEventTypes()
	}
	if input.FeishuLongConnectionEnabled {
		if feishuAppID == "" {
			return CollaborationRelayConfig{}, errors.New("feishu long connection requires feishu app id")
		}
		if feishuAppSecret == "" {
			return CollaborationRelayConfig{}, errors.New("feishu long connection requires feishu app secret")
		}
	}
	maxEvents := input.MaxEvents
	if maxEvents <= 0 {
		maxEvents = defaultCollaborationRelayMaxEvents
	}
	return CollaborationRelayConfig{
		Host:                           host,
		Port:                           port,
		PublicBaseURL:                  baseURL,
		Token:                          token,
		FeishuAppID:                    feishuAppID,
		FeishuAppSecret:                feishuAppSecret,
		FeishuLongConnectionEnabled:    input.FeishuLongConnectionEnabled,
		FeishuLongConnectionEventTypes: feishuLongConnectionEventTypes,
		MaxEvents:                      maxEvents,
	}, nil
}

func ServeCollaborationRelay(ctx context.Context, config CollaborationRelayConfig) error {
	relay := NewCollaborationRelay(config)
	if err := relay.StartBackgroundTransports(ctx); err != nil {
		return err
	}
	addr := net.JoinHostPort(config.Host, strconv.Itoa(config.Port))
	httpServer := &http.Server{Addr: addr, Handler: relay.routes()}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdownCtx)
	}()

	log.Printf(
		"willdeep-agent collaboration relay %s listening on http://%s public=%s protocol=%s",
		Version,
		addr,
		config.PublicBaseURL,
		CollaborationRelayProtocolVersion,
	)
	err := httpServer.ListenAndServe()
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func NewCollaborationRelay(config CollaborationRelayConfig) *CollaborationRelay {
	relay := &CollaborationRelay{
		config: config,
		now:    time.Now,
	}
	relay.setFeishuLongConnectionStatus("disabled", "")
	return relay
}

func (r *CollaborationRelay) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /collab/health", r.handleHealth)
	mux.HandleFunc("GET /connectors/feishu/setup", r.handleFeishuSetup)
	mux.HandleFunc("GET /oauth/{platform}/callback", r.handleOAuthCallback)
	mux.HandleFunc("POST /events/{platform}", r.handleEvent)
	mux.HandleFunc("GET /events/poll", r.withAuth(r.handlePollEvents))
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		writeCollaborationRelayVersionHeaders(w)
		mux.ServeHTTP(w, req)
	})
}

func (r *CollaborationRelay) withAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		auth := strings.TrimSpace(req.Header.Get("Authorization"))
		queryToken := req.URL.Query().Get("token")
		want := r.config.Token
		if auth != "Bearer "+want && subtle.ConstantTimeCompare([]byte(queryToken), []byte(want)) != 1 {
			writeCollaborationRelayError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		next(w, req)
	}
}

func (r *CollaborationRelay) handleHealth(w http.ResponseWriter, req *http.Request) {
	r.mu.Lock()
	queued := len(r.events)
	feishuLongConnectionStatus := r.feishuLongConnectionStatus
	r.mu.Unlock()
	writeCollaborationRelayOK(w, map[string]any{
		"version":          VersionInfo(),
		"protocol_version": CollaborationRelayProtocolVersion,
		"public_base_url":  r.config.PublicBaseURL,
		"oauth_callbacks": map[string]string{
			"feishu":   r.config.PublicBaseURL + "/oauth/feishu/callback",
			"dingtalk": r.config.PublicBaseURL + "/oauth/dingtalk/callback",
			"wecom":    r.config.PublicBaseURL + "/oauth/wecom/callback",
		},
		"event_callbacks": map[string]string{
			"feishu":   r.config.PublicBaseURL + "/events/feishu",
			"dingtalk": r.config.PublicBaseURL + "/events/dingtalk",
			"wecom":    r.config.PublicBaseURL + "/events/wecom",
		},
		"setup_urls": map[string]string{
			"feishu": r.config.PublicBaseURL + "/connectors/feishu/setup",
		},
		"event_transports": map[string]any{
			"feishu_long_connection": feishuLongConnectionStatus,
		},
		"queued_events": queued,
	})
}

func (r *CollaborationRelay) handleFeishuSetup(w http.ResponseWriter, req *http.Request) {
	appID := strings.TrimSpace(r.config.FeishuAppID)
	if appID == "" {
		writeCollaborationRelayError(w, http.StatusServiceUnavailable, "feishu app id is not configured")
		return
	}
	state := strings.TrimSpace(req.URL.Query().Get("state"))
	if state == "" {
		writeCollaborationRelayError(w, http.StatusBadRequest, "missing state")
		return
	}

	authorizationURL := feishuAuthorizationURL(
		appID,
		r.config.PublicBaseURL+"/oauth/feishu/callback",
		state,
	)
	if req.URL.Query().Get("format") == "json" {
		writeCollaborationRelayOK(w, map[string]any{
			"configured":        true,
			"authorization_url": authorizationURL,
		})
		return
	}
	http.Redirect(w, req, authorizationURL, http.StatusFound)
}

func (r *CollaborationRelay) handleOAuthCallback(w http.ResponseWriter, req *http.Request) {
	platform, ok := collaborationRelayPlatformFor(req.PathValue("platform"))
	if !ok {
		writeCollaborationRelayError(w, http.StatusNotFound, "unknown collaboration platform")
		return
	}

	callbackURL := url.URL{
		Scheme:   "willdeep",
		Host:     "oauth",
		Path:     "/" + platform.name + "/callback",
		RawQuery: req.URL.RawQuery,
	}
	if req.URL.Query().Get("format") == "json" {
		writeCollaborationRelayOK(w, map[string]any{"redirect_url": callbackURL.String()})
		return
	}
	http.Redirect(w, req, callbackURL.String(), http.StatusFound)
}

func (r *CollaborationRelay) handleEvent(w http.ResponseWriter, req *http.Request) {
	platform, ok := collaborationRelayPlatformFor(req.PathValue("platform"))
	if !ok {
		writeCollaborationRelayError(w, http.StatusNotFound, "unknown collaboration platform")
		return
	}

	body, err := io.ReadAll(http.MaxBytesReader(w, req.Body, collaborationRelayMaxBodyBytes))
	if err != nil {
		writeCollaborationRelayError(w, http.StatusRequestEntityTooLarge, "event body too large")
		return
	}
	if len(strings.TrimSpace(string(body))) == 0 {
		writeCollaborationRelayError(w, http.StatusBadRequest, "empty event body")
		return
	}

	var envelope map[string]any
	if err := json.Unmarshal(body, &envelope); err != nil {
		writeCollaborationRelayError(w, http.StatusBadRequest, "invalid json event body")
		return
	}
	if challenge, ok := stringValue(envelope["challenge"]); ok && challenge != "" {
		w.Header().Set("Content-Type", "application/json")
		writeCollaborationRelayVersionHeaders(w)
		_ = json.NewEncoder(w).Encode(map[string]string{"challenge": challenge})
		return
	}

	event := CollaborationRelayEvent{
		ID:         newRelayEventID(platform.name, r.now()),
		Platform:   platform.name,
		Kind:       relayEventKind(envelope),
		ReceivedAt: r.now().UTC(),
		RemoteAddr: req.RemoteAddr,
		Headers:    relayHeaders(req),
		Body:       append(json.RawMessage(nil), body...),
	}
	r.enqueue(event)
	writeCollaborationRelayOK(w, map[string]any{"event_id": event.ID, "queued": true})
}

func (r *CollaborationRelay) handlePollEvents(w http.ResponseWriter, req *http.Request) {
	limit := queryInt(req, "limit", 50)
	r.mu.Lock()
	if limit > len(r.events) {
		limit = len(r.events)
	}
	events := append([]CollaborationRelayEvent(nil), r.events[:limit]...)
	r.events = append([]CollaborationRelayEvent(nil), r.events[limit:]...)
	remaining := len(r.events)
	r.mu.Unlock()

	writeCollaborationRelayOK(w, map[string]any{
		"events":    events,
		"remaining": remaining,
	})
}

func (r *CollaborationRelay) enqueue(event CollaborationRelayEvent) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, event)
	if len(r.events) <= r.config.MaxEvents {
		return
	}
	drop := len(r.events) - r.config.MaxEvents
	r.events = append([]CollaborationRelayEvent(nil), r.events[drop:]...)
}

func (r *CollaborationRelay) setFeishuLongConnectionStatus(state string, lastError string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.feishuLongConnectionStatus = CollaborationRelayTransportStatus{
		Enabled:    r.config.FeishuLongConnectionEnabled,
		Configured: r.config.FeishuLongConnectionEnabled && r.config.FeishuAppID != "" && r.config.FeishuAppSecret != "",
		State:      state,
		EventTypes: append([]string(nil), r.config.FeishuLongConnectionEventTypes...),
		LastError:  sanitizeRelayError(lastError),
		UpdatedAt:  r.now().UTC(),
	}
}

func writeCollaborationRelayOK(w http.ResponseWriter, data any) {
	writeCollaborationRelayAPI(w, http.StatusOK, APIResponse{OK: true, Data: data})
}

func writeCollaborationRelayError(w http.ResponseWriter, status int, message string) {
	writeCollaborationRelayAPI(w, status, APIResponse{OK: false, Error: message})
}

func writeCollaborationRelayAPI(w http.ResponseWriter, status int, response APIResponse) {
	w.Header().Set("Content-Type", "application/json")
	writeCollaborationRelayVersionHeaders(w)
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(response)
}

func writeCollaborationRelayVersionHeaders(w http.ResponseWriter) {
	w.Header().Set("X-WillDeep-App-Version", Version)
	w.Header().Set("X-WillDeep-Server-Version", Version)
}

func collaborationRelayPlatformFor(value string) (collaborationRelayPlatform, bool) {
	platform, ok := collaborationRelayPlatforms[strings.ToLower(strings.TrimSpace(value))]
	return platform, ok
}

func relayHeaders(req *http.Request) map[string]any {
	headers := map[string]any{}
	for _, key := range []string{
		"X-Lark-Request-Timestamp",
		"X-Lark-Request-Nonce",
		"X-Lark-Signature",
		"X-Dingtalk-Signature",
		"X-Dingtalk-Timestamp",
		"X-Dingtalk-Nonce",
		"User-Agent",
	} {
		if value := req.Header.Get(key); value != "" {
			headers[key] = value
		}
	}
	return headers
}

func relayEventKind(envelope map[string]any) string {
	for _, key := range []string{"type", "event_type", "EventType", "msgtype"} {
		if value, ok := stringValue(envelope[key]); ok && value != "" {
			return value
		}
	}
	if header, ok := envelope["header"].(map[string]any); ok {
		if value, ok := stringValue(header["event_type"]); ok && value != "" {
			return value
		}
	}
	return "event"
}

func newRelayEventID(platform string, now time.Time) string {
	return fmt.Sprintf("%s-%d", platform, now.UTC().UnixNano())
}

func feishuAuthorizationURL(appID string, redirectURI string, state string) string {
	authorizationURL := url.URL{
		Scheme: "https",
		Host:   "open.feishu.cn",
		Path:   "/open-apis/authen/v1/index",
	}
	query := authorizationURL.Query()
	query.Set("app_id", appID)
	query.Set("redirect_uri", redirectURI)
	query.Set("state", state)
	authorizationURL.RawQuery = query.Encode()
	return authorizationURL.String()
}

func stringValue(value any) (string, bool) {
	switch typed := value.(type) {
	case string:
		return typed, true
	default:
		return "", false
	}
}

func loadSecret(secret string, secretFile string, envName string) (string, error) {
	if secret == "" && envName != "" {
		secret = os.Getenv(envName)
	}
	if secret == "" && secretFile != "" {
		data, err := os.ReadFile(secretFile)
		if err != nil {
			return "", fmt.Errorf("read secret file: %w", err)
		}
		secret = string(data)
	}
	return strings.TrimSpace(secret), nil
}

func normalizeList(value string) []string {
	seen := map[string]bool{}
	items := []string{}
	for _, part := range strings.Split(value, ",") {
		item := strings.TrimSpace(part)
		if item == "" || seen[item] {
			continue
		}
		seen[item] = true
		items = append(items, item)
	}
	return items
}

func defaultFeishuLongConnectionEventTypes() []string {
	return []string{
		"im.message.receive_v1",
		"application.bot.menu_v6",
	}
}

func sanitizeRelayError(message string) string {
	message = strings.TrimSpace(message)
	if message == "" {
		return ""
	}
	if len(message) > 240 {
		return message[:240]
	}
	return message
}
