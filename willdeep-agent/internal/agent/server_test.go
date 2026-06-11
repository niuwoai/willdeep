package agent

import (
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
