package agent

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"
)

type ProbeReport struct {
	IdempotentJobStart   bool              `json:"idempotent_job_start,omitempty"`
	StartRequestRecovery bool              `json:"start_request_recovery,omitempty"`
	MonotonicRunDeadline bool              `json:"monotonic_run_deadline,omitempty"`
	Version              VersionReport     `json:"version"`
	Platform             string            `json:"platform"`
	Arch                 string            `json:"arch"`
	Workspace            string            `json:"workspace"`
	Now                  time.Time         `json:"now"`
	Tools                map[string]string `json:"tools"`
	Registries           map[string]string `json:"registries"`
	Proxies              map[string]string `json:"proxies"`
	GitHubCLIAuthLine    string            `json:"github_cli_auth_line,omitempty"`
}

func Probe(ctx context.Context, root WorkspaceRoot) ProbeReport {
	report := ProbeReport{
		Version:    VersionInfo(),
		Platform:   runtime.GOOS,
		Arch:       runtime.GOARCH,
		Workspace:  root.Path(),
		Now:        time.Now().UTC(),
		Tools:      map[string]string{},
		Registries: map[string]string{},
		Proxies:    map[string]string{},
	}

	report.Tools["git"] = firstCommand(ctx, "git", "--version")
	report.Tools["rg"] = firstCommand(ctx, "rg", "--version")
	report.Tools["bash"] = commandPath("bash")
	report.Tools["sh"] = commandPath("sh")
	report.Tools["node"] = firstCommand(ctx, "node", "--version")
	report.Tools["npm"] = firstCommand(ctx, "npm", "--version")
	report.Tools["yarn"] = firstCommand(ctx, "yarn", "--version")
	report.Tools["python"] = firstAvailable(ctx, [][]string{{"python3", "--version"}, {"python", "--version"}})
	report.Tools["pip"] = firstAvailable(ctx, [][]string{{"pip3", "--version"}, {"pip", "--version"}})
	report.Tools["ruby"] = firstCommand(ctx, "ruby", "--version")
	report.Tools["go"] = firstCommand(ctx, "go", "version")
	report.Tools["java"] = firstCommand(ctx, "java", "-version")
	report.Tools["gh"] = firstCommand(ctx, "gh", "--version")
	report.Tools["claude"] = commandPath("claude")
	report.Tools["codex"] = commandPath("codex")
	report.Tools["cursor-agent"] = firstAvailablePath("cursor-agent", "cursor")
	report.Tools["cline"] = commandPath("cline")

	report.Registries["npm"] = configValue(ctx, "npm", "config", "get", "registry")
	report.Registries["yarn"] = firstAvailable(ctx, [][]string{{"yarn", "config", "get", "npmRegistryServer"}, {"yarn", "config", "get", "registry"}})

	report.Proxies["npm_proxy"] = redactProxy(configValue(ctx, "npm", "config", "get", "proxy"))
	report.Proxies["npm_https_proxy"] = redactProxy(configValue(ctx, "npm", "config", "get", "https-proxy"))
	report.Proxies["pip_proxy"] = redactProxy(firstAvailable(ctx, [][]string{{"pip3", "config", "get", "global.proxy"}, {"pip", "config", "get", "global.proxy"}}))
	report.Proxies["http_proxy"] = redactProxy(envFirst("http_proxy", "HTTP_PROXY"))
	report.Proxies["https_proxy"] = redactProxy(envFirst("https_proxy", "HTTPS_PROXY"))
	report.Proxies["no_proxy"] = envFirst("no_proxy", "NO_PROXY")
	report.GitHubCLIAuthLine = firstCommand(ctx, "gh", "auth", "status")

	removeEmpty(report.Tools)
	removeEmpty(report.Registries)
	removeEmpty(report.Proxies)
	return report
}

func FormatProbe(report ProbeReport) string {
	var b strings.Builder
	fmt.Fprintf(&b, "willdeep-agent %s\n", report.Version.Version)
	fmt.Fprintf(&b, "platform: %s/%s\n", report.Platform, report.Arch)
	fmt.Fprintf(&b, "workspace: %s\n", report.Workspace)
	writeMap(&b, "tools", report.Tools)
	writeMap(&b, "registries", report.Registries)
	writeMap(&b, "proxies", report.Proxies)
	if report.GitHubCLIAuthLine != "" {
		fmt.Fprintf(&b, "github: %s\n", report.GitHubCLIAuthLine)
	}
	return strings.TrimRight(b.String(), "\n")
}

func writeMap(b *strings.Builder, title string, values map[string]string) {
	if len(values) == 0 {
		return
	}
	fmt.Fprintf(b, "%s:\n", title)
	for key, value := range values {
		fmt.Fprintf(b, "  %s: %s\n", key, value)
	}
}

func firstCommand(ctx context.Context, name string, args ...string) string {
	if _, err := exec.LookPath(name); err != nil {
		return ""
	}
	cmdCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(cmdCtx, name, args...)
	output, err := cmd.CombinedOutput()
	if err != nil && len(output) == 0 {
		return ""
	}
	return firstLine(string(output))
}

func firstAvailable(ctx context.Context, commands [][]string) string {
	for _, parts := range commands {
		if len(parts) == 0 {
			continue
		}
		if value := firstCommand(ctx, parts[0], parts[1:]...); value != "" {
			return value
		}
	}
	return ""
}

func commandPath(name string) string {
	path, err := exec.LookPath(name)
	if err != nil {
		return ""
	}
	return path
}

func firstAvailablePath(names ...string) string {
	for _, name := range names {
		if path := commandPath(name); path != "" {
			return path
		}
	}
	return ""
}

func configValue(ctx context.Context, name string, args ...string) string {
	value := firstCommand(ctx, name, args...)
	if value == "undefined" || value == "null" {
		return ""
	}
	return value
}

func envFirst(names ...string) string {
	for _, name := range names {
		if value := strings.TrimSpace(os.Getenv(name)); value != "" {
			return value
		}
	}
	return ""
}

func firstLine(value string) string {
	for _, line := range strings.Split(value, "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			return line
		}
	}
	return ""
}

func removeEmpty(values map[string]string) {
	for key, value := range values {
		if strings.TrimSpace(value) == "" {
			delete(values, key)
		}
	}
}

func redactProxy(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	parts := strings.SplitN(value, "://", 2)
	if len(parts) != 2 {
		return value
	}
	at := strings.LastIndex(parts[1], "@")
	if at < 0 {
		return value
	}
	return parts[0] + "://redacted:redacted@" + parts[1][at+1:]
}
