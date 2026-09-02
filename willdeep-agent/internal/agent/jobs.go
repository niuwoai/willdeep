package agent

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

const maxJobBufferBytes = 64 * 1024

type JobRegistry struct {
	mu   sync.RWMutex
	seq  int64
	jobs map[string]*Job
}

type ProcessSpec struct {
	Command    string
	Executable string
	Arguments  []string
	Stdin      []byte
	Cwd        string
	Timeout    time.Duration
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

	cancel context.CancelFunc
	buffer jobBuffer
}

type JobEvent struct {
	JobID    string    `json:"job_id"`
	Stream   string    `json:"stream"`
	Data     string    `json:"data"`
	ExitCode *int      `json:"exit_code,omitempty"`
	Error    string    `json:"error,omitempty"`
	Time     time.Time `json:"time"`
}

type jobBuffer struct {
	mu     sync.Mutex
	events []JobEvent
	bytes  int
	wait   chan struct{}
}

func NewJobRegistry() *JobRegistry {
	return &JobRegistry{jobs: map[string]*Job{}}
}

func (r *JobRegistry) Start(ctx context.Context, command string, cwd string, timeout time.Duration) (*Job, error) {
	return r.StartProcess(ctx, ProcessSpec{
		Command: command,
		Cwd:     cwd,
		Timeout: timeout,
	})
}

func (r *JobRegistry) StartProcess(ctx context.Context, spec ProcessSpec) (*Job, error) {
	if err := ValidateProcessSpec(spec); err != nil {
		return nil, err
	}
	if spec.Timeout <= 0 {
		spec.Timeout = 30 * time.Minute
	}
	if spec.Timeout > 6*time.Hour {
		spec.Timeout = 6 * time.Hour
	}
	jobCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), spec.Timeout)

	r.mu.Lock()
	r.seq++
	id := fmt.Sprintf("job-%d", r.seq)
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
	r.jobs[id] = job
	r.mu.Unlock()

	var cmd *exec.Cmd
	if spec.Executable != "" {
		cmd = exec.CommandContext(jobCtx, spec.Executable, spec.Arguments...)
		cmd.Stdin = bytes.NewReader(spec.Stdin)
	} else {
		cmd = exec.CommandContext(jobCtx, "/bin/sh", "-lc", spec.Command)
	}
	cmd.Dir = spec.Cwd
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		cancel()
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		cancel()
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		cancel()
		return nil, err
	}
	job.PID = cmd.Process.Pid

	go job.capture("stdout", stdout)
	go job.capture("stderr", stderr)
	go func() {
		err := cmd.Wait()
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
	}
}

func (j *Job) EventsSince(index int) ([]JobEvent, int) {
	j.buffer.mu.Lock()
	defer j.buffer.mu.Unlock()
	if index < 0 {
		index = 0
	}
	if index > len(j.buffer.events) {
		index = len(j.buffer.events)
	}
	events := append([]JobEvent(nil), j.buffer.events[index:]...)
	return events, len(j.buffer.events)
}

func (j *Job) WaitChannel() <-chan struct{} {
	j.buffer.mu.Lock()
	defer j.buffer.mu.Unlock()
	return j.buffer.wait
}

func (j *Job) capture(stream string, reader io.Reader) {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 0, 4096), 1024*1024)
	for scanner.Scan() {
		j.appendEvent(JobEvent{
			JobID:  j.ID,
			Stream: stream,
			Data:   scanner.Text() + "\n",
			Time:   time.Now().UTC(),
		})
	}
}

func (j *Job) finish(code int, err error) {
	j.buffer.mu.Lock()
	defer j.buffer.mu.Unlock()
	j.FinishedAt = time.Now().UTC()
	j.ExitCode = &code
	if err != nil {
		j.Error = err.Error()
	}
	j.buffer.appendLocked(JobEvent{
		JobID:    j.ID,
		Stream:   "exit",
		ExitCode: &code,
		Error:    j.Error,
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
	b.events = append(b.events, event)
	b.bytes += len(event.Data)
	for b.bytes > maxJobBufferBytes && len(b.events) > 0 {
		b.bytes -= len(b.events[0].Data)
		b.events = b.events[1:]
	}
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
