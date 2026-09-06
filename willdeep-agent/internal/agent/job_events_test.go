package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func eventFixture() *Job {
	return &Job{ID: "job-fixture", buffer: jobBuffer{wait: make(chan struct{})}}
}

func TestJobEventCursorSurvivesBufferEviction(t *testing.T) {
	job := eventFixture()
	for i := 0; i < 3; i++ {
		job.appendEvent(JobEvent{JobID: job.ID, Stream: "stdout", Data: "first"})
	}
	_, cursor := job.EventsSince(0)
	for i := 0; i < 4; i++ {
		job.appendEvent(JobEvent{JobID: job.ID, Stream: "stdout", Data: strings.Repeat("x", maxJobBufferBytes/2)})
	}
	events, next := job.EventsSince(cursor)
	if next != 7 || len(events) != 2 || events[0].Sequence != 6 || events[1].Sequence != 7 {
		t.Fatalf("cursor=%d next=%d sequences=%v", cursor, next, eventSequences(events))
	}
	job.appendEvent(JobEvent{JobID: job.ID, Stream: "stderr", Data: "last"})
	events, next = job.EventsSince(next)
	if len(events) != 1 || next != 8 || events[0].Data != "last" || events[0].Sequence != 8 {
		t.Fatalf("later event was lost after pruning: next=%d events=%v", next, eventSequences(events))
	}
}

func TestJobEventBatchSignalsAppendAndFinish(t *testing.T) {
	job := eventFixture()
	first := job.eventBatchSince(0)
	job.appendEvent(JobEvent{JobID: job.ID, Stream: "stdout", Data: "ready"})
	select {
	case <-first.Changed:
	default:
		t.Fatal("append did not signal its observer")
	}
	second := job.eventBatchSince(first.Next)
	if second.Next != 1 || second.Finished {
		t.Fatal("invalid running snapshot")
	}
	select {
	case <-second.Changed:
		t.Fatal("new observer was already signalled")
	default:
	}
	job.finish(0, nil)
	select {
	case <-second.Changed:
	default:
		t.Fatal("finish did not signal its observer")
	}
	last := job.eventBatchSince(second.Next)
	if !last.Finished || len(last.Events) != 1 || last.Events[0].Stream != "exit" || last.Next != 2 {
		t.Fatalf("invalid terminal batch: %+v", last)
	}
}

func TestJobIDsDoNotAliasAcrossRegistryRestarts(t *testing.T) {
	first, second := NewJobRegistry(), NewJobRegistry()
	var jobs []*Job
	for _, registry := range []*JobRegistry{first, second} {
		job, err := registry.StartProcess(context.Background(), ProcessSpec{
			Executable: "/usr/bin/true", Cwd: t.TempDir(), Timeout: 5 * time.Second})
		if err != nil {
			t.Fatal(err)
		}
		<-job.WaitChannel()
		jobs = append(jobs, job)
	}
	if jobs[0].ID == jobs[1].ID {
		t.Fatal("new registry reused an old job identity")
	}
	if _, found := second.Get(jobs[0].ID); found {
		t.Fatal("old job resolved to a different process")
	}
}

func TestJobFailedLaunchDoesNotPublishAnAliveJob(t *testing.T) {
	registry := NewJobRegistry()
	_, err := registry.StartProcess(context.Background(), ProcessSpec{
		Executable: "/nonexistent/willdeep-fixture", Cwd: t.TempDir(), Timeout: time.Second})
	if err == nil || len(registry.jobs) != 0 {
		t.Fatalf("failed launch left a phantom job: err=%v jobs=%d", err, len(registry.jobs))
	}
}

