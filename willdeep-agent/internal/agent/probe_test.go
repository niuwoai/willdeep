package agent

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRedactProxy(t *testing.T) {
	got := redactProxy("http://alice:secret@proxy.example.com:8080")
	want := "http://redacted:redacted@proxy.example.com:8080"
	if got != want {
		t.Fatalf("redactProxy() = %q, want %q", got, want)
	}
	plain := "http://proxy.example.com:8080"
	if redactProxy(plain) != plain {
		t.Fatalf("proxy without credentials should not change")
	}
}

func TestFirstAvailablePathUsesFirstInstalledCommand(t *testing.T) {
	binDir := t.TempDir()
	cursorPath := filepath.Join(binDir, "cursor")
	if err := os.WriteFile(cursorPath, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatalf("write fake cursor executable: %v", err)
	}
	t.Setenv("PATH", binDir)

	got := firstAvailablePath("cursor-agent", "cursor")
	if got != cursorPath {
		t.Fatalf("firstAvailablePath() = %q, want %q", got, cursorPath)
	}
}
