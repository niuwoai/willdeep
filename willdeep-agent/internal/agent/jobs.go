package agent

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

const maxJobBufferBytes = 64 * 1024
const jobOutputDrainTimeout = 2 * time.Second

type JobRegistry struct {
	mu         sync.RWMutex
	seq        int64
	jobs       map[string]*Job
	instanceID string
	startedAt  time.Time
	requestMu  sync.Mutex
	requests   map[string]*jobStartRequest
}

type ProcessSpec struct {
	Command                     string
	Executable                  string
	Arguments                   []string
	Stdin                       []byte
	Cwd                         string
	Timeout                     time.Duration
	DeadlineElapsedMilliseconds *int64
}

type Job struct {
	ID         string    `json:"id"`
	Command    string    `json:"command"`
	Cwd        string    `json:"cwd"`
	PID        int       `json:"pid,omitempty"`
	StartedAt  time.Time `json:"started_at"`
	FinishedAt time.Time `json:"finished_at,omitempty"`
	ExitCode   *int      `json:"exit_code,omitempty"`
	Error      string    `json:"error,omitempty"`
	TimedOut   bool      `json:"timed_out,omitempty"`

	cancel context.CancelFunc
	buffer jobBuffer
}

type JobEvent struct {
	Sequence int64     `json:"sequence"`
	JobID    string    `json:"job_id"`
	Stream   string    `json:"stream"`
	Data     string    `json:"data"`
	ExitCode *int      `json:"exit_code,omitempty"`
	Error    string    `json:"error,omitempty"`
	TimedOut bool      `json:"timed_out,omitempty"`
	Time     time.Time `json:"time"`
}

type jobBuffer struct {
	mu        sync.Mutex
	events    []JobEvent
	bytes     int
	wait      chan struct{}
	baseIndex int64
	changed   chan struct{}
}

func NewJobRegistry() *JobRegistry {
	var identity [16]byte
	if _, err := rand.Read(identity[:]); err != nil {
		panic(fmt.Errorf("initialize job registry identity: %w", err))
	}
	return &JobRegistry{jobs: map[string]*Job{}, instanceID: hex.EncodeToString(identity[:]), startedAt: time.Now()}
}

func (r *JobRegistry) Start(ctx context.Context, command string, cwd string, timeout time.Duration) (*Job, error) {
	return r.StartProcess(ctx, ProcessSpec{
		Command: command,
		Cwd:     cwd,
		Timeout: timeout,
	})
}

func (r *JobRegistry) StartProcess(ctx context.Context, spec ProcessSpec) (*Job, error) {
	var err error
	spec, err = normalizedProcessSpec(spec)
	if err != nil {
		return nil, err
	}
	r.mu.Lock()
	r.seq++
	id := fmt.Sprintf("job-%s-%d", r.instanceID, r.seq)
	r.mu.Unlock()
	return r.startProcess(ctx, spec, id)
}

func normalizedProcessSpec(spec ProcessSpec) (ProcessSpec, error) {
	if err := ValidateProcessSpec(spec); err != nil {
		return spec, err
	}
	if spec.Timeout <= 0 {
		spec.Timeout = 30 * time.Minute
	}
	if spec.DeadlineElapsedMilliseconds != nil {
		deadline := *spec.DeadlineElapsedMilliseconds
		spec.DeadlineElapsedMilliseconds = &deadline
	}
	if spec.Timeout > maximumJobDuration {
		spec.Timeout = maximumJobDuration
	}
	return spec, nil
}

func (r *JobRegistry) startProcess(ctx context.Context, spec ProcessSpec, id string) (*Job, error) {
	deadline, err := r.executionDeadline(spec)
	if err != nil {
		return nil, err
	}
	jobCtx, cancel := context.WithDeadline(context.WithoutCancel(ctx), deadline)
	displayCommand := spec.Command
	if spec.Executable != "" {
		displayCommand = spec.Executable
	}
	job := &Job{
		ID:        id,
		Command:   displayCommand,
		Cwd:       spec.Cwd,
		StartedAt: time.Now().UTC(),
		cancel:    cancel,
		buffer:    jobBuffer{wait: make(chan struct{})},
	}
	var cmd *exec.Cmd
	if spec.Executable != "" {
		cmd = exec.CommandContext(jobCtx, spec.Executable, spec.Arguments...)
		cmd.Stdin = bytes.NewReader(spec.Stdin)
	} else {
		cmd = exec.CommandContext(jobCtx, "/bin/sh", "-lc", spec.Command)
	}
	cmd.Dir = spec.Cwd
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// Let os/exec own its copy goroutines. Wait must drain their output
	// before publishing the final event; StdoutPipe + concurrent Wait can
	// close the pipe before the last lines have reached the event buffer.
	stdout := &jobStreamWriter{job: job, stream: "stdout"}
	stderr := &jobStreamWriter{job: job, stream: "stderr"}
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	cmd.WaitDelay = jobOutputDrainTimeout
	if err := cmd.Start(); err != nil {
		cancel()
		if spec.DeadlineElapsedMilliseconds != nil && errors.Is(err, context.DeadlineExceeded) {
			return nil, ErrRunDeadlineExpired
		}
		return nil, err
	}
	job.PID = cmd.Process.Pid
	r.mu.Lock()
	r.jobs[id] = job
	r.mu.Unlock()

	go func() {
		err := cmd.Wait()
		stdout.flush()
		stderr.flush()
		if jobCtx.Err() == context.DeadlineExceeded {
			err = jobCtx.Err()
		}
		code := 0
		if err != nil {
			code = 1
			var exitErr *exec.ExitError
			if errors.As(err, &exitErr) {
				code = exitErr.ExitCode()
			}
		}
		job.finish(code, err)
		cancel()
	}()

	return job, nil
}

