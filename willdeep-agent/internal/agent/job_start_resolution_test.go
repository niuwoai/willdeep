package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
)

func TestStartReconciliationSealsLateLaunch(t *testing.T) {
	r := NewJobRegistry()
	spec, marker := startRequestFixture(t)
	for i := 0; i < 2; i++ {
		receipt, err := r.ReconcileStart(r.instanceID, testStartKey)
		if err != nil || receipt.State != "not_started" || receipt.Job != nil {
			t.Fatalf("resolution: %+v %v", receipt, err)
		}
	}
	if _, err := r.StartProcessOnce(context.Background(), spec, r.instanceID, testStartKey); !errors.Is(err, ErrStartKeySealed) {
		t.Fatalf("late launch accepted: %v", err)
	}
	if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) || len(r.jobs) != 0 {
		t.Fatal("sealed key executed")
	}
}

func TestStartReconciliationAtCapacityStillProvesNoLaunch(t *testing.T) {
	r := NewJobRegistry()
	r.requests = make(map[string]*jobStartRequest)
	for i := 0; i < maximumStartRequestKeys; i++ {
		r.requests[string(rune(i))] = &jobStartRequest{}
	}
	resolution, err := r.ReconcileStart(r.instanceID, testStartKey)
	if err != nil || resolution.State != "not_started" {
		t.Fatalf("capacity resolution: %+v %v", resolution, err)
	}
	if _, err := r.StartProcessOnce(context.Background(), ProcessSpec{Command: "true"}, r.instanceID, testStartKey); !errors.Is(err, ErrStartKeyCapacity) {
		t.Fatalf("capacity proof did not prevent late launch: %v", err)
	}
	if len(r.requests) != maximumStartRequestKeys || len(r.jobs) != 0 {
		t.Fatal("capacity reconciliation mutated or launched")
	}
}

func TestStartReconciliationConcurrentLaunchHasOneAuthoritativeOutcome(t *testing.T) {
	for i := 0; i < 12; i++ {
		r := NewJobRegistry()
		spec, marker := startRequestFixture(t)
		gate := make(chan struct{})
		var job *Job
		var launchErr error
		var resolution JobStartResolution
		var resolutionErr error
		var done sync.WaitGroup
		done.Add(2)
		go func() {
			defer done.Done()
			<-gate
			job, launchErr = r.StartProcessOnce(context.Background(), spec, r.instanceID, testStartKey)
		}()
		go func() {
			defer done.Done()
			<-gate
			resolution, resolutionErr = r.ReconcileStart(r.instanceID, testStartKey)
		}()
		close(gate)
		done.Wait()
		if resolutionErr != nil {
			t.Fatal(resolutionErr)
		}
		final, err := r.ReconcileStart(r.instanceID, testStartKey)
		if err != nil {
			t.Fatal(err)
		}
		if job != nil {
			if launchErr != nil || resolution.State == "not_started" || final.State != "started" || final.Job.ID != job.ID {
				t.Fatal("launch and reconciliation disagree")
			}
			requireSingleStart(t, job, marker)
		} else if !errors.Is(launchErr, ErrStartKeySealed) || final.State != "not_started" {
			t.Fatalf("unproven no-launch outcome: %v %+v", launchErr, final)
		}
	}
}

func TestStartReconciliationPendingFailureAndIsolation(t *testing.T) {
	r := NewJobRegistry()
	done := make(chan struct{})
	r.requests = map[string]*jobStartRequest{testStartKey: {done: done}}
	pending, err := r.ReconcileStart(r.instanceID, testStartKey)
	if err != nil || pending.State != "pending" {
		t.Fatalf("pending: %+v %v", pending, err)
	}
	r.requests[testStartKey].err = errors.New("isolated launch failure")
	close(done)
	failed, err := r.ReconcileStart(r.instanceID, testStartKey)
	if err != nil || failed.State != "not_started" {
		t.Fatalf("failure: %+v %v", failed, err)
	}
	if _, err := r.ReconcileStart("old-instance", testStartKey); !errors.Is(err, ErrStartInstanceChanged) {
		t.Fatalf("instance isolation: %v", err)
	}
	if _, err := r.ReconcileStart(r.instanceID, "bad-key"); !errors.Is(err, ErrStartKeyInvalid) {
		t.Fatal("invalid key accepted")
	}
	if len(r.requests) != 1 {
		t.Fatal("rejected reconciliation mutated registry")
	}
}

func TestStartReconciliationHTTPAuthenticationAndLatePost(t *testing.T) {
	spec, marker := startRequestFixture(t)
	root, err := NewWorkspaceRoot(spec.Cwd)
	if err != nil {
		t.Fatal(err)
	}
	s := NewServer(ServerConfig{Workspace: root, Token: "fixture-auth"})
	invoke := func(path string, body map[string]any, authenticated bool) *httptest.ResponseRecorder {
		data, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(data))
		if authenticated {
			req.Header.Set("Authorization", "Bearer fixture-auth")
		}
		response := httptest.NewRecorder()
		s.routes().ServeHTTP(response, req)
		return response
	}
	path := "/v1/run/requests/" + testStartKey + "/reconcile"
	body := map[string]any{"expected_instance_id": s.jobs.instanceID}
	if response := invoke(path, body, false); response.Code != http.StatusUnauthorized || len(s.jobs.requests) != 0 {
		t.Fatal("unauthenticated reconciliation mutated state")
	}
	response := invoke(path, body, true)
	var envelope struct {
		Data JobStartResolution `json:"data"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &envelope); err != nil {
		t.Fatal(err)
	}
	if response.Code != http.StatusOK || envelope.Data.State != "not_started" || envelope.Data.InstanceID != s.jobs.instanceID {
		t.Fatal("missing authoritative no-launch receipt")
	}
	body["request_id"] = testStartKey
	body["executable"] = spec.Executable
	body["arguments"] = spec.Arguments
	body["cwd"] = "."
	if response := invoke("/v1/run/start", body, true); response.Code != http.StatusConflict {
		t.Fatal("late HTTP POST was not rejected")
	}
	if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("late HTTP POST executed")
	}
}
