package agent

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

const ChromeNativeHostProtocolVersion = "chrome-native-host.v3"

const (
	chromeNativeHostMaxInboundBytes  = 64 * 1024 * 1024
	chromeNativeHostMaxOutboundBytes = 1024 * 1024
	defaultChromeBridgeHost          = "127.0.0.1"
	defaultChromeBridgePort          = 8797
	defaultChromeBridgeTimeout       = 8 * time.Second
)

type ChromeNativeHostMessage struct {
	ID      string          `json:"id,omitempty"`
	Type    string          `json:"type,omitempty"`
	Payload json.RawMessage `json:"payload,omitempty"`
	ReplyTo string          `json:"reply_to,omitempty"`
	OK      bool            `json:"ok,omitempty"`
	Error   string          `json:"error,omitempty"`
	Data    json.RawMessage `json:"data,omitempty"`
}

type ChromeNativeHostResponse struct {
	ReplyTo string `json:"reply_to,omitempty"`
	OK      bool   `json:"ok"`
	Error   string `json:"error,omitempty"`
	Data    any    `json:"data,omitempty"`
}

type ChromeNativeBridge struct {
	reader  *bufio.Reader
	writer  *bufio.Writer
	writeMu sync.Mutex

	pendingMu sync.Mutex
	pending   map[string]chan ChromeNativeHostMessage
	nextID    atomic.Uint64
}

type ChromeBridgeRequest struct {
	Type      string          `json:"type"`
	Payload   json.RawMessage `json:"payload,omitempty"`
	TimeoutMS int             `json:"timeout_ms,omitempty"`
}

func ServeChromeNativeHost(ctx context.Context, input io.Reader, output io.Writer) error {
	bridge := &ChromeNativeBridge{
		reader:  bufio.NewReader(input),
		writer:  bufio.NewWriter(output),
		pending: map[string]chan ChromeNativeHostMessage{},
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	defer bridge.writer.Flush()

	httpServer, listener, err := bridge.startHTTPBridge(ctx)
	if err != nil {
		log.Printf("willdeep chrome bridge HTTP listener disabled: %v", err)
	} else {
		defer func() {
			shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer shutdownCancel()
			_ = httpServer.Shutdown(shutdownCtx)
		}()
		go func() {
			if serveErr := httpServer.Serve(listener); serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
				log.Printf("willdeep chrome bridge HTTP server stopped: %v", serveErr)
			}
		}()
		log.Printf("willdeep chrome bridge listening on http://%s", listener.Addr().String())
	}

	for {
		select {
		case <-ctx.Done():
			return nil
		default:
		}

		message, err := readChromeNativeHostMessage(bridge.reader)
		if err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				return nil
			}
			return err
		}
		if message.ReplyTo != "" {
			bridge.deliverReply(message)
			continue
		}
		response := handleChromeNativeHostMessage(message)
		if err := bridge.writeResponse(response); err != nil {
			return err
		}
	}
}

func (b *ChromeNativeBridge) startHTTPBridge(ctx context.Context) (*http.Server, net.Listener, error) {
	addr := net.JoinHostPort(defaultChromeBridgeHost, strconv.Itoa(chromeBridgePort()))
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, nil, err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /chrome/health", b.handleHealth)
	mux.HandleFunc("POST /chrome/request", b.handleRequest)
	server := &http.Server{Handler: mux}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	return server, listener, nil
}

func (b *ChromeNativeBridge) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeOK(w, map[string]any{
		"name":             "willdeep-chrome-bridge",
		"version":          VersionInfo(),
		"protocol_version": ChromeNativeHostProtocolVersion,
		"native_connected": true,
		"capabilities":     chromeNativeHostCapabilities(),
	})
}

func (b *ChromeNativeBridge) handleRequest(w http.ResponseWriter, r *http.Request) {
	var request ChromeBridgeRequest
	if err := decodeJSON(r.Body, &request); err != nil {
		writeError(w, http.StatusBadRequest, "decode chrome bridge request: "+err.Error())
		return
	}
	if request.Type == "" {
		writeError(w, http.StatusBadRequest, "type is required")
		return
	}
	timeout := defaultChromeBridgeTimeout
	if request.TimeoutMS > 0 {
		timeout = time.Duration(request.TimeoutMS) * time.Millisecond
		if timeout > 30*time.Second {
			timeout = 30 * time.Second
		}
	}
	ctx, cancel := context.WithTimeout(r.Context(), timeout)
	defer cancel()

	reply, err := b.sendRequest(ctx, request.Type, request.Payload)
	if err != nil {
		writeError(w, http.StatusGatewayTimeout, err.Error())
		return
	}
	if !reply.OK {
		if reply.Error == "" {
			reply.Error = "chrome extension returned an error"
		}
		writeError(w, http.StatusBadGateway, reply.Error)
		return
	}
	writeOK(w, json.RawMessage(reply.Data))
}

