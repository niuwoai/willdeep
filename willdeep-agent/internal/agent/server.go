package agent

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

type ServerConfigInput struct {
	Host      string
	Port      int
	Workspace string
	Token     string
	TokenFile string
}

type ServerConfig struct {
	Host      string
	Port      int
	Workspace WorkspaceRoot
	Token     string
}

type Server struct {
	config   ServerConfig
	jobs     *JobRegistry
	upgrader websocket.Upgrader
}

type APIResponse struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
	Data  any    `json:"data,omitempty"`
}

const (
	maxFSListEntries          = 400
	maxSearchFileSize         = 512 * 1024
	maxSearchFiles            = 4_000
	maxSearchVisitedPath      = 50_000
	maxProcessStdinBytes      = 1024 * 1024
	jobEventHeartbeatInterval = 15 * time.Second
)

var skippedDirectoryNames = map[string]struct{}{
	".angular":         {},
	".build":           {},
	".cache":           {},
	".cargo":           {},
	".dart_tool":       {},
	".direnv":          {},
	".git":             {},
	".gradle":          {},
	".mypy_cache":      {},
	".next":            {},
	".nuxt":            {},
	".parcel-cache":    {},
	".pnpm-store":      {},
	".pytest_cache":    {},
	".ruff_cache":      {},
	".serverless":      {},
	".stack-work":      {},
	".svelte-kit":      {},
	".swiftpm":         {},
	".terraform":       {},
	".turbo":           {},
	".tox":             {},
	".venv":            {},
	".yarn":            {},
	"__pycache__":      {},
	"_build":           {},
	"bazel-bin":        {},
	"bazel-out":        {},
	"bazel-testlogs":   {},
	"bower_components": {},
	"Carthage":         {},
	"DerivedData":      {},
	"Pods":             {},
	"build":            {},
	"coverage":         {},
	"deps":             {},
	"dist":             {},
	"env":              {},
	"node_modules":     {},
	"out":              {},
	"target":           {},
	"venv":             {},
	"vendor":           {},
}

func NewServerConfig(input ServerConfigInput) (ServerConfig, error) {
	host := strings.TrimSpace(input.Host)
	if host == "" {
		host = "127.0.0.1"
	}
	if host != "127.0.0.1" && host != "localhost" && host != "::1" {
		log.Printf("warning: willdeep-agent is listening on %s; prefer 127.0.0.1 behind an SSH tunnel", host)
	}
	port := input.Port
	if port <= 0 || port > 65535 {
		return ServerConfig{}, fmt.Errorf("invalid port: %d", port)
	}
	root, err := NewWorkspaceRoot(input.Workspace)
	if err != nil {
		return ServerConfig{}, err
	}
	token, err := loadToken(input.Token, input.TokenFile)
	if err != nil {
		return ServerConfig{}, err
	}
	return ServerConfig{Host: host, Port: port, Workspace: root, Token: token}, nil
}

