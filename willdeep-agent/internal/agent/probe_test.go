package agent

import "testing"

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