func TestJobExitFollowsAllCapturedOutput(t *testing.T) {
	registry := NewJobRegistry()
	job, err := registry.StartProcess(context.Background(), ProcessSpec{Executable: "/bin/sh",
		Arguments: []string{"-c", "i=0; while [ $i -lt 400 ]; do printf 'out-%s\\n' \"$i\"; printf 'err-%s\\n' \"$i\" >&2; i=$((i+1)); done; printf final-tail"},
		Cwd:       t.TempDir(), Timeout: 5 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	<-job.WaitChannel()
	events, next := job.EventsSince(0)
	if len(events) != 802 || next != 802 || events[len(events)-1].Stream != "exit" {
		t.Fatalf("exit was not ordered after all output: count=%d next=%d", len(events), next)
	}
	output := job.Output()
	if !strings.Contains(output, "out-399\n") || !strings.Contains(output, "err-399\n") || !strings.Contains(output, "final-tail\n") {
		t.Fatal("final output was dropped")
	}
}

func TestJobStreamWriterRejectsOversizedLinesExplicitly(t *testing.T) {
	writer := &jobStreamWriter{job: eventFixture(), stream: "stdout"}
	_, err := writer.Write([]byte(strings.Repeat("x", maxJobOutputLineBytes+1)))
	if !errors.Is(err, errJobOutputLineTooLong) {
		t.Fatalf("error=%v", err)
	}
	writer.flush()
	if len(writer.pending) != 0 {
		t.Fatal("oversized line was retained")
	}
}

func TestJobEventsResumeFromQueryOrHeader(t *testing.T) {
	for _, useHeader := range []bool{false, true} {
		t.Run(fmt.Sprint(useHeader), func(t *testing.T) {
			job := eventFixture()
			for i := 0; i < 3; i++ {
				job.appendEvent(JobEvent{JobID: job.ID, Stream: "stdout", Data: "line"})
			}
			job.finish(0, nil)
			s := &Server{jobs: NewJobRegistry()}
			s.jobs.jobs[job.ID] = job
			r := httptest.NewRequest("GET", "/events?after=2", nil)
			r.SetPathValue("id", job.ID)
			if useHeader {
				r = httptest.NewRequest("GET", "/events", nil)
				r.SetPathValue("id", job.ID)
				r.Header.Set("Last-Event-ID", "2")
			}
			w := httptest.NewRecorder()
			s.handleJobEvents(w, r)
			events := decodeJobSSE(t, w.Body.String())
			if w.Code != 200 || fmt.Sprint(eventSequences(events)) != "[3 4]" {
				t.Fatalf("code=%d sequences=%v", w.Code, eventSequences(events))
			}
			if w.Header().Get("X-Job-Event-Cursor") != "1" || w.Header().Get("X-Server-Version") != Version {
				t.Fatal("missing protocol/version headers")
			}
			if !strings.Contains(w.Body.String(), "id: 3\n") {
				t.Fatal("missing SSE event id")
			}
		})
	}
}

func TestJobEventsExposePrunedRange(t *testing.T) {
	job := eventFixture()
	for i := 0; i < 4; i++ {
		job.appendEvent(JobEvent{JobID: job.ID, Stream: "stdout", Data: strings.Repeat("x", maxJobBufferBytes/2)})
	}
	job.finish(0, nil)
	s := &Server{jobs: NewJobRegistry()}
	s.jobs.jobs[job.ID] = job
	r := httptest.NewRequest("GET", "/events?after=0", nil)
	r.SetPathValue("id", job.ID)
	w := httptest.NewRecorder()
	s.handleJobEvents(w, r)
	events := decodeJobSSE(t, w.Body.String())
	if fmt.Sprint(eventSequences(events)) != "[2 3 4 5]" || events[0].Stream != "gap" {
		t.Fatalf("missing explicit gap: %v", eventSequences(events))
	}
}

func TestJobEventsRejectInvalidAndFutureCursors(t *testing.T) {
	for _, value := range []string{"-1", "invalid", "9223372036854775808", "100"} {
		t.Run(value, func(t *testing.T) {
			job := eventFixture()
			job.finish(0, nil)
			s := &Server{jobs: NewJobRegistry()}
			s.jobs.jobs[job.ID] = job
			r := httptest.NewRequest("GET", "/events?after="+value, nil)
			r.SetPathValue("id", job.ID)
			w := httptest.NewRecorder()
			s.handleJobEvents(w, r)
			if w.Code != http.StatusBadRequest {
				t.Fatalf("code=%d", w.Code)
			}
		})
	}
}

type firstFlushRecorder struct {
	*httptest.ResponseRecorder
	ready chan struct{}
	once  sync.Once
}

func (w *firstFlushRecorder) Flush() {
	w.ResponseRecorder.Flush()
	w.once.Do(func() { close(w.ready) })
}

func TestJobEventsWakeOnOutputAndContextCancellation(t *testing.T) {
	for _, cancelOnly := range []bool{false, true} {
		t.Run(fmt.Sprint(cancelOnly), func(t *testing.T) {
			job := eventFixture()
			s := &Server{jobs: NewJobRegistry()}
			s.jobs.jobs[job.ID] = job
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			r := httptest.NewRequest("GET", "/events", nil).WithContext(ctx)
			r.SetPathValue("id", job.ID)
			w := &firstFlushRecorder{ResponseRecorder: httptest.NewRecorder(), ready: make(chan struct{})}
			done := make(chan struct{})
			go func() { defer close(done); s.handleJobEvents(w, r) }()
			select {
			case <-w.ready:
			case <-ctx.Done():
				t.Fatal("stream did not open")
			}
			if cancelOnly {
				cancel()
			} else {
				job.appendEvent(JobEvent{JobID: job.ID, Stream: "stdout", Data: "live"})
				job.finish(0, nil)
			}
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Fatal("stream did not finish")
			}
			if !cancelOnly && len(decodeJobSSE(t, w.Body.String())) != 2 {
				t.Fatal("lost live output or exit")
			}
		})
	}
}

func decodeJobSSE(t *testing.T, body string) []JobEvent {
	t.Helper()
	var events []JobEvent
	for _, line := range strings.Split(body, "\n") {
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		var event JobEvent
		if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &event); err != nil {
			t.Fatal(err)
		}
		events = append(events, event)
	}
	return events
}

func eventSequences(events []JobEvent) []int64 {
	result := make([]int64, len(events))
	for i, event := range events {
		result[i] = event.Sequence
	}
	return result
}
