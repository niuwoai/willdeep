package agent

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
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
	// ChromeBridgeTokenHeader carries the per-launch secret the WillDeep app
	// reads from the 0600 token file. Without it any local process — or a web
	// page posting to 127.0.0.1 — could drive the user's logged-in Chrome.
	ChromeBridgeTokenHeader     = "X-WillDeep-Bridge-Token"
	chromeBridgeTokenBytes      = 32
	chromeBridgeTokenFileName   = "bridge-token"
	chromeBridgeTokenFileEnvVar = "WILLDEEP_CHROME_BRIDGE_TOKEN_FILE"
	// chromeBridgeBindRetryInterval is how often a host that lost the port
	// race tries again.
	chromeBridgeBindRetryInterval = 5 * time.Second
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

	token string
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

	// One host process runs per Chrome profile, and only one can own the
	// port. The others keep retrying so the bridge survives the owner's
	// profile being closed instead of going dark while Chrome is still open.
	var bridgeServer sync.WaitGroup
	bridgeServer.Add(1)
	go func() {
		defer bridgeServer.Done()
		bridge.serveHTTPBridgeWithRetry(ctx, chromeBridgeBindRetryInterval)
	}()
	defer func() {
		cancel()
		bridgeServer.Wait()
	}()

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

// serveHTTPBridgeWithRetry binds the loopback bridge, retrying every
// interval while another host owns the port, and serves until ctx ends.
// startHTTPBridge's own goroutine shuts the server down on ctx.Done.
func (b *ChromeNativeBridge) serveHTTPBridgeWithRetry(ctx context.Context, interval time.Duration) {
	loggedBusy := false
	for {
		httpServer, listener, err := b.startHTTPBridge(ctx)
		if err == nil {
			log.Printf("willdeep chrome bridge listening on http://%s", listener.Addr().String())
			if serveErr := httpServer.Serve(listener); serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
				log.Printf("willdeep chrome bridge HTTP server stopped: %v", serveErr)
			}
			return
		}
		if !loggedBusy {
			log.Printf("willdeep chrome bridge HTTP listener unavailable, retrying every %s: %v", interval, err)
			loggedBusy = true
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(interval):
		}
	}
}

func (b *ChromeNativeBridge) startHTTPBridge(ctx context.Context) (*http.Server, net.Listener, error) {
	addr := net.JoinHostPort(defaultChromeBridgeHost, strconv.Itoa(chromeBridgePort()))
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, nil, err
	}
	// Publish the token only after winning the port: a second Chrome
	// profile's host that failed to bind must not overwrite the secret of
	// the host that is actually serving.
	token, err := newChromeBridgeToken()
	if err != nil {
		_ = listener.Close()
		return nil, nil, err
	}
	if err := writeChromeBridgeToken(chromeBridgeTokenPath(), token); err != nil {
		_ = listener.Close()
		return nil, nil, fmt.Errorf("write chrome bridge token: %w", err)
	}
	b.token = token
	mux := http.NewServeMux()
	mux.HandleFunc("GET /chrome/health", b.handleHealth)
	mux.HandleFunc("POST /chrome/request", b.handleRequest)
	server := &http.Server{Handler: b.guard(mux, listener.Addr())}
	tokenPath := chromeBridgeTokenPath()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
		removeChromeBridgeTokenIfOwned(tokenPath, token)
	}()
	return server, listener, nil
}

// removeChromeBridgeTokenIfOwned deletes the token file on shutdown unless a
// newer host has already replaced it, so the app does not keep sending a
// token nobody is listening for.
func removeChromeBridgeTokenIfOwned(path, token string) {
	data, err := os.ReadFile(path)
	if err != nil || string(data) != token {
		return
	}
	_ = os.Remove(path)
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

// guard rejects anything that is not the WillDeep app talking to the bridge:
// browser-originated requests (any Origin header), DNS-rebinding hosts, and
// callers without the per-launch token.
func (b *ChromeNativeBridge) guard(next http.Handler, addr net.Addr) http.Handler {
	allowedHosts := chromeBridgeAllowedHosts(addr)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Origin") != "" {
			writeError(w, http.StatusForbidden, "chrome bridge does not accept browser-originated requests")
			return
		}
		if _, ok := allowedHosts[strings.ToLower(r.Host)]; !ok {
			writeError(w, http.StatusForbidden, "chrome bridge rejected host "+r.Host)
			return
		}
		provided := r.Header.Get(ChromeBridgeTokenHeader)
		if b.token == "" || subtle.ConstantTimeCompare([]byte(provided), []byte(b.token)) != 1 {
			writeError(w, http.StatusUnauthorized, "chrome bridge token missing or invalid")
			return
		}
		if r.Method == http.MethodPost {
			mediaType := strings.TrimSpace(strings.SplitN(r.Header.Get("Content-Type"), ";", 2)[0])
			if !strings.EqualFold(mediaType, "application/json") {
				writeError(w, http.StatusUnsupportedMediaType, "chrome bridge requires application/json")
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

func chromeBridgeAllowedHosts(addr net.Addr) map[string]struct{} {
	port := strconv.Itoa(chromeBridgePort())
	if tcp, ok := addr.(*net.TCPAddr); ok {
		port = strconv.Itoa(tcp.Port)
	}
	return map[string]struct{}{
		net.JoinHostPort(defaultChromeBridgeHost, port): {},
		net.JoinHostPort("localhost", port):             {},
	}
}

func newChromeBridgeToken() (string, error) {
	raw := make([]byte, chromeBridgeTokenBytes)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("generate chrome bridge token: %w", err)
	}
	return hex.EncodeToString(raw), nil
}

// chromeBridgeTokenPath is where the WillDeep app looks for the token; it
// sits next to the native-host launcher the app installs.
func chromeBridgeTokenPath() string {
	if override := strings.TrimSpace(os.Getenv(chromeBridgeTokenFileEnvVar)); override != "" {
		return override
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		home = os.Getenv("HOME")
	}
	return filepath.Join(home, "Library", "Application Support", "WillDeep", "ChromeNativeHost", chromeBridgeTokenFileName)
}

// writeChromeBridgeToken writes via a 0600 temp file + rename so the app
// never reads a half-written token and no other user can read it.
func writeChromeBridgeToken(path, token string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), chromeBridgeTokenFileName+".*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.WriteString(token); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpPath, path)
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