func Serve(ctx context.Context, config ServerConfig) error {
	server := NewServer(config)
	addr := net.JoinHostPort(config.Host, strconv.Itoa(config.Port))
	httpServer := &http.Server{Addr: addr, Handler: server.routes()}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdownCtx)
	}()

	log.Printf("willdeep-agent %s listening on http://%s workspace=%s", Version, addr, config.Workspace.Path())
	err := httpServer.ListenAndServe()
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func NewServer(config ServerConfig) *Server {
	return &Server{
		config: config,
		jobs:   NewJobRegistry(),
		upgrader: websocket.Upgrader{
			CheckOrigin: func(r *http.Request) bool { return true },
		},
	}
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("GET /v1/probe", s.withAuth(s.handleProbe))
	mux.HandleFunc("GET /v1/fs/list", s.withAuth(s.handleFSList))
	mux.HandleFunc("GET /v1/fs/read", s.withAuth(s.handleFSRead))
	mux.HandleFunc("POST /v1/fs/write", s.withAuth(s.handleFSWrite))
	mux.HandleFunc("GET /v1/search", s.withAuth(s.handleSearch))
	mux.HandleFunc("GET /v1/git/status", s.withAuth(s.handleGitStatus))
	mux.HandleFunc("POST /v1/run/start", s.withAuth(s.handleRunStart))
	mux.HandleFunc("GET /v1/run/identity", s.withAuth(s.handleRunIdentity))
	mux.HandleFunc("POST /v1/run/requests/{key}/reconcile", s.withAuth(s.handleRunStartReconcile))
	mux.HandleFunc("GET /v1/run/jobs/{id}", s.withAuth(s.handleJobGet))
	mux.HandleFunc("GET /v1/run/jobs/{id}/output", s.withAuth(s.handleJobOutput))
	mux.HandleFunc("GET /v1/run/jobs/{id}/events", s.withAuth(s.handleJobEvents))
	mux.HandleFunc("DELETE /v1/run/jobs/{id}", s.withAuth(s.handleJobKill))
	mux.HandleFunc("GET /v1/ws", s.withAuth(s.handleWebSocket))
	return mux
}

func (s *Server) withAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.config.Token != "" {
			auth := strings.TrimSpace(r.Header.Get("Authorization"))
			queryToken := r.URL.Query().Get("token")
			if auth != "Bearer "+s.config.Token && queryToken != s.config.Token {
				writeError(w, http.StatusUnauthorized, "unauthorized")
				return
			}
		}
		next(w, r)
	}
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeOK(w, map[string]any{
		"version":   VersionInfo(),
		"workspace": s.config.Workspace.Path(),
	})
}

func (s *Server) handleProbe(w http.ResponseWriter, r *http.Request) {
	report := Probe(r.Context(), s.config.Workspace)
	report.IdempotentJobStart = true
	report.StartRequestRecovery = true
	report.MonotonicRunDeadline = true
	writeOK(w, report)
}

func (s *Server) handleRunIdentity(w http.ResponseWriter, r *http.Request) {
	writeOK(w, map[string]any{"instance_id": s.jobs.instanceID, "elapsed_milliseconds": s.jobs.ElapsedMilliseconds()})
}

func (s *Server) handleFSList(w http.ResponseWriter, r *http.Request) {
	path, err := s.config.Workspace.Resolve(r.URL.Query().Get("path"))
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	items, truncated, err := s.listDirectory(path, true)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeOK(w, map[string]any{"entries": items, "truncated": truncated})
}

func (s *Server) handleFSRead(w http.ResponseWriter, r *http.Request) {
	path, err := s.config.Workspace.Resolve(r.URL.Query().Get("path"))
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeOK(w, map[string]any{
		"path":           s.config.Workspace.Relative(path),
		"content_base64": base64.StdEncoding.EncodeToString(data),
	})
}

