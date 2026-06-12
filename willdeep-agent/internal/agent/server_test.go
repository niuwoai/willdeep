package agent

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
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