func (b *ChromeNativeBridge) sendRequest(ctx context.Context, messageType string, payload json.RawMessage) (ChromeNativeHostMessage, error) {
	id := fmt.Sprintf("host-%d", b.nextID.Add(1))
	replyCh := make(chan ChromeNativeHostMessage, 1)
	b.pendingMu.Lock()
	b.pending[id] = replyCh
	b.pendingMu.Unlock()
	defer func() {
		b.pendingMu.Lock()
		delete(b.pending, id)
		b.pendingMu.Unlock()
	}()

	if err := b.writeMessage(ChromeNativeHostMessage{ID: id, Type: messageType, Payload: payload}); err != nil {
		return ChromeNativeHostMessage{}, err
	}
	select {
	case <-ctx.Done():
		return ChromeNativeHostMessage{}, fmt.Errorf("chrome bridge request %s timed out: %w", messageType, ctx.Err())
	case reply := <-replyCh:
		return reply, nil
	}
}

func (b *ChromeNativeBridge) deliverReply(message ChromeNativeHostMessage) {
	b.pendingMu.Lock()
	replyCh := b.pending[message.ReplyTo]
	b.pendingMu.Unlock()
	if replyCh == nil {
		log.Printf("willdeep chrome bridge received orphan reply: %s", message.ReplyTo)
		return
	}
	select {
	case replyCh <- message:
	default:
		log.Printf("willdeep chrome bridge pending reply channel full: %s", message.ReplyTo)
	}
}

func (b *ChromeNativeBridge) writeMessage(message ChromeNativeHostMessage) error {
	b.writeMu.Lock()
	defer b.writeMu.Unlock()
	if err := writeChromeNativeHostFrame(b.writer, message); err != nil {
		return err
	}
	return b.writer.Flush()
}

func (b *ChromeNativeBridge) writeResponse(response ChromeNativeHostResponse) error {
	b.writeMu.Lock()
	defer b.writeMu.Unlock()
	if err := writeChromeNativeHostResponse(b.writer, response); err != nil {
		return err
	}
	return b.writer.Flush()
}

func readChromeNativeHostMessage(reader io.Reader) (ChromeNativeHostMessage, error) {
	var length uint32
	if err := binary.Read(reader, binary.LittleEndian, &length); err != nil {
		return ChromeNativeHostMessage{}, err
	}
	if length == 0 || length > chromeNativeHostMaxInboundBytes {
		return ChromeNativeHostMessage{}, fmt.Errorf("invalid chrome native message length: %d", length)
	}

	body := make([]byte, length)
	if _, err := io.ReadFull(reader, body); err != nil {
		return ChromeNativeHostMessage{}, err
	}
	var message ChromeNativeHostMessage
	if err := json.Unmarshal(body, &message); err != nil {
		return ChromeNativeHostMessage{}, fmt.Errorf("decode chrome native message: %w", err)
	}
	return message, nil
}

func writeChromeNativeHostResponse(writer io.Writer, response ChromeNativeHostResponse) error {
	return writeChromeNativeHostFrame(writer, response)
}

func writeChromeNativeHostFrame(writer io.Writer, value any) error {
	body, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if len(body) > chromeNativeHostMaxOutboundBytes {
		return fmt.Errorf("chrome native message too large: %d", len(body))
	}
	if err := binary.Write(writer, binary.LittleEndian, uint32(len(body))); err != nil {
		return err
	}
	_, err = writer.Write(body)
	return err
}

func handleChromeNativeHostMessage(message ChromeNativeHostMessage) ChromeNativeHostResponse {
	response := ChromeNativeHostResponse{
		ReplyTo: message.ID,
		OK:      true,
	}
	switch message.Type {
	case "hello", "ping":
		response.Data = map[string]any{
			"name":             "willdeep-agent",
			"version":          VersionInfo(),
			"protocol_version": ChromeNativeHostProtocolVersion,
			"capabilities":     chromeNativeHostCapabilities(),
		}
	case "browser_event":
		response.Data = map[string]any{
			"received": true,
		}
	default:
		response.OK = false
		response.Error = "unknown chrome native host message type: " + message.Type
	}
	return response
}

func chromeNativeHostCapabilities() []string {
	return []string{
		"native.ping",
		"page.read",
		"page.selection",
		"page.snapshot",
		"page.click",
		"page.type",
		"page.hover",
		"page.select_option",
		"page.key",
		"page.scroll",
		"page.wait",
		"tab.list",
		"tab.activate",
		"tab.navigate",
		"tab.history",
		"tab.capture",
		"debugger.command",
	}
}

func chromeBridgePort() int {
	raw := os.Getenv("WILLDEEP_CHROME_BRIDGE_PORT")
	if raw == "" {
		return defaultChromeBridgePort
	}
	port, err := strconv.Atoi(raw)
	if err != nil || port <= 0 || port > 65535 {
		return defaultChromeBridgePort
	}
	return port
}
