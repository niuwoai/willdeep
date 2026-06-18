package agent

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"testing"
	"time"
)

func TestChromeNativeHostPing(t *testing.T) {
	input := encodeChromeNativeHostTestMessage(t, ChromeNativeHostMessage{
		ID:   "msg-1",
		Type: "ping",
	})
	var output bytes.Buffer

	if err := ServeChromeNativeHost(context.Background(), bytes.NewReader(input), &output); err != nil {
		t.Fatalf("ServeChromeNativeHost: %v", err)
	}

	response := decodeChromeNativeHostTestResponse(t, output.Bytes())
	if !response.OK {
		t.Fatalf("response not ok: %#v", response)
	}
	if response.ReplyTo != "msg-1" {
		t.Fatalf("reply_to = %q, want msg-1", response.ReplyTo)
	}
	data, ok := response.Data.(map[string]any)
	if !ok {
		t.Fatalf("data = %#v", response.Data)
	}
	if data["protocol_version"] != ChromeNativeHostProtocolVersion {
		t.Fatalf("protocol_version = %#v", data["protocol_version"])
	}
}

func TestChromeNativeHostRejectsUnknownType(t *testing.T) {
	input := encodeChromeNativeHostTestMessage(t, ChromeNativeHostMessage{
		ID:   "msg-2",
		Type: "unknown",
	})
	var output bytes.Buffer

	if err := ServeChromeNativeHost(context.Background(), bytes.NewReader(input), &output); err != nil {
		t.Fatalf("ServeChromeNativeHost: %v", err)
	}

	response := decodeChromeNativeHostTestResponse(t, output.Bytes())
	if response.OK {
		t.Fatalf("response unexpectedly ok: %#v", response)
	}
	if response.Error == "" {
		t.Fatalf("expected error message")
	}
}

func TestChromeNativeBridgeSendRequestWritesFrameAndReceivesReply(t *testing.T) {
	var output bytes.Buffer
	bridge := &ChromeNativeBridge{
		writer:  bufio.NewWriter(&output),
		pending: map[string]chan ChromeNativeHostMessage{},
	}

	resultCh := make(chan ChromeNativeHostMessage, 1)
	errCh := make(chan error, 1)
	go func() {
		reply, err := bridge.sendRequest(context.Background(), "page.read", json.RawMessage(`{"maxChars":1200}`))
		if err != nil {
			errCh <- err
			return
		}
		resultCh <- reply
	}()

	message := waitForChromeNativeHostTestMessage(t, &output)
	if message.Type != "page.read" {
		t.Fatalf("type = %q, want page.read", message.Type)
	}
	if message.ID == "" {
		t.Fatalf("expected generated id")
	}
	if string(message.Payload) != `{"maxChars":1200}` {
		t.Fatalf("payload = %s", message.Payload)
	}

	bridge.deliverReply(ChromeNativeHostMessage{
		ReplyTo: message.ID,
		OK:      true,
		Data:    json.RawMessage(`{"title":"Example"}`),
	})

	select {
	case err := <-errCh:
		t.Fatalf("sendRequest: %v", err)
	case reply := <-resultCh:
		if !reply.OK {
			t.Fatalf("reply not ok: %#v", reply)
		}
		if string(reply.Data) != `{"title":"Example"}` {
			t.Fatalf("reply data = %s", reply.Data)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for sendRequest reply")
	}
}

func encodeChromeNativeHostTestMessage(t *testing.T, message ChromeNativeHostMessage) []byte {
	t.Helper()
	body, err := json.Marshal(message)
	if err != nil {
		t.Fatalf("marshal message: %v", err)
	}
	var buffer bytes.Buffer
	if err := binary.Write(&buffer, binary.LittleEndian, uint32(len(body))); err != nil {
		t.Fatalf("write length: %v", err)
	}
	buffer.Write(body)
	return buffer.Bytes()
}

func waitForChromeNativeHostTestMessage(t *testing.T, buffer *bytes.Buffer) ChromeNativeHostMessage {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if buffer.Len() > 4 {
			return decodeChromeNativeHostTestMessage(t, buffer.Bytes())
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for native host message")
	return ChromeNativeHostMessage{}
}

func decodeChromeNativeHostTestMessage(t *testing.T, data []byte) ChromeNativeHostMessage {
	t.Helper()
	reader := bytes.NewReader(data)
	var length uint32
	if err := binary.Read(reader, binary.LittleEndian, &length); err != nil {
		t.Fatalf("read length: %v", err)
	}
	body := make([]byte, length)
	if _, err := reader.Read(body); err != nil {
		t.Fatalf("read body: %v", err)
	}
	var message ChromeNativeHostMessage
	if err := json.Unmarshal(body, &message); err != nil {
		t.Fatalf("decode message: %v", err)
	}
	return message
}

func decodeChromeNativeHostTestResponse(t *testing.T, data []byte) ChromeNativeHostResponse {
	t.Helper()
	reader := bytes.NewReader(data)
	var length uint32
	if err := binary.Read(reader, binary.LittleEndian, &length); err != nil {
		t.Fatalf("read length: %v", err)
	}
	body := make([]byte, length)
	if _, err := reader.Read(body); err != nil {
		t.Fatalf("read body: %v", err)
	}
	var response ChromeNativeHostResponse
	if err := json.Unmarshal(body, &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	return response
}
