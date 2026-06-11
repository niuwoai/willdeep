package agent

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

var ErrPathOutsideWorkspace = errors.New("path escapes workspace")

type WorkspaceRoot struct {
	path string
}

func NewWorkspaceRoot(path string) (WorkspaceRoot, error) {
	if strings.TrimSpace(path) == "" {
		return WorkspaceRoot{}, errors.New("workspace path is required")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return WorkspaceRoot{}, fmt.Errorf("resolve workspace path: %w", err)
	}
	evaluated, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return WorkspaceRoot{}, fmt.Errorf("resolve workspace symlinks: %w", err)
	}
	info, err := os.Stat(evaluated)
	if err != nil {
		return WorkspaceRoot{}, fmt.Errorf("stat workspace: %w", err)
	}
	if !info.IsDir() {
		return WorkspaceRoot{}, fmt.Errorf("workspace is not a directory: %s", evaluated)
	}
	return WorkspaceRoot{path: evaluated}, nil
}

func (r WorkspaceRoot) Path() string {
	return r.path
}

func (r WorkspaceRoot) Resolve(userPath string) (string, error) {
	if r.path == "" {
		return "", errors.New("workspace root is not configured")
	}
	clean := strings.TrimSpace(userPath)
	if clean == "" || clean == "." {
		return r.path, nil
	}
	if filepath.IsAbs(clean) {
		return "", fmt.Errorf("%w: absolute paths are not allowed", ErrPathOutsideWorkspace)
	}
	candidate := filepath.Join(r.path, clean)
	abs, err := filepath.Abs(candidate)
	if err != nil {
		return "", fmt.Errorf("resolve path: %w", err)
	}
	parentForSymlinkCheck := abs
	if _, err := os.Lstat(abs); err != nil && os.IsNotExist(err) {
		parentForSymlinkCheck = existingAncestor(filepath.Dir(abs))
	}
	evaluatedParent, err := filepath.EvalSymlinks(parentForSymlinkCheck)
	if err != nil {
		return "", fmt.Errorf("resolve path symlinks: %w", err)
	}
	if !r.contains(evaluatedParent) {
		return "", ErrPathOutsideWorkspace
	}
	if target, err := filepath.EvalSymlinks(abs); err == nil && !r.contains(target) {
		return "", ErrPathOutsideWorkspace
	}
	if !r.contains(abs) {
		return "", ErrPathOutsideWorkspace
	}
	return abs, nil
}

func (r WorkspaceRoot) Relative(path string) string {
	rel, err := filepath.Rel(r.path, path)
	if err != nil {
		return path
	}
	if rel == "." {
		return "."
	}
	return rel
}

func (r WorkspaceRoot) contains(path string) bool {
	rel, err := filepath.Rel(r.path, path)
	if err != nil {
		return false
	}
	return rel == "." || (!strings.HasPrefix(rel, ".."+string(filepath.Separator)) && rel != "..")
}

func existingAncestor(path string) string {
	current := path
	for {
		if _, err := os.Lstat(current); err == nil {
			return current
		}
		parent := filepath.Dir(current)
		if parent == current {
			return current
		}
		current = parent
	}
}
