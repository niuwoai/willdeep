package agent

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestStartProcessPreservesArgumentsWithoutShellExpansion(t *testing.T) {
	registry := NewJobRegistry()
	literal := "$(printf injected) ' \" ` newline\nsecond"
	job, err := registry.StartProcess(context.Background(), ProcessSpec{
		Executable: "/usr/bin/printf",
		Arguments:  []string{"%s", literal},
		Cwd:        t.TempDir(),
		Timeout:    5 * time.Second,
	})
	if err != nil {
		t.Fatalf("StartProcess: %v", err)
	}
	<-job.WaitChannel()
	if output := job.Output(); output != literal+"\n" {
		t.Fatalf("output = %q, want literal argument %q", output, literal)
	}
}

func TestStartProcessWritesStandardInputVerbatim(t *testing.T) {
	registry := NewJobRegistry()
	stdin := "prompt with 'quotes', $(substitution), and\nmultiple lines\n"
	job, err := registry.StartProcess(context.Background(), ProcessSpec{
		Executable: "/bin/cat",
		Stdin:      []byte(stdin),
		Cwd:        t.TempDir(),
		Timeout:    5 * time.Second,
	})
	if err != nil {
		t.Fatalf("StartProcess: %v", err)
	}
	<-job.WaitChannel()
	if output := job.Output(); output != stdin {
		t.Fatalf("output = %q, want stdin %q", output, stdin)
	}
}

func TestStartProcessRequiresExactlyOneLaunchMode(t *testing.T) {
	registry := NewJobRegistry()
	tests := []ProcessSpec{
		{},
		{Command: "true", Executable: "/usr/bin/true"},
		{Command: "true", Arguments: []string{"unexpected"}},
	}
	for _, spec := range tests {
		_, err := registry.StartProcess(context.Background(), spec)
		if err == nil {
			t.Fatalf("StartProcess(%+v) unexpectedly succeeded", spec)
		}
	}
}

func TestStartProcessOutlivesRequestCancellation(t *testing.T) {
	registry := NewJobRegistry()
	ctx, cancel := context.WithCancel(context.Background())
	job, err := registry.StartProcess(ctx, ProcessSpec{
		Executable: "/bin/sh",
		Arguments:  []string{"-c", "sleep 0.05; printf finished"},
		Cwd:        t.TempDir(),
		Timeout:    5 * time.Second,
	})
	if err != nil {
		t.Fatalf("StartProcess: %v", err)
	}
	cancel()
	<-job.WaitChannel()
	if output := job.Output(); !strings.Contains(output, "finished") {
		t.Fatalf("job was cancelled with request context: %q", output)
	}
}
