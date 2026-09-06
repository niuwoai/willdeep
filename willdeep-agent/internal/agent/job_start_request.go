package agent

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
)

const maximumStartRequestKeys = 10000

var (
	ErrStartInstanceChanged = errors.New("daemon instance changed; this request was not started")
	ErrStartKeyInvalid      = errors.New("request_id must be 16-128 ASCII letters, digits, hyphens or underscores")
	ErrStartKeyConflict     = errors.New("request_id already belongs to a different process specification")
	ErrStartKeyCapacity     = errors.New("daemon start request capacity reached; no new process was started")
	ErrStartKeySealed       = errors.New("request_id was reconciled before launch; no process was started")
)

type jobStartRequest struct {
	digest [32]byte
	sealed bool
	done   chan struct{}
	job    *Job
	err    error
}

func validStartRequestKey(key string) bool {
	if len(key) < 16 || len(key) > 128 {
		return false
	}
	for _, char := range key {
		if !(char >= 'a' && char <= 'z' || char >= 'A' && char <= 'Z' ||
			char >= '0' && char <= '9' || char == '-' || char == '_') {
			return false
		}
	}
	return true
}

// A request belongs to one daemon lifetime. Replaying it after a restart
// must fail, not silently execute a second copy of a possibly orphaned job.
// Entries, including launch failures, are retained for this entire lifetime;
// at capacity new keys are rejected rather than evicting old deduplication.
func (r *JobRegistry) StartProcessOnce(ctx context.Context, spec ProcessSpec, instance, key string) (*Job, error) {
	if instance != r.instanceID {
		return nil, ErrStartInstanceChanged
	}
	if !validStartRequestKey(key) {
		return nil, ErrStartKeyInvalid
	}
	var err error
	spec, err = normalizedProcessSpec(spec)
	if err != nil {
		return nil, err
	}
	encoded, err := json.Marshal(spec)
	if err != nil {
		return nil, err
	}
	digest := sha256.Sum256(encoded)
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	r.requestMu.Lock()
	if previous := r.requests[key]; previous != nil {
		r.requestMu.Unlock()
		if previous.sealed {
			return nil, ErrStartKeySealed
		}
		if previous.digest != digest {
			return nil, ErrStartKeyConflict
		}
		select {
		case <-previous.done:
			return previous.job, previous.err
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	if len(r.requests) >= maximumStartRequestKeys {
		r.requestMu.Unlock()
		return nil, ErrStartKeyCapacity
	}
	if r.requests == nil {
		r.requests = make(map[string]*jobStartRequest)
	}
	entry := &jobStartRequest{digest: digest, done: make(chan struct{})}
	r.requests[key] = entry
	r.requestMu.Unlock()
	entry.job, entry.err = r.startProcess(ctx, spec, "job-"+r.instanceID+"-request-"+key)
	close(entry.done)
	return entry.job, entry.err
}

type JobStartResolution struct {
	RequestID  string `json:"request_id"`
	InstanceID string `json:"instance_id"`
	State      string `json:"state"`
	Job        *Job   `json:"job,omitempty"`
}

// ReconcileStart never launches or kills a process. If StartProcessOnce has
// not committed this key, reconciliation seals it against every late POST.
// A plain 404 cannot provide that proof: a delayed POST may still arrive.
func (r *JobRegistry) ReconcileStart(instance, key string) (JobStartResolution, error) {
	result := JobStartResolution{RequestID: key, InstanceID: instance}
	if instance != r.instanceID {
		return result, ErrStartInstanceChanged
	}
	if !validStartRequestKey(key) {
		return result, ErrStartKeyInvalid
	}
	r.requestMu.Lock()
	entry := r.requests[key]
	if entry == nil {
		if len(r.requests) >= maximumStartRequestKeys {
			r.requestMu.Unlock()
			// Receipts are never evicted in this instance. At capacity an
			// absent key can never start, including after this response.
			result.State = "not_started"
			return result, nil
		}
		if r.requests == nil {
			r.requests = make(map[string]*jobStartRequest)
		}
		entry = &jobStartRequest{sealed: true, done: make(chan struct{}), err: ErrStartKeySealed}
		close(entry.done)
		r.requests[key] = entry
	}
	r.requestMu.Unlock()
	select {
	case <-entry.done:
		if entry.job == nil {
			result.State = "not_started"
		} else {
			result.State = "started"
			snapshot := entry.job.Snapshot()
			result.Job = &snapshot
		}
	default:
		result.State = "pending"
	}
	return result, nil
}
