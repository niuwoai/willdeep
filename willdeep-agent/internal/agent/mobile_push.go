package agent

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const defaultUmengPushEndpoint = "https://msgapi.umeng.com/api/send"

type MobileRemotePushConfig struct {
	Enabled         bool
	Provider        string
	AppKey          string
	AppMasterSecret string
	Endpoint        string
	ProductionMode  bool
}

func (c MobileRemotePushConfig) Normalize() MobileRemotePushConfig {
	c.Provider = strings.ToLower(strings.TrimSpace(c.Provider))
	if c.Provider == "" {
		c.Provider = "umeng"
	}
	c.AppKey = strings.TrimSpace(c.AppKey)
	c.AppMasterSecret = strings.TrimSpace(c.AppMasterSecret)
	c.Endpoint = strings.TrimSpace(c.Endpoint)
	if c.Endpoint == "" {
		c.Endpoint = defaultUmengPushEndpoint
	}
	c.Enabled = c.Enabled && c.Provider == "umeng" && c.AppKey != "" && c.AppMasterSecret != ""
	return c
}

type mobileRemotePushSender interface {
	Send(ctx context.Context, clientID string, payload mobileRemoteAttentionPayload) error
}

type mobileRemotePushTarget struct {
	DeviceID string
	ClientID string
}

func NewMobileRemotePushSender(config MobileRemotePushConfig) mobileRemotePushSender {
	config = config.Normalize()
	if !config.Enabled {
		return nil
	}
	return &umengRemotePushSender{
		config:     config,
		httpClient: &http.Client{Timeout: 8 * time.Second},
	}
}

func LoadMobileRemotePushConfig() MobileRemotePushConfig {
	values := loadLocalPropertiesFromDefaultPaths()
	env := os.Environ()
	for _, raw := range env {
		key, value, ok := strings.Cut(raw, "=")
		if ok {
			values[key] = value
		}
	}
	enabled := boolConfig(values, false, "UMENG_PUSH_ENABLED", "WILLDEEP_MOBILE_PUSH_ENABLED")
	secret := firstConfigValue(values,
		"UMENG_APP_MASTER_SECRET",
		"UMENG_MASTER_SECRET",
		"UMENG_MESSAGE_SECRET",
	)
	return MobileRemotePushConfig{
		Enabled:         enabled,
		Provider:        "umeng",
		AppKey:          firstConfigValue(values, "UMENG_APPKEY", "UMENG_APP_KEY"),
		AppMasterSecret: secret,
		Endpoint:        firstConfigValue(values, "UMENG_PUSH_ENDPOINT"),
		ProductionMode:  boolConfig(values, false, "UMENG_PRODUCTION_MODE"),
	}
}

func loadLocalPropertiesFromDefaultPaths() map[string]string {
	values := map[string]string{}
	home, _ := os.UserHomeDir()
	cwd, _ := os.Getwd()
	paths := []string{}
	if cwd != "" {
		paths = append(paths, filepath.Join(cwd, "local.properties"))
	}
	if home != "" {
		paths = append(paths,
			filepath.Join(home, "local.properties"),
			filepath.Join(home, "Sites", "Xedit", "local.properties"),
		)
	}
	for _, path := range paths {
		mergeLocalProperties(values, path)
	}
	return values
}

func mergeLocalProperties(values map[string]string, path string) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		key, value, ok := strings.Cut(trimmed, "=")
		if !ok {
			continue
		}
		values[strings.TrimSpace(key)] = strings.Trim(strings.TrimSpace(value), `"'`)
	}
}

func firstConfigValue(values map[string]string, keys ...string) string {
	for _, key := range keys {
		if value := strings.TrimSpace(values[key]); value != "" {
			return value
		}
	}
	return ""
}

func boolConfig(values map[string]string, fallback bool, keys ...string) bool {
	for _, key := range keys {
		switch strings.ToLower(strings.TrimSpace(values[key])) {
		case "1", "true", "yes", "on":
			return true
		case "0", "false", "no", "off":
			return false
		}
	}
	return fallback
}

type mobileRemoteAttentionPayload struct {
	TargetType           string `json:"target_type"`
	TargetID             string `json:"target_id"`
	SessionID            string `json:"session_id,omitempty"`
	Title                string `json:"title"`
	Summary              string `json:"summary"`
	ToolName             string `json:"tool_name,omitempty"`
	InputPreview         string `json:"input_preview,omitempty"`
	Path                 string `json:"path,omitempty"`
	Kind                 string `json:"kind,omitempty"`
	RequiresAnswer       bool   `json:"requires_answer,omitempty"`
	RequiresConfirmation bool   `json:"requires_confirmation,omitempty"`
}

func (p mobileRemoteAttentionPayload) DedupeKey() string {
	return p.TargetType + ":" + p.TargetID
}

