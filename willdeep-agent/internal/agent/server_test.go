package agent

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestNewServerConfigLoadsTokenFile(t *testing.T) {
	root := t.TempDir()
	tokenFile := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(tokenFile, []byte(" secret-token \n"), 0o600); err != nil {
		t.Fatalf("write token file: %v", err)
	}
	cfg, err := NewServerConfig(ServerConfigInput{
		Host:      "127.0.0.1",
		Port:      8765,
		Workspace: root,
		TokenFile: tokenFile,
	})
	if err != nil {
		t.Fatalf("NewServerConfig: %v", err)
	}
	if cfg.Token != "secret-token" {
		t.Fatalf("token = %q", cfg.Token)
	}
}

func TestListDirectorySkipsDependenciesAndCapsEntries(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "node_modules"), 0o755); err != nil {
		t.Fatalf("mkdir node_modules: %v", err)
	}
	if err := os.Mkdir(filepath.Join(root, "target"), 0o755); err != nil {
		t.Fatalf("mkdir target: %v", err)
	}
	if err := os.Mkdir(filepath.Join(root, "bazel-sample"), 0o755); err != nil {
		t.Fatalf("mkdir bazel-sample: %v", err)
	}
	for i := 0; i < maxFSListEntries+5; i++ {
		name := filepath.Join(root, fmt.Sprintf("file-%03d.txt", i))
		if err := os.WriteFile(name, []byte("x"), 0o644); err != nil {
			t.Fatalf("write fixture: %v", err)
		}
	}
	workspace, err := NewWorkspaceRoot(root)
	if err != nil {
		t.Fatalf("workspace: %v", err)
	}
	server := NewServer(ServerConfig{Workspace: workspace})

	items, truncated, err := server.listDirectory(root, false)
	if err != nil {
		t.Fatalf("listDirectory: %v", err)
	}
	if !truncated {
		t.Fatalf("expected truncated directory listing")
	}
	if len(items) != maxFSListEntries {
		t.Fatalf("len(items) = %d, want %d", len(items), maxFSListEntries)
	}
	for _, item := range items {
		switch item["name"] {
		case "node_modules", "target", "bazel-sample":
			t.Fatalf("dependency directory leaked into listing")
		}
	}
}

func TestRunStartAcceptsExecutableArgumentsAndStdin(t *testing.T) {
	root := t.TempDir()
	workspace, err := NewWorkspaceRoot(root)
	if err != nil {
		t.Fatalf("workspace: %v", err)
	}
	server := NewServer(ServerConfig{Workspace: workspace})
	stdin := "literal ' $(not-expanded)\nsecond line\n"
	requestBody := map[string]any{
		"executable":      "/bin/cat",
		"arguments":       []string{},
		"stdin_base64":    base64.StdEncoding.EncodeToString([]byte(stdin)),
		"cwd":             ".",
		"timeout_seconds": 5,
	}
	var encoded bytes.Buffer
	if err := json.NewEncoder(&encoded).Encode(requestBody); err != nil {
		t.Fatalf("encode request: %v", err)
	}
	request := httptest.NewRequest(http.MethodPost, "/v1/run/start", &encoded)
	recorder := httptest.NewRecorder()

	server.handleRunStart(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	var response struct {
		OK   bool `json:"ok"`
		Data Job  `json:"data"`
	}
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	job, ok := server.jobs.Get(response.Data.ID)
	if !ok {
		t.Fatalf("job %q not registered", response.Data.ID)
	}
	select {
	case <-job.WaitChannel():
	case <-time.After(5 * time.Second):
		t.Fatal("job did not finish")
	}
	if output := job.Output(); output != stdin {
		t.Fatalf("output = %q, want stdin %q", output, stdin)
	}
}

func TestRunStartRejectsAmbiguousLaunchMode(t *testing.T) {
	root := t.TempDir()
	workspace, err := NewWorkspaceRoot(root)
	if err != nil {
		t.Fatalf("workspace: %v", err)
	}
	server := NewServer(ServerConfig{Workspace: workspace})
	body := bytes.NewBufferString(
		`{"command":"true","executable":"/usr/bin/true","cwd":"."}`,
	)
	request := httptest.NewRequest(http.MethodPost, "/v1/run/start", body)
	recorder := httptest.NewRecorder()

	server.handleRunStart(recorder, request)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
}