func ValidateProcessSpec(spec ProcessSpec) error {
	if spec.DeadlineElapsedMilliseconds != nil &&
		(*spec.DeadlineElapsedMilliseconds <= 0 || *spec.DeadlineElapsedMilliseconds > maximumDeadlineMilliseconds) {
		return ErrRunDeadlineInvalid
	}
	hasCommand := spec.Command != ""
	hasExecutable := spec.Executable != ""
	if hasCommand == hasExecutable {
		return errors.New("exactly one of command or executable is required")
	}
	if hasCommand && len(spec.Arguments) > 0 {
		return errors.New("arguments require executable")
	}
	return nil
}

func (r *JobRegistry) Get(id string) (*Job, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	job, ok := r.jobs[id]
	return job, ok
}

func (r *JobRegistry) Kill(id string) error {
	job, ok := r.Get(id)
	if !ok {
		return errors.New("job not found")
	}
	job.cancel()
	if job.PID > 0 {
		return syscall.Kill(-job.PID, syscall.SIGTERM)
	}
	return nil
}

func (j *Job) Snapshot() Job {
	j.buffer.mu.Lock()
	defer j.buffer.mu.Unlock()
	return Job{
		ID:         j.ID,
		Command:    j.Command,
		Cwd:        j.Cwd,
		PID:        j.PID,
		StartedAt:  j.StartedAt,
		FinishedAt: j.FinishedAt,
		ExitCode:   j.ExitCode,
		Error:      j.Error,
		TimedOut:   j.TimedOut,
	}
}

type jobEventBatch struct {
	Events   []JobEvent
	Next     int64
	First    int64
	Changed  <-chan struct{}
	Finished bool
}

func (j *Job) EventsSince(index int64) ([]JobEvent, int64) {
	batch := j.eventBatchSince(index)
	return batch.Events, batch.Next
}

func (j *Job) eventBatchSince(index int64) jobEventBatch {
	j.buffer.mu.Lock()
	defer j.buffer.mu.Unlock()
	if j.buffer.changed == nil {
		j.buffer.changed = make(chan struct{})
	}
	next := j.buffer.baseIndex + int64(len(j.buffer.events))
	if index < j.buffer.baseIndex {
		index = j.buffer.baseIndex
	}
	if index > next {
		index = next
	}
	events := append([]JobEvent(nil), j.buffer.events[int(index-j.buffer.baseIndex):]...)
	return jobEventBatch{Events: events, Next: next, First: j.buffer.baseIndex + 1,
		Changed: j.buffer.changed, Finished: j.ExitCode != nil}
}

func (j *Job) WaitChannel() <-chan struct{} {
	j.buffer.mu.Lock()
	defer j.buffer.mu.Unlock()
	return j.buffer.wait
}

func (j *Job) finish(code int, err error) {
	j.buffer.mu.Lock()
	defer j.buffer.mu.Unlock()
	j.FinishedAt = time.Now().UTC()
	j.ExitCode = &code
	j.TimedOut = errors.Is(err, context.DeadlineExceeded)
	if err != nil {
		j.Error = err.Error()
	}
	j.buffer.appendLocked(JobEvent{
		JobID:    j.ID,
		Stream:   "exit",
		ExitCode: &code,
		Error:    j.Error,
		TimedOut: j.TimedOut,
		Time:     j.FinishedAt,
	})
	close(j.buffer.wait)
}

func (j *Job) appendEvent(event JobEvent) {
	j.buffer.mu.Lock()
	defer j.buffer.mu.Unlock()
	j.buffer.appendLocked(event)
}

func (b *jobBuffer) appendLocked(event JobEvent) {
	event.Sequence = b.baseIndex + int64(len(b.events)) + 1
	b.events = append(b.events, event)
	b.bytes += len(event.Data)
	for b.bytes > maxJobBufferBytes && len(b.events) > 0 {
		b.bytes -= len(b.events[0].Data)
		b.events[0] = JobEvent{}
		b.events = b.events[1:]
		b.baseIndex++
	}
	if b.changed != nil {
		close(b.changed)
	}
	b.changed = nil
}

func (j *Job) Output() string {
	events, _ := j.EventsSince(0)
	var b bytes.Buffer
	for _, event := range events {
		if event.Stream == "stdout" || event.Stream == "stderr" {
			b.WriteString(event.Data)
		}
	}
	return b.String()
}