func mobileRemoteAttentionPayloadFromEnvelope(message MobileEnvelope) (mobileRemoteAttentionPayload, bool) {
	switch message.Type {
	case "tool.pending":
		id := firstPayloadString(message.Payload, "id", "tool_call_id", "approval_id")
		if id == "" {
			return mobileRemoteAttentionPayload{}, false
		}
		toolName := firstPayloadString(message.Payload, "tool_name", "tool")
		inputPreview := firstPayloadString(message.Payload, "input_preview", "preview")
		return mobileRemoteAttentionPayload{
			TargetType:           "tool",
			TargetID:             id,
			SessionID:            firstNonBlank(message.SessionID, firstPayloadString(message.Payload, "session_id")),
			Title:                firstNonBlank(firstPayloadString(message.Payload, "title"), "WillDeep needs approval"),
			Summary:              firstNonBlank(firstPayloadString(message.Payload, "summary", "message", "body"), inputPreview),
			ToolName:             toolName,
			InputPreview:         inputPreview,
			Kind:                 toolName,
			RequiresAnswer:       strings.EqualFold(toolName, "ask_user") || boolPayload(message.Payload, "requires_answer", "requires_input"),
			RequiresConfirmation: boolPayload(message.Payload, "requires_confirmation", "requires_confirm"),
		}, true
	case "patch.upsert":
		id := firstPayloadString(message.Payload, "id", "patch_id")
		if id == "" {
			return mobileRemoteAttentionPayload{}, false
		}
		path := firstPayloadString(message.Payload, "path")
		return mobileRemoteAttentionPayload{
			TargetType:   "patch",
			TargetID:     id,
			SessionID:    firstNonBlank(message.SessionID, firstPayloadString(message.Payload, "session_id")),
			Title:        firstNonBlank(firstPayloadString(message.Payload, "title"), "WillDeep has a patch to review"),
			Summary:      firstPayloadString(message.Payload, "summary", "stats", "message", "body"),
			Path:         path,
			InputPreview: path,
		}, true
	default:
		return mobileRemoteAttentionPayload{}, false
	}
}

func firstPayloadString(payload map[string]any, keys ...string) string {
	for _, key := range keys {
		value, ok := payload[key]
		if !ok || value == nil {
			continue
		}
		switch typed := value.(type) {
		case string:
			if trimmed := strings.TrimSpace(typed); trimmed != "" {
				return trimmed
			}
		case fmt.Stringer:
			if trimmed := strings.TrimSpace(typed.String()); trimmed != "" {
				return trimmed
			}
		}
	}
	return ""
}

func boolPayload(payload map[string]any, keys ...string) bool {
	for _, key := range keys {
		switch value := payload[key].(type) {
		case bool:
			if value {
				return true
			}
		case string:
			switch strings.ToLower(strings.TrimSpace(value)) {
			case "1", "true", "yes", "on":
				return true
			}
		}
	}
	return false
}

func firstNonBlank(values ...string) string {
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

type umengRemotePushSender struct {
	config     MobileRemotePushConfig
	httpClient *http.Client
}

func (s *umengRemotePushSender) Send(ctx context.Context, clientID string, payload mobileRemoteAttentionPayload) error {
	clientID = strings.TrimSpace(clientID)
	if clientID == "" {
		return nil
	}
	custom, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal mobile push payload: %w", err)
	}
	requestBody := map[string]any{
		"appkey":        s.config.AppKey,
		"timestamp":     fmt.Sprintf("%d", time.Now().Unix()),
		"type":          "unicast",
		"device_tokens": clientID,
		"payload": map[string]any{
			"display_type": "message",
			"body": map[string]any{
				"custom": string(custom),
			},
		},
		"production_mode": fmt.Sprintf("%t", s.config.ProductionMode),
		"description":     "WillDeep mobile attention",
	}
	body, err := json.Marshal(requestBody)
	if err != nil {
		return fmt.Errorf("marshal umeng request: %w", err)
	}
	endpoint := strings.TrimSpace(s.config.Endpoint)
	sign := umengSign(http.MethodPost, endpoint, body, s.config.AppMasterSecret)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint+"?sign="+sign, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create umeng request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("send umeng request: %w", err)
	}
	defer resp.Body.Close()
	responseBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("umeng status %d: %s", resp.StatusCode, strings.TrimSpace(string(responseBody)))
	}
	var parsed struct {
		Ret  string `json:"ret"`
		Data any    `json:"data"`
	}
	if err := json.Unmarshal(responseBody, &parsed); err == nil && parsed.Ret != "" && parsed.Ret != "SUCCESS" {
		return fmt.Errorf("umeng response ret=%s", parsed.Ret)
	}
	return nil
}

func umengSign(method string, endpoint string, body []byte, secret string) string {
	sum := md5.Sum([]byte(method + endpoint + string(body) + secret))
	return hex.EncodeToString(sum[:])
}
