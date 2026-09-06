package agent

import (
	"errors"
	"time"
)

const maximumJobDuration = 6 * time.Hour
const maximumDeadlineMilliseconds = int64((1<<63 - 1) / time.Millisecond)

var ErrRunDeadlineExpired = errors.New("run deadline expired before process start")
var ErrRunDeadlineInvalid = errors.New("invalid instance-relative run deadline")

// This clock belongs to one registry instance and includes Go's monotonic
// time component. It is neither wall-clock Unix time nor a fresh timeout
// on every retry. Restarted daemons reject the old instance identity.
func (r *JobRegistry) ElapsedMilliseconds() int64 {
	return time.Since(r.startedAt).Milliseconds()
}

func (r *JobRegistry) executionDeadline(spec ProcessSpec) (time.Time, error) {
	now := time.Now()
	deadline := now.Add(spec.Timeout)
	if spec.DeadlineElapsedMilliseconds == nil {
		return deadline, nil
	}
	requested := r.startedAt.Add(time.Duration(*spec.DeadlineElapsedMilliseconds) * time.Millisecond)
	if !requested.After(now) {
		return time.Time{}, ErrRunDeadlineExpired
	}
	if requested.Before(deadline) {
		return requested, nil
	}
	return deadline, nil
}