func (s *Server) handleFSWrite(w http.ResponseWriter, r *http.Request) {
	var request struct {
		Path          string `json:"path"`
		Content       string `json:"content,omitempty"`
		ContentBase64 string `json:"content_base64,omitempty"`
	}
	if err := decodeJSON(r.Body, &request); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	path, err := s.config.Workspace.Resolve(request.Path)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	var data []byte
	if request.ContentBase64 != "" {
		data, err = base64.StdEncoding.DecodeString(request.ContentBase64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid content_base64")
			return
		}
	} else {
		data = []byte(request.Content)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeOK(w, map[string]any{"path": s.config.Workspace.Relative(path), "bytes": len(data)})
}

func (s *Server) handleSearch(w http.ResponseWriter, r *http.Request) {
	query := strings.TrimSpace(r.URL.Query().Get("query"))
	if query == "" {
		writeError(w, http.StatusBadRequest, "query is required")
		return
	}
	limit := queryInt(r, "limit", 100)
	path, err := s.config.Workspace.Resolve(r.URL.Query().Get("path"))
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	results, err := s.search(r.Context(), path, query, limit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeOK(w, map[string]any{"matches": results})
}

func (s *Server) handleGitStatus(w http.ResponseWriter, r *http.Request) {
	output, err := s.runShortCommand(r.Context(), "git", "status", "--short", "--branch")
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeOK(w, map[string]any{"status": output})
}

func (s *Server) handleRunStart(w http.ResponseWriter, r *http.Request) {
	var request struct {
		RequestID                   string   `json:"request_id,omitempty"`
		ExpectedInstanceID          string   `json:"expected_instance_id,omitempty"`
		Command                     string   `json:"command"`
		Executable                  string   `json:"executable"`
		Arguments                   []string `json:"arguments,omitempty"`
		StdinBase64                 string   `json:"stdin_base64,omitempty"`
		Cwd                         string   `json:"cwd,omitempty"`
		TimeoutSeconds              int      `json:"timeout_seconds,omitempty"`
		DeadlineElapsedMilliseconds *int64   `json:"deadline_elapsed_milliseconds,omitempty"`
	}
	if err := decodeJSON(r.Body, &request); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if request.DeadlineElapsedMilliseconds != nil && (request.RequestID == "" || request.ExpectedInstanceID == "") {
		writeError(w, http.StatusBadRequest, "instance-relative deadlines require request_id and expected_instance_id")
		return
	}
	// Clamp before duration multiplication so a large JSON integer cannot
	// overflow into a negative duration and reset to the default timeout.
	if request.TimeoutSeconds > int(maximumJobDuration/time.Second) {
		request.TimeoutSeconds = int(maximumJobDuration / time.Second)
	}
	if request.TimeoutSeconds < 0 {
		writeError(w, http.StatusBadRequest, "timeout_seconds must not be negative")
		return
	}
	cwd, err := s.config.Workspace.Resolve(request.Cwd)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	stdin, err := decodeProcessStdin(request.StdinBase64)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	spec := ProcessSpec{
		Command:                     request.Command,
		Executable:                  request.Executable,
		Arguments:                   request.Arguments,
		Stdin:                       stdin,
		Cwd:                         cwd,
		Timeout:                     time.Duration(request.TimeoutSeconds) * time.Second,
		DeadlineElapsedMilliseconds: request.DeadlineElapsedMilliseconds,
	}
	if err := ValidateProcessSpec(spec); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	var job *Job
	if request.RequestID != "" || request.ExpectedInstanceID != "" {
		job, err = s.jobs.StartProcessOnce(r.Context(), spec, request.ExpectedInstanceID, request.RequestID)
	} else {
		job, err = s.jobs.StartProcess(r.Context(), spec)
	}
	if err != nil {
		writeError(w, startRequestErrorStatus(err), err.Error())
		return
	}
	writeOK(w, job.Snapshot())
}

func decodeProcessStdin(encoded string) ([]byte, error) {
	if encoded == "" {
		return nil, nil
	}
	if base64.StdEncoding.DecodedLen(len(encoded)) > maxProcessStdinBytes {
		return nil, errors.New("stdin exceeds 1 MiB limit")
	}
	data, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, fmt.Errorf("invalid stdin_base64: %w", err)
	}
	if len(data) > maxProcessStdinBytes {
		return nil, errors.New("stdin exceeds 1 MiB limit")
	}
	return data, nil
}

func (s *Server) handleJobGet(w http.ResponseWriter, r *http.Request) {
	job, ok := s.jobs.Get(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "job not found")
		return
	}
	writeOK(w, job.Snapshot())
}

func (s *Server) handleJobOutput(w http.ResponseWriter, r *http.Request) {
	job, ok := s.jobs.Get(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "job not found")
		return
	}
	writeOK(w, map[string]any{"output": job.Output()})
}

