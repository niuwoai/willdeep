package agent

import (
	"bytes"
	"errors"
	"time"
)

const maxJobOutputLineBytes = 1024 * 1024

var errJobOutputLineTooLong = errors.New("job output line exceeds capture limit")

// A writer is owned by one os/exec copy goroutine. flush runs only after
// cmd.Wait has joined those goroutines, so exit is always the last event.
type jobStreamWriter struct {
	job     *Job
	stream  string
	pending []byte
	err     error
}

func (w *jobStreamWriter) Write(data []byte) (int, error) {
	if w.err != nil {
		return 0, w.err
	}
	consumed := 0
	for len(data) > 0 {
		length := len(data)
		newline := bytes.IndexByte(data, '\n')
		if newline >= 0 {
			length = newline + 1
		}
		if len(w.pending)+length > maxJobOutputLineBytes {
			w.err = errJobOutputLineTooLong
			w.pending = nil
			return consumed, w.err
		}
		w.pending = append(w.pending, data[:length]...)
		consumed += length
		data = data[length:]
		if newline >= 0 {
			w.emit()
		}
	}
	return consumed, nil
}

func (w *jobStreamWriter) flush() {
	if w.err != nil || len(w.pending) == 0 {
		return
	}
	w.pending = append(w.pending, '\n')
	w.emit()
}

func (w *jobStreamWriter) emit() {
	w.job.appendEvent(JobEvent{JobID: w.job.ID, Stream: w.stream,
		Data: string(w.pending), Time: time.Now().UTC()})
	w.pending = w.pending[:0]
}
