package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const testStartKey = "01234567-89ab-cdef-0123-456789abcdef"

// A real isolated child writes one marker per process. No shell expansion or
// user process is involved in the at-most-once execution assertion.
func TestIdempotentStartHelper(t *testing.T) {
	if len(os.Args) < 3 || os.Args[len(os.Args)-2] != "willdeep-idempotent-helper" {
		return
	}
	f, err := os.OpenFile(os.Args[len(os.Args)-1], os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString("executed\n"); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
}

func startRequestFixture(t *testing.T) (ProcessSpec, string) {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	marker := filepath.Join(root, "executions.txt")
	return ProcessSpec{Executable: executable,
		Arguments: []string{"-test.run=^TestIdempotentStartHelper$", "--", "willdeep-idempotent-helper", marker},
		Cwd:       root, Timeout: 10 * time.Second}, marker
}

func requireSingleStart(t *testing.T, job *Job, marker string) {
	t.Helper()
	select {
	case <-job.WaitChannel():
	case <-time.After(15 * time.Second):
		t.Fatal("fixture child did not exit")
	}
	if snapshot := job.Snapshot(); snapshot.ExitCode == nil || *snapshot.ExitCode != 0 {
		t.Fatalf("fixture process failed: %s", job.Output())
	}
	data, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "executed\n" {
		t.Fatalf("execution marker = %q", data)
	}
}

func TestStartRequestConcurrentAndCompletedReplayStartsOneProcess(t *testing.T) {
	r := NewJobRegistry()
	spec, marker := startRequestFixture(t)
	const callers = 12
	jobs := make(chan *Job, callers)
	errorsSeen := make(chan error, callers)
	var workers sync.WaitGroup
	for i := 0; i < callers; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			job, err := r.StartProcessOnce(context.Background(), spec, r.instanceID, testStartKey)
			jobs <- job
			errorsSeen <- err
		}()
	}
	workers.Wait()
	close(jobs)
	close(errorsSeen)
	for err := range errorsSeen {
		if err != nil {
			t.Fatal(err)
		}
	}
	var first *Job
	for job := range jobs {
		if first == nil {
			first = job
		}
		if job != first {
			t.Fatal("replay created a different job")
		}
	}
	if first.ID != "job-"+r.instanceID+"-request-"+testStartKey {
		t.Fatal("unstable keyed job identity")
	}
	requireSingleStart(t, first, marker)
	replayed, err := r.StartProcessOnce(context.Background(), spec, r.instanceID, testStartKey)
	if err != nil || replayed != first {
		t.Fatalf("completed replay: %v", err)
	}
	requireSingleStart(t, replayed, marker)
}

func TestStartRequestRejectsChangedPayloadAndRestartedInstance(t *testing.T) {
	r := NewJobRegistry()
	spec, marker := startRequestFixture(t)
	job, err := r.StartProcessOnce(context.Background(), spec, r.instanceID, testStartKey)
	if err != nil {
		t.Fatal(err)
	}
	defer requireSingleStart(t, job, marker)
	changed := spec
	changed.Stdin = []byte("different input")
	if _, err := r.StartProcessOnce(context.Background(), changed, r.instanceID, testStartKey); !errors.Is(err, ErrStartKeyConflict) {
		t.Fatalf("changed request: %v", err)
	}
	restarted := NewJobRegistry()
	if _, err := restarted.StartProcessOnce(context.Background(), spec, r.instanceID, testStartKey); !errors.Is(err, ErrStartInstanceChanged) {
		t.Fatalf("restarted daemon: %v", err)
	}
	if len(restarted.jobs) != 0 {
		t.Fatal("old instance request started a new process")
	}
}