func (s *Server) handleJobEvents(w http.ResponseWriter, r *http.Request) {
	job, ok := s.jobs.Get(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "job not found")
		return
	}
	rawCursor := r.URL.Query().Get("after")
	if rawCursor == "" {
		rawCursor = r.Header.Get("Last-Event-ID")
	}
	var index int64
	if rawCursor != "" {
		var err error
		index, err = strconv.ParseInt(rawCursor, 10, 64)
		if err != nil || index < 0 {
			writeError(w, http.StatusBadRequest, "invalid job event cursor")
			return
		}
	}
	initial := job.eventBatchSince(index)
	if index > initial.Next {
		writeError(w, http.StatusBadRequest, "job event cursor is ahead of this job")
		return
	}
	writeVersionHeaders(w)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Job-Event-Cursor", "1")
	flusher, _ := w.(http.Flusher)
	heartbeat := time.NewTicker(jobEventHeartbeatInterval)
	defer heartbeat.Stop()
	for {
		batch := job.eventBatchSince(index)
		if index < batch.First-1 {
			gap := JobEvent{JobID: job.ID, Sequence: batch.First - 1, Stream: "gap",
				Data: "Earlier job output was evicted from the bounded event buffer.", Time: time.Now().UTC()}
			if err := writeJobEvent(w, gap); err != nil {
				return
			}
		}
		index = batch.Next
		for _, event := range batch.Events {
			if err := writeJobEvent(w, event); err != nil {
				return
			}
		}
		if flusher != nil {
			flusher.Flush()
		}
		if batch.Finished {
			return
		}
		select {
		case <-r.Context().Done():
			return
		case <-batch.Changed:
		case <-heartbeat.C:
			if _, err := io.WriteString(w, ": heartbeat\n\n"); err != nil {
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
	}
}

func writeJobEvent(w io.Writer, event JobEvent) error {
	if _, err := fmt.Fprintf(w, "id: %d\n", event.Sequence); err != nil {
		return err
	}
	return writeSSE(w, "run."+event.Stream, event)
}

func (s *Server) handleJobKill(w http.ResponseWriter, r *http.Request) {
	if err := s.jobs.Kill(r.PathValue("id")); err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	writeOK(w, map[string]any{"killed": true})
}

func (s *Server) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close()
	for {
		var message WSMessage
		if err := conn.ReadJSON(&message); err != nil {
			return
		}
		response := s.handleWSMessage(r.Context(), message)
		if err := conn.WriteJSON(response); err != nil {
			return
		}
	}
}

func (s *Server) search(ctx context.Context, path string, query string, limit int) ([]string, error) {
	if _, err := exec.LookPath("rg"); err == nil {
		args := []string{"--line-number", "--no-heading", "--color", "never"}
		for name := range skippedDirectoryNames {
			args = append(args, "--glob", "!"+name+"/**")
		}
		args = append(args, "--glob", "!bazel-*/**")
		args = append(args, "-F", query, path)
		cmd := exec.CommandContext(ctx, "rg", args...)
		output, err := cmd.CombinedOutput()
		if err != nil && len(output) == 0 {
			return []string{}, nil
		}
		return limitLines(string(output), limit), nil
	}
	var results []string
	visited := 0
	scanned := 0
	err := filepath.WalkDir(path, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		visited++
		if visited > maxSearchVisitedPath || len(results) >= limit {
			return filepath.SkipAll
		}
		if entry.IsDir() {
			if shouldSkipDirectoryName(entry.Name()) {
				return filepath.SkipDir
			}
			return nil
		}
		scanned++
		if scanned > maxSearchFiles {
			return filepath.SkipAll
		}
		info, err := entry.Info()
		if err != nil || info.Size() > maxSearchFileSize {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil
		}
		for lineNo, line := range strings.Split(string(data), "\n") {
			if strings.Contains(line, query) {
				results = append(results, fmt.Sprintf("%s:%d:%s", s.config.Workspace.Relative(path), lineNo+1, line))
				if len(results) >= limit {
					return nil
				}
			}
		}
		return nil
	})
	return results, err
}

