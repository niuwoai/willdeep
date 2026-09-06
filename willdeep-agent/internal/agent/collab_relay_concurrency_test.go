package agent

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// The relay's three entry points — callback ingress, poll, and ack — all mutate
// the same queue, counters, and journal behind one mutex, and in production they
// run concurrently: a Feishu callback lands while a desktop client is polling and
// a second window is acknowledging what it already handled. Every existing test
// drives one path at a time, so a lock held too briefly, a counter incremented
// outside it, or a journal write racing a queue swap would all pass review.
//
// This exercises the three paths against each other under `-race` and then
// checks the accounting identity that has to hold no matter how the operations
// interleave:
//
//	Received == Deduplicated + Dropped + Acknowledged + len(queue)
//
// Every event the relay ever saw is either a duplicate it folded, one it refused
// for capacity, one a client acknowledged, or one still waiting. An event that
// falls out of that equation was lost.
func TestCollaborationRelayHandlesConcurrentCallbackPollAndAck(t *testing.T) {
	const (
		producers         = 4
		eventsPerProducer = 30
		consumers         = 3
		queueCapacity     = 32
		burstOverflow     = 8
	)

	cfg, err := NewCollaborationRelayConfig(CollaborationRelayConfigInput{
		Host:           "127.0.0.1",
		Port:           8898,
		PublicBaseURL:  "https://fly.niuwoai.com",
		Token:          "relay-secret",
		MaxEvents:      queueCapacity,
		EventStoreFile: filepath.Join(t.TempDir(), "relay-events.json"),
	})
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	relay := NewCollaborationRelay(cfg)
	if relay.startupError != nil {
		t.Fatalf("startup: %v", relay.startupError)
	}
	server := httptest.NewServer(relay.routes())
	defer server.Close()

	// A capacity smaller than the offered load is deliberate: it forces the
	// full-queue branch to run while polls and acks are in flight, which is the
	// interleaving where an evicted or double-counted event would hide.
	var (
		mu       sync.Mutex
		queued   = map[string]struct{}{}
		acked    = map[string]struct{}{}
		ackTotal int
	)

	post := func(id string) (int, bool) {
		body := fmt.Sprintf(
			`{"EventType":"chat_update","eventId":%q,"conversationId":"cid"}`,
			id,
		)
		req, err := http.NewRequest(
			http.MethodPost,
			server.URL+"/events/dingtalk",
			strings.NewReader(body),
		)
		if err != nil {
			return 0, false
		}
		req.Header.Set("Authorization", "Bearer relay-secret")
		req.Header.Set("Content-Type", "application/json")
		resp, err := server.Client().Do(req)
		if err != nil {
			return 0, false
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return resp.StatusCode, false
		}
		var decoded APIResponse
		if err := json.NewDecoder(resp.Body).Decode(&decoded); err != nil {
			return resp.StatusCode, false
		}
		data, _ := decoded.Data.(map[string]any)
		accepted, _ := data["queued"].(bool)
		return resp.StatusCode, accepted
	}

	drain := func() int {
		req, err := http.NewRequest(http.MethodGet, server.URL+"/events/poll?limit=100", nil)
		if err != nil {
			return 0
		}
		req.Header.Set("Authorization", "Bearer relay-secret")
		resp, err := server.Client().Do(req)
		if err != nil {
			return 0
		}
		var polled APIResponse
		decodeErr := json.NewDecoder(resp.Body).Decode(&polled)
		_ = resp.Body.Close()
		if decodeErr != nil {
			return 0
		}
		data, _ := polled.Data.(map[string]any)
		entries, _ := data["events"].([]any)
		ids := make([]string, 0, len(entries))
		for _, entry := range entries {
			event, _ := entry.(map[string]any)
			id, _ := event["id"].(string)
			if id != "" {
				ids = append(ids, id)
			}
		}
		if len(ids) == 0 {
			return 0
		}
		payload, err := json.Marshal(map[string]any{"event_ids": ids})
		if err != nil {
			return 0
		}
		ackResp := authorizedRelayJSONRequestNoFatal(server, http.MethodPost, "/events/ack", string(payload))
		if ackResp == nil {
			return 0
		}
		var ack APIResponse
		decodeErr = json.NewDecoder(ackResp.Body).Decode(&ack)
		_ = ackResp.Body.Close()
		if decodeErr != nil {
			return 0
		}
		ackData, _ := ack.Data.(map[string]any)
		count, _ := ackData["acknowledged"].(float64)

		mu.Lock()
		ackTotal += int(count)
		for _, id := range ids {
			acked[id] = struct{}{}
		}
		mu.Unlock()
		return int(count)
	}

	// Phase 1: fill past capacity with nobody draining. Leaving this to chance
	// in the concurrent phase does not work — consumers keep up, the queue never
	// fills, and the capacity branch silently goes uncovered.
	burstAccepted := 0
	burstRejected := 0
	for i := 0; i < queueCapacity+burstOverflow; i++ {
		id := fmt.Sprintf("burst-%d", i)
		status, accepted := post(id)
		switch {
		case accepted:
			burstAccepted++
			queued[id] = struct{}{}
		case status == http.StatusTooManyRequests:
			burstRejected++
		default:
			t.Fatalf("burst post %s: status=%d accepted=%t", id, status, accepted)
		}
	}
	if burstAccepted != queueCapacity {
		t.Fatalf("burst queued %d events, want %d", burstAccepted, queueCapacity)
	}
	if burstRejected != burstOverflow {
		t.Fatalf("burst rejected %d events, want %d", burstRejected, burstOverflow)
	}
	// A replay of an id that is still queued folds into the dedup counter even
	// though the queue is full: dedup is decided before capacity. Pinning it
	// here keeps that ordering covered without depending on how the concurrent
	// phase happens to interleave.
	if status, accepted := post("burst-0"); accepted || status != http.StatusOK {
		t.Fatalf("replay of a queued id: status=%d accepted=%t, want 200 and not queued", status, accepted)
	}

	var producing sync.WaitGroup
	stopConsumers := make(chan struct{})
	var consuming sync.WaitGroup

	for c := 0; c < consumers; c++ {
		consuming.Add(1)
		go func() {
			defer consuming.Done()
			for {
				select {
				case <-stopConsumers:
					return
				default:
				}
				if drain() == 0 {
					time.Sleep(time.Millisecond)
				}
			}
		}()
	}

	for p := 0; p < producers; p++ {
		producing.Add(1)
		go func(producer int) {
			defer producing.Done()
			for i := 0; i < eventsPerProducer; i++ {
				id := fmt.Sprintf("evt-%d-%d", producer, i)
				_, first := post(id)
				// Replaying the same id models a platform redelivering a
				// callback it did not see acknowledged. While the entry is still
				// queued this must fold into the dedup counter rather than
				// create a second entry; once a consumer has acknowledged it,
				// the replay is a fresh event again. Either post may be the one
				// that lands, because the first can hit a full queue.
				_, second := post(id)
				if first || second {
					mu.Lock()
					queued[id] = struct{}{}
					mu.Unlock()
				}
			}
		}(p)
	}

	producing.Wait()

	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		relay.mu.Lock()
		remaining := len(relay.events)
		relay.mu.Unlock()
		if remaining == 0 {
			break
		}
		time.Sleep(2 * time.Millisecond)
	}
	close(stopConsumers)
	consuming.Wait()
	// One last pass: a consumer may have exited between its poll and its ack.
	for drain() > 0 {
	}

	relay.mu.Lock()
	counters := relay.counters
	remaining := len(relay.events)
	relay.mu.Unlock()

	accounted := counters.Deduplicated + counters.Dropped + counters.Acknowledged + uint64(remaining)
	if counters.Received != accounted {
		t.Fatalf(
			"accounting lost events: received=%d dedup=%d dropped=%d acked=%d remaining=%d",
			counters.Received,
			counters.Deduplicated,
			counters.Dropped,
			counters.Acknowledged,
			remaining,
		)
	}

	// Every offer reached the relay: the burst, its one replay, plus two posts
	// per concurrent event.
	want := uint64(queueCapacity + burstOverflow + 1 + producers*eventsPerProducer*2)
	if counters.Received != want {
		t.Fatalf("received = %d, want %d", counters.Received, want)
	}

	mu.Lock()
	queuedCount := len(queued)
	ackedCount := len(acked)
	total := ackTotal
	mu.Unlock()

	// An id acknowledged twice would inflate the server's tally past the number
	// of distinct ids the consumers actually saw.
	if uint64(total) != counters.Acknowledged {
		t.Fatalf("ack tally %d disagrees with counter %d", total, counters.Acknowledged)
	}
	if ackedCount != queuedCount {
		t.Fatalf("acknowledged %d distinct ids, but %d were queued", ackedCount, queuedCount)
	}
	if remaining != 0 {
		t.Fatalf("queue did not drain: %d events left", remaining)
	}
	if counters.Dropped == 0 {
		t.Fatal("capacity branch never ran; the test no longer covers a full queue")
	}
	if counters.Deduplicated == 0 {
		t.Fatal("dedup branch never ran; replayed callbacks were not folded")
	}
}

// authorizedRelayJSONRequestNoFatal mirrors authorizedRelayJSONRequest for use
// off the test goroutine, where t.Fatalf is not allowed. Callers get a nil
// response instead and let the invariant checks report the damage.
func authorizedRelayJSONRequestNoFatal(
	server *httptest.Server,
	method string,
	path string,
	body string,
) *http.Response {
	req, err := http.NewRequest(method, server.URL+path, strings.NewReader(body))
	if err != nil {
		return nil
	}
	req.Header.Set("Authorization", "Bearer relay-secret")
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := server.Client().Do(req)
	if err != nil {
		return nil
	}
	return resp
}
