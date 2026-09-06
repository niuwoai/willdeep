package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

func TestRunDeadlineHelper(t *testing.T) {
	if len(os.Args) > 1 && os.Args[len(os.Args)-1] == "willdeep-deadline-helper" {
		time.Sleep(30 * time.Second)
	}
}

func TestRunDeadlineSurvivesRequestCancellationAndDoesNotExtendOnReplay(t *testing.T) {
	r := NewJobRegistry()
	spec, _ := startRequestFixture(t)
	spec.Arguments = []string{"-test.run=^TestRunDeadlineHelper$", "--", "willdeep-deadline-helper"}
	spec.Timeout = 30 * time.Second
	deadline := r.ElapsedMilliseconds() + 1500
	spec.DeadlineElapsedMilliseconds = &deadline
	ctx, cancel := context.WithCancel(context.Background())
	started := time.Now()
	job, err := r.StartProcessOnce(ctx, spec, r.instanceID, testStartKey)
	if err != nil {
		t.Fatal(err)
	}
	cancel() // Models an HTTP client disappearing, not an authorized Stop.
	replay, err := r.StartProcessOnce(context.Background(), spec, r.instanceID, testStartKey)
	if err != nil || replay != job {
		t.Fatalf("replay: %v", err)
	}
	select {
	case <-job.WaitChannel():
	case <-time.After(8 * time.Second):
		t.Fatal("server did not enforce its deadline")
	}
	if elapsed := time.Since(started); elapsed < time.Second || elapsed > 6*time.Second {
		t.Fatalf("deadline elapsed %s", elapsed)
	}
	// `Job` still embeds its buffer's mutex, so the snapshot must never be
	// copied into a variadic argument: `go vet` fails the whole package for
	// it, and a `vet && test` chain then never reaches the tests at all.
	// Report the fields instead.
	if snapshot := job.Snapshot(); !snapshot.TimedOut || snapshot.ExitCode == nil || snapshot.Error != context.DeadlineExceeded.Error() {
		t.Fatalf(
			"missing authoritative timeout: timedOut=%t exitCode=%v error=%q",
			snapshot.TimedOut,
			snapshot.ExitCode,
			snapshot.Error,
		)
	}
	events, _ := job.EventsSince(0)
	if len(events) == 0 || !events[len(events)-1].TimedOut {
		t.Fatal("exit stream lost timeout reason")
	}
	// Expiration must not hide a completed receipt or allow a new process.
	replay, err = r.StartProcessOnce(context.Background(), spec, r.instanceID, testStartKey)
	if err != nil || replay != job {
		t.Fatalf("completed replay: %v", err)
	}
	later := deadline + 10000
	spec.DeadlineElapsedMilliseconds = &later
	if _, err := r.StartProcessOnce(context.Background(), spec, r.instanceID, testStartKey); !errors.Is(err, ErrStartKeyConflict) {
		t.Fatalf("replay extended deadline: %v", err)
	}
}

func TestExpiredRunDeadlineSealsFailureBeforeAnyProcess(t *testing.T) {
	r := NewJobRegistry()
	r.startedAt = r.startedAt.Add(-time.Second)
	spec, marker := startRequestFixture(t)
	deadline := int64(1)
	spec.DeadlineElapsedMilliseconds = &deadline
	for i := 0; i < 2; i++ {
		if _, err := r.StartProcessOnce(context.Background(), spec, r.instanceID, testStartKey); !errors.Is(err, ErrRunDeadlineExpired) {
			t.Fatalf("expired request: %v", err)
		}
	}
	resolution, err := r.ReconcileStart(r.instanceID, testStartKey)
	if err != nil || resolution.State != "not_started" {
		t.Fatalf("resolution: %+v %v", resolution, err)
	}
	if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) || len(r.jobs) != 0 {
		t.Fatal("expired request executed")
	}
	later := r.ElapsedMilliseconds() + 5000
	spec.DeadlineElapsedMilliseconds = &later
	if _, err := r.StartProcessOnce(context.Background(), spec, r.instanceID, testStartKey); !errors.Is(err, ErrStartKeyConflict) {
		t.Fatalf("expired key was reused: %v", err)
	}
}

func TestRunDeadlineHTTPValidationAndIdentity(t *testing.T) {
	root, err := NewWorkspaceRoot(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	s := NewServer(ServerConfig{Workspace: root, Token: "fixture-auth"})
	s.jobs.startedAt = s.jobs.startedAt.Add(-time.Second)
	identityRequest := httptest.NewRequest(http.MethodGet, "/v1/run/identity", nil)
	identityRequest.Header.Set("Authorization", "Bearer fixture-auth")
	identity := httptest.NewRecorder()
	s.routes().ServeHTTP(identity, identityRequest)
	var decoded struct {
		Data struct {
			InstanceID string `json:"instance_id"`
			Elapsed    int64  `json:"elapsed_milliseconds"`
		} `json:"data"`
	}
	if err := json.Unmarshal(identity.Body.Bytes(), &decoded); err != nil || decoded.Data.Elapsed < 1000 || decoded.Data.InstanceID != s.jobs.instanceID {
		t.Fatalf("identity does not bind the monotonic clock: %v", err)
	}
	for _, tc := range []struct {
		name     string
		deadline int64
		instance bool
		timeout  int
		want     int
	}{
		{"expired", 1, true, 60, http.StatusGone},
		{"missing-instance", 5000, false, 60, http.StatusBadRequest},
		{"overflow", 1<<63 - 1, true, 60, http.StatusBadRequest},
		{"negative", -1, true, 60, http.StatusBadRequest},
		{"negative-timeout", 5000, true, -1, http.StatusBadRequest},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := map[string]any{"command": "true", "timeout_seconds": tc.timeout, "deadline_elapsed_milliseconds": tc.deadline}
			if tc.instance {
				body["request_id"] = testStartKey + tc.name
				body["expected_instance_id"] = s.jobs.instanceID
			}
			data, err := json.Marshal(body)
			if err != nil {
				t.Fatal(err)
			}
			request := httptest.NewRequest(http.MethodPost, "/v1/run/start", bytes.NewReader(data))
			request.Header.Set("Authorization", "Bearer fixture-auth")
			response := httptest.NewRecorder()
			s.routes().ServeHTTP(response, request)
			if response.Code != tc.want {
				t.Fatalf("status %d, want %d", response.Code, tc.want)
			}
		})
	}
	if len(s.jobs.jobs) != 0 {
		t.Fatal("invalid request launched a process")
	}
}