func (s *Server) listDirectory(path string, includeDetails bool) ([]map[string]any, bool, error) {
	dir, err := os.Open(path)
	if err != nil {
		return nil, false, err
	}
	defer dir.Close()

	filtered := make([]os.DirEntry, 0, maxFSListEntries)
	truncated := false
	for {
		entries, err := dir.ReadDir(128)
		if err != nil && !errors.Is(err, io.EOF) {
			return nil, false, err
		}
		for _, entry := range entries {
			if entry.IsDir() && shouldSkipDirectoryName(entry.Name()) {
				continue
			}
			if len(filtered) >= maxFSListEntries {
				truncated = true
				break
			}
			filtered = append(filtered, entry)
		}
		if truncated || errors.Is(err, io.EOF) {
			break
		}
	}
	sort.Slice(filtered, func(i, j int) bool {
		return strings.ToLower(filtered[i].Name()) < strings.ToLower(filtered[j].Name())
	})

	items := make([]map[string]any, 0, len(filtered))
	for _, entry := range filtered {
		item := map[string]any{
			"name":   entry.Name(),
			"is_dir": entry.IsDir(),
		}
		if includeDetails {
			info, err := entry.Info()
			if err != nil {
				continue
			}
			fullPath := filepath.Join(path, entry.Name())
			item["path"] = s.config.Workspace.Relative(fullPath)
			item["size"] = info.Size()
			item["mode"] = info.Mode().String()
			item["modified"] = info.ModTime().UTC()
		}
		items = append(items, item)
	}
	return items, truncated, nil
}

func shouldSkipDirectoryName(name string) bool {
	_, ok := skippedDirectoryNames[name]
	return ok || strings.HasPrefix(name, "bazel-")
}

func (s *Server) runShortCommand(ctx context.Context, name string, args ...string) (string, error) {
	cmdCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(cmdCtx, name, args...)
	cmd.Dir = s.config.Workspace.Path()
	output, err := cmd.CombinedOutput()
	if err != nil {
		return string(output), fmt.Errorf("%s failed: %w\n%s", name, err, string(output))
	}
	return string(output), nil
}

func decodeJSON(reader io.Reader, value any) error {
	decoder := json.NewDecoder(io.LimitReader(reader, 2*1024*1024))
	decoder.DisallowUnknownFields()
	return decoder.Decode(value)
}

func writeOK(w http.ResponseWriter, data any) {
	writeAPI(w, http.StatusOK, APIResponse{OK: true, Data: data})
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeAPI(w, status, APIResponse{OK: false, Error: message})
}

func writeAPI(w http.ResponseWriter, status int, response APIResponse) {
	w.Header().Set("Content-Type", "application/json")
	writeVersionHeaders(w)
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(response)
}

func writeVersionHeaders(w http.ResponseWriter) {
	w.Header().Set("X-App-Version", Version)
	w.Header().Set("X-Server-Version", Version)
}

func writeSSE(w io.Writer, event string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, data)
	return err
}

func queryInt(r *http.Request, key string, fallback int) int {
	value, err := strconv.Atoi(r.URL.Query().Get(key))
	if err != nil || value <= 0 {
		return fallback
	}
	if value > 1000 {
		return 1000
	}
	return value
}

func limitLines(output string, limit int) []string {
	lines := strings.Split(strings.TrimRight(output, "\n"), "\n")
	if len(lines) > limit {
		lines = lines[:limit]
	}
	if len(lines) == 1 && lines[0] == "" {
		return []string{}
	}
	return lines
}

func loadToken(token string, tokenFile string) (string, error) {
	if token == "" {
		token = os.Getenv("WILLDEEP_AGENT_TOKEN")
	}
	if token == "" && tokenFile != "" {
		data, err := os.ReadFile(tokenFile)
		if err != nil {
			return "", fmt.Errorf("read token file: %w", err)
		}
		token = string(data)
	}
	return strings.TrimSpace(token), nil
}
