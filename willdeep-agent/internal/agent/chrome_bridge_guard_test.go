package agent

import (
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestChromeBridgeGuard(t *testing.T) {
	const token = "0123456789abcdef"
	bridge := &ChromeNativeBridge{token: token}
	handler := bridge.guard(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}), &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 8797})

	tests := []struct {
		name        string
		method      string
		host        string
		token       string
		origin      string
		contentType string
		want        int
	}{
		{name: "app request", method: http.MethodPost, host: "127.0.0.1:8797", token: token, contentType: "application/json", want: http.StatusOK},
		{name: "app request with charset", method: http.MethodPost, host: "127.0.0.1:8797", token: token, contentType: "application/json; charset=utf-8", want: http.StatusOK},
		{name: "localhost host", method: http.MethodGet, host: "localhost:8797", token: token, want: http.StatusOK},
		{name: "missing token", method: http.MethodPost, host: "127.0.0.1:8797", contentType: "application/json", want: http.StatusUnauthorized},
		{name: "wrong token", method: http.MethodPost, host: "127.0.0.1:8797", token: "nope", contentType: "application/json", want: http.StatusUnauthorized},
		{name: "browser origin", method: http.MethodPost, host: "127.0.0.1:8797", token: token, origin: "https://evil.example", contentType: "application/json", want: http.StatusForbidden},
		{name: "dns rebinding host", method: http.MethodPost, host: "attacker.example:8797", token: token, contentType: "application/json", want: http.StatusForbidden},
		{name: "simple text post", method: http.MethodPost, host: "127.0.0.1:8797", token: token, contentType: "text/plain", want: http.StatusUnsupportedMediaType},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(tt.method, "http://"+tt.host+"/chrome/request", strings.NewReader("{}"))
			req.Host = tt.host
			if tt.token != "" {
				req.Header.Set(ChromeBridgeTokenHeader, tt.token)
			}
			if tt.origin != "" {
				req.Header.Set("Origin", tt.origin)
			}
			if tt.contentType != "" {
				req.Header.Set("Content-Type", tt.contentType)
			}
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, req)
			if rec.Code != tt.want {
				t.Fatalf("status = %d, want %d (body %s)", rec.Code, tt.want, rec.Body.String())
			}
		})
	}
}

func TestChromeBridgeGuardRejectsEverythingWithoutToken(t *testing.T) {
	bridge := &ChromeNativeBridge{}
	handler := bridge.guard(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}), &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 8797})
	req := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:8797/chrome/health", nil)
	req.Host = "127.0.0.1:8797"
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
}

func TestWriteChromeBridgeTokenIsPrivateAndAtomic(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", chromeBridgeTokenFileName)
	token, err := newChromeBridgeToken()
	if err != nil {
		t.Fatal(err)
	}
	if len(token) != chromeBridgeTokenBytes*2 {
		t.Fatalf("token length = %d", len(token))
	}
	if err := writeChromeBridgeToken(path, token); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("token file mode = %o, want 600", perm)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != token {
		t.Fatalf("token file content mismatch")
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("temp files left behind: %v", entries)
	}
}

func TestChromeBridgeTokenPathHonorsOverride(t *testing.T) {
	t.Setenv(chromeBridgeTokenFileEnvVar, "/tmp/custom-token")
	if got := chromeBridgeTokenPath(); got != "/tmp/custom-token" {
		t.Fatalf("path = %q", got)
	}
	t.Setenv(chromeBridgeTokenFileEnvVar, "")
	if got := chromeBridgeTokenPath(); !strings.HasSuffix(got, filepath.Join("WillDeep", "ChromeNativeHost", chromeBridgeTokenFileName)) {
		t.Fatalf("default path = %q", got)
	}
}