func TestStartRequestRetainsLaunchFailureAndRejectsInvalidKey(t *testing.T) {
	r := NewJobRegistry()
	spec := ProcessSpec{Executable: filepath.Join(t.TempDir(), "missing"), Cwd: t.TempDir()}
	for _, key := range []string{"", "short", strings.Repeat("a", 129), "0123456789abcdef/../../"} {
		if _, err := r.StartProcessOnce(context.Background(), spec, r.instanceID, key); !errors.Is(err, ErrStartKeyInvalid) {
			t.Fatalf("invalid key accepted: %v", err)
		}
	}
	_, first := r.StartProcessOnce(context.Background(), spec, r.instanceID, testStartKey)
	_, second := r.StartProcessOnce(context.Background(), spec, r.instanceID, testStartKey)
	if first == nil || first != second || len(r.requests) != 1 || len(r.jobs) != 0 {
		t.Fatal("launch failure was not retained without a job")
	}
}

func TestStartRequestCapacityNeverEvictsPriorReceipts(t *testing.T) {
	r := NewJobRegistry()
	r.requests = make(map[string]*jobStartRequest)
	for i := 0; i < maximumStartRequestKeys; i++ {
		r.requests[string(rune(i))] = &jobStartRequest{}
	}
	if _, err := r.StartProcessOnce(context.Background(), ProcessSpec{Command: "true"}, r.instanceID, testStartKey); !errors.Is(err, ErrStartKeyCapacity) {
		t.Fatalf("capacity: %v", err)
	}
	if len(r.requests) != maximumStartRequestKeys || len(r.jobs) != 0 {
		t.Fatal("capacity evicted receipts or launched work")
	}
}

func TestRunStartResponseLossReplayAndInstancePrecondition(t *testing.T) {
	spec, marker := startRequestFixture(t)
	root, err := NewWorkspaceRoot(spec.Cwd)
	if err != nil {
		t.Fatal(err)
	}
	s := NewServer(ServerConfig{Workspace: root, Token: "fixture-auth"})
	identity := httptest.NewRecorder()
	unauthorized := httptest.NewRequest(http.MethodGet, "/v1/run/identity", nil)
	s.routes().ServeHTTP(identity, unauthorized)
	if identity.Code != http.StatusUnauthorized {
		t.Fatalf("identity bypasses authentication: %d", identity.Code)
	}
	body := map[string]any{"executable": spec.Executable, "arguments": spec.Arguments, "cwd": ".", "timeout_seconds": 10,
		"request_id": testStartKey, "expected_instance_id": s.jobs.instanceID}
	post := func(body map[string]any) *httptest.ResponseRecorder {
		data, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		r := httptest.NewRequest(http.MethodPost, "/v1/run/start", bytes.NewReader(data))
		r.Header.Set("Authorization", "Bearer fixture-auth")
		w := httptest.NewRecorder()
		s.routes().ServeHTTP(w, r)
		return w
	}
	if lost := post(body); lost.Code != http.StatusOK {
		t.Fatalf("first response: %d", lost.Code)
	}
	// Deliberately discard the first response. A repeat must recover its ID.
	replay := post(body)
	if replay.Code != http.StatusOK {
		t.Fatalf("replay status: %d", replay.Code)
	}
	var envelope struct {
		Data Job `json:"data"`
	}
	if err := json.Unmarshal(replay.Body.Bytes(), &envelope); err != nil {
		t.Fatal(err)
	}
	job, ok := s.jobs.Get(envelope.Data.ID)
	if !ok {
		t.Fatal("replayed job missing")
	}
	requireSingleStart(t, job, marker)
	body["expected_instance_id"] = "obsolete-instance"
	if failed := post(body); failed.Code != http.StatusPreconditionFailed {
		t.Fatalf("instance guard: %d", failed.Code)
	}
	body["expected_instance_id"] = s.jobs.instanceID
	body["timeout_seconds"] = 11
	if failed := post(body); failed.Code != http.StatusConflict {
		t.Fatalf("payload guard: %d", failed.Code)
	}
	if len(s.jobs.jobs) != 1 {
		t.Fatal("replay created additional jobs")
	}
}
