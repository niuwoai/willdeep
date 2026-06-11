package agent

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWorkspaceResolveRejectsEscapes(t *testing.T) {
	rootDir := t.TempDir()
	root, err := NewWorkspaceRoot(rootDir)
	if err != nil {
		t.Fatalf("NewWorkspaceRoot: %v", err)
	}
	if _, err := root.Resolve("../secret"); err == nil {
		t.Fatal("expected parent escape to fail")
	}
	if _, err := root.Resolve("/etc/passwd"); err == nil {
		t.Fatal("expected absolute path to fail")
	}
	if resolved, err := root.Resolve("dir/file.txt"); err != nil {
		t.Fatalf("Resolve child: %v", err)
	} else if filepath.Dir(resolved) != filepath.Join(root.Path(), "dir") {
		t.Fatalf("unexpected resolved path: %s", resolved)
	}
}

func TestWorkspaceResolveRejectsSymlinkEscape(t *testing.T) {
	rootDir := t.TempDir()
	outsideDir := t.TempDir()
	if err := os.Symlink(outsideDir, filepath.Join(rootDir, "outside")); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	root, err := NewWorkspaceRoot(rootDir)
	if err != nil {
		t.Fatalf("NewWorkspaceRoot: %v", err)
	}
	if _, err := root.Resolve("outside/file.txt"); err == nil {
		t.Fatal("expected symlink escape to fail")
	}
}
