package agent

import (
	"context"
	"encoding/base64"
	"os"
	"path/filepath"
	"time"
)

type WSMessage struct {
	ID      string         `json:"id,omitempty"`
	Event   string         `json:"event"`
	Payload map[string]any `json:"payload,omitempty"`
}

type WSResponse struct {
	ID      string `json:"id,omitempty"`
	Event   string `json:"event"`
	OK      bool   `json:"ok"`
	Error   string `json:"error,omitempty"`
	Payload any    `json:"payload,omitempty"`
}

func (s *Server) handleWSMessage(ctx context.Context, message WSMessage) WSResponse {
	switch message.Event {
	case "hello":
		return wsOK(message, map[string]any{"version": VersionInfo()})
	case "probe":
		return wsOK(message, Probe(ctx, s.config.Workspace))
	case "fs.read":
		path, err := s.config.Workspace.Resolve(wsString(message.Payload, "path"))
		if err != nil {
			return wsError(message, err)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return wsError(message, err)
		}
		return wsOK(message, map[string]any{"path": s.config.Workspace.Relative(path), "content_base64": base64.StdEncoding.EncodeToString(data)})
	case "fs.list":
		path, err := s.config.Workspace.Resolve(wsString(message.Payload, "path"))
		if err != nil {
			return wsError(message, err)
		}
		items, truncated, err := s.listDirectory(path, false)
		if err != nil {
			return wsError(message, err)
		}
		return wsOK(message, map[string]any{"entries": items, "truncated": truncated})
	case "fs.write":
		path, err := s.config.Workspace.Resolve(wsString(message.Payload, "path"))
		if err != nil {
			return wsError(message, err)
		}
		content := wsString(message.Payload, "content")
		if encoded := wsString(message.Payload, "content_base64"); encoded != "" {
			data, err := base64.StdEncoding.DecodeString(encoded)
			if err != nil {
				return wsError(message, err)
			}
			content = string(data)
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return wsError(message, err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			return wsError(message, err)
		}
		return wsOK(message, map[string]any{"path": s.config.Workspace.Relative(path)})
	case "search":
		path, err := s.config.Workspace.Resolve(wsString(message.Payload, "path"))
		if err != nil {
			return wsError(message, err)
		}
		matches, err := s.search(ctx, path, wsString(message.Payload, "query"), wsInt(message.Payload, "limit", 100))
		if err != nil {
			return wsError(message, err)
		}
		return wsOK(message, map[string]any{"matches": matches})
	case "git.status":
		status, err := s.runShortCommand(ctx, "git", "status", "--short", "--branch")
		if err != nil {
			return wsError(message, err)
		}
		return wsOK(message, map[string]any{"status": status})
	case "run.start":
		cwd, err := s.config.Workspace.Resolve(wsString(message.Payload, "cwd"))
		if err != nil {
			return wsError(message, err)
		}
		job, err := s.jobs.Start(ctx, wsString(message.Payload, "command"), cwd, time.Duration(wsInt(message.Payload, "timeout_seconds", 0))*time.Second)
		if err != nil {
			return wsError(message, err)
		}
		return wsOK(message, job.Snapshot())
	case "run.kill":
		if err := s.jobs.Kill(wsString(message.Payload, "job_id")); err != nil {
			return wsError(message, err)
		}
		return wsOK(message, map[string]any{"killed": true})
	default:
		return WSResponse{ID: message.ID, Event: message.Event, OK: false, Error: "unknown event"}
	}
}

func wsOK(message WSMessage, payload any) WSResponse {
	return WSResponse{ID: message.ID, Event: message.Event, OK: true, Payload: payload}
}

func wsError(message WSMessage, err error) WSResponse {
	return WSResponse{ID: message.ID, Event: message.Event, OK: false, Error: err.Error()}
}

func wsString(payload map[string]any, key string) string {
	if payload == nil {
		return ""
	}
	value, _ := payload[key].(string)
	return value
}

func wsInt(payload map[string]any, key string, fallback int) int {
	if payload == nil {
		return fallback
	}
	switch value := payload[key].(type) {
	case float64:
		return int(value)
	case int:
		return value
	default:
		return fallback
	}
}
