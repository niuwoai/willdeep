package agent

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const MobileGatewayProtocolVersion = "mobile-gateway.v1"

const (
	defaultMobilePairingTTL = 2 * time.Minute
	mobileWriteTimeout      = 5 * time.Second
	mobileMaxMessageBytes   = 1 * 1024 * 1024
)

type MobileGatewayConfigInput struct {
	Host           string
	Port           int
	DesktopName    string
	DesktopToken   string
	PairingTTL     time.Duration
	AllowPairing   bool
	PairingBaseURL string
}

type MobileGatewayConfig struct {
	Host           string
	Port           int
	DesktopName    string
	DesktopToken   string
	PairingTTL     time.Duration
	AllowPairing   bool
	PairingBaseURL string
}

type MobileGateway struct {
	config MobileGatewayConfig

	mu             sync.Mutex
	pairingToken   string
	pairingExpires time.Time
	pairingClaimed bool
	devices        map[string]*mobileDevice
	connections    map[*mobileConnection]struct{}
	desktop        *mobileConnection

	upgrader websocket.Upgrader
	now      func() time.Time
}

type MobileEnvelope struct {
	ID        string         `json:"id,omitempty"`
	Type      string         `json:"type"`
	SessionID string         `json:"session_id,omitempty"`
	Payload   map[string]any `json:"payload,omitempty"`
	Timestamp string         `json:"ts,omitempty"`
}

type mobileDevice struct {
	ID              string    `json:"id"`
	Name            string    `json:"name"`
	TokenHash       string    `json:"-"`
	CreatedAt       time.Time `json:"created_at"`
	LastConnectedAt time.Time `json:"last_connected_at,omitempty"`
	RevokedAt       time.Time `json:"revoked_at,omitempty"`
}

type mobileConnectionRole string

const (
	mobileRoleDesktop mobileConnectionRole = "desktop"
	mobileRoleDevice  mobileConnectionRole = "device"
)

type mobileConnection struct {
	role     mobileConnectionRole
	deviceID string
	conn     *websocket.Conn
	send     chan MobileEnvelope
	done     chan struct{}
	once     sync.Once
}

type mobilePairClaimRequest struct {
	PairingToken string `json:"pairing_token"`
	DeviceName   string `json:"device_name"`
}

type mobileRevokeRequest struct {
	DeviceID string `json:"device_id"`
}

var mobileCommandTypes = map[string]struct{}{
	"session.list":   {},
	"session.create": {},
	"session.select": {},
	"message.send":   {},
	"turn.stop":      {},
	"queue.update":   {},
	"tool.decide":    {},
	"patch.decide":   {},
	"file.read":      {},
	"diff.get":       {},
	"job.kill":       {},
}

var mobileDesktopEventTypes = map[string]struct{}{
	"state.snapshot":   {},
	"session.upsert":   {},
	"message.append":   {},
	"message.delta":    {},
	"message.done":     {},
	"tool.pending":     {},
	"tool.updated":     {},
	"patch.upsert":     {},
	"job.updated":      {},
	"worktree.updated": {},
	"error":            {},
	"ack":              {},
	"command.error":    {},
}

func NewMobileGatewayConfig(input MobileGatewayConfigInput) (MobileGatewayConfig, error) {
	host := strings.TrimSpace(input.Host)
	if host == "" {
		host = "127.0.0.1"
	}
	port := input.Port
	if port <= 0 || port > 65535 {
		return MobileGatewayConfig{}, fmt.Errorf("invalid port: %d", port)
	}
	desktopName := strings.TrimSpace(input.DesktopName)
	if desktopName == "" {
		desktopName = "WillDeep Mac"
	}
	desktopToken := strings.TrimSpace(input.DesktopToken)
	if desktopToken == "" {
		token, err := randomToken()
		if err != nil {
			return MobileGatewayConfig{}, err
		}
		desktopToken = token
	}
	pairingTTL := input.PairingTTL
	if pairingTTL <= 0 {
		pairingTTL = defaultMobilePairingTTL
	}
	return MobileGatewayConfig{
		Host:           host,
		Port:           port,
		DesktopName:    desktopName,
		DesktopToken:   desktopToken,
		PairingTTL:     pairingTTL,
		AllowPairing:   input.AllowPairing,
		PairingBaseURL: strings.TrimRight(strings.TrimSpace(input.PairingBaseURL), "/"),
	}, nil
}

func ServeMobileGateway(ctx context.Context, config MobileGatewayConfig) error {
	gateway, err := NewMobileGateway(config)
	if err != nil {
		return err
	}
	addr := net.JoinHostPort(config.Host, strconv.Itoa(config.Port))
	httpServer := &http.Server{Addr: addr, Handler: gateway.routes()}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdownCtx)
	}()

	log.Printf("willdeep-agent mobile gateway %s listening on http://%s protocol=%s", Version, addr, MobileGatewayProtocolVersion)
	err = httpServer.ListenAndServe()
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func NewMobileGateway(config MobileGatewayConfig) (*MobileGateway, error) {
	gateway := &MobileGateway{
		config:      config,
		devices:     map[string]*mobileDevice{},
		connections: map[*mobileConnection]struct{}{},
		upgrader: websocket.Upgrader{
			CheckOrigin: func(r *http.Request) bool { return true },
		},
		now: time.Now,
	}
	if config.AllowPairing {
		if err := gateway.rotatePairingTokenLocked(gateway.now()); err != nil {
			return nil, err
		}
	}
	return gateway, nil
}

func (g *MobileGateway) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /mobile/health", g.handleHealth)
	mux.HandleFunc("GET /mobile/pairing", g.handlePairingPayload)
	mux.HandleFunc("POST /mobile/pairing/rotate", g.handlePairingRotate)
	mux.HandleFunc("GET /mobile/devices", g.handleDevices)
	mux.HandleFunc("POST /mobile/pair/claim", g.handlePairClaim)
	mux.HandleFunc("POST /mobile/devices/revoke", g.handleDeviceRevoke)
	mux.HandleFunc("GET /mobile/ws", g.handleWebSocket)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeVersionHeaders(w)
		mux.ServeHTTP(w, r)
	})
}

func (g *MobileGateway) handleHealth(w http.ResponseWriter, r *http.Request) {
	g.mu.Lock()
	defer g.mu.Unlock()
	writeOK(w, map[string]any{
		"version":          VersionInfo(),
		"protocol_version": MobileGatewayProtocolVersion,
		"desktop_name":     g.config.DesktopName,
		"pairing_allowed":  g.pairingAvailableLocked(g.now()),
	})
}

func (g *MobileGateway) handlePairingPayload(w http.ResponseWriter, r *http.Request) {
	if !g.isDesktopRequest(r) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	g.mu.Lock()
	payload := g.pairingPayloadLocked(g.now())
	g.mu.Unlock()
	if payload == nil {
		writeError(w, http.StatusGone, "pairing token expired or already claimed")
		return
	}
	writeOK(w, map[string]any{"pairing_payload": payload})
}

func (g *MobileGateway) handlePairingRotate(w http.ResponseWriter, r *http.Request) {
	if !g.isDesktopRequest(r) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if !g.config.AllowPairing {
		writeError(w, http.StatusForbidden, "pairing is disabled")
		return
	}
	g.mu.Lock()
	if err := g.rotatePairingTokenLocked(g.now()); err != nil {
		g.mu.Unlock()
		writeError(w, http.StatusInternalServerError, "could not rotate pairing token")
		return
	}
	payload := g.pairingPayloadLocked(g.now())
	g.mu.Unlock()
	writeOK(w, map[string]any{"pairing_payload": payload})
}

func (g *MobileGateway) handleDevices(w http.ResponseWriter, r *http.Request) {
	if !g.isDesktopRequest(r) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	g.mu.Lock()
	devices := make([]mobileDevice, 0, len(g.devices))
	for _, device := range g.devices {
		devices = append(devices, *device)
	}
	g.mu.Unlock()
	sort.Slice(devices, func(i, j int) bool {
		return devices[i].CreatedAt.Before(devices[j].CreatedAt)
	})
	writeOK(w, map[string]any{"devices": devices})
}

func (g *MobileGateway) handlePairClaim(w http.ResponseWriter, r *http.Request) {
	var request mobilePairClaimRequest
	if err := decodeJSON(r.Body, &request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request")
		return
	}
	device, token, err := g.claimPairingToken(request.PairingToken, request.DeviceName)
	if err != nil {
		writeError(w, http.StatusUnauthorized, err.Error())
		return
	}
	writeOK(w, map[string]any{
		"device":           device,
		"device_token":     token,
		"protocol_version": MobileGatewayProtocolVersion,
	})
}

func (g *MobileGateway) handleDeviceRevoke(w http.ResponseWriter, r *http.Request) {
	if !g.isDesktopRequest(r) {
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	var request mobileRevokeRequest
	if err := decodeJSON(r.Body, &request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request")
		return
	}
	if err := g.revokeDevice(request.DeviceID); err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	writeOK(w, map[string]any{"revoked": true})
}

func (g *MobileGateway) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	role, deviceID, err := g.authenticateWebSocket(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, err.Error())
		return
	}
	writeVersionHeaders(w)
	conn, err := g.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	peer := &mobileConnection{
		role:     role,
		deviceID: deviceID,
		conn:     conn,
		send:     make(chan MobileEnvelope, 64),
		done:     make(chan struct{}),
	}
	g.registerConnection(peer)
	defer g.unregisterConnection(peer)

	go g.writeConnection(peer)
	g.readConnection(r.Context(), peer)
}

func (g *MobileGateway) claimPairingToken(token string, deviceName string) (mobileDevice, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	now := g.now()
	if !g.pairingAvailableLocked(now) {
		return mobileDevice{}, "", errors.New("pairing token expired or already claimed")
	}
	if subtle.ConstantTimeCompare([]byte(token), []byte(g.pairingToken)) != 1 {
		return mobileDevice{}, "", errors.New("invalid pairing token")
	}
	deviceToken, err := randomToken()
	if err != nil {
		return mobileDevice{}, "", err
	}
	deviceID, err := randomID("dev")
	if err != nil {
		return mobileDevice{}, "", err
	}
	name := strings.TrimSpace(deviceName)
	if name == "" {
		name = "Android Device"
	}
	device := &mobileDevice{
		ID:        deviceID,
		Name:      name,
		TokenHash: tokenHash(deviceToken),
		CreatedAt: now,
	}
	g.devices[device.ID] = device
	g.pairingClaimed = true
	return *device, deviceToken, nil
}

func (g *MobileGateway) revokeDevice(deviceID string) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	device, ok := g.devices[deviceID]
	if !ok {
		return errors.New("device not found")
	}
	now := g.now()
	device.RevokedAt = now
	var doomed []*mobileConnection
	for peer := range g.connections {
		if peer.role == mobileRoleDevice && peer.deviceID == deviceID {
			doomed = append(doomed, peer)
		}
	}
	for _, peer := range doomed {
		peer.close()
	}
	return nil
}

func (g *MobileGateway) authenticateWebSocket(r *http.Request) (mobileConnectionRole, string, error) {
	token := bearerToken(r)
	if token == "" {
		token = strings.TrimSpace(r.URL.Query().Get("token"))
	}
	if token == "" {
		return "", "", errors.New("missing token")
	}
	if subtle.ConstantTimeCompare([]byte(token), []byte(g.config.DesktopToken)) == 1 {
		return mobileRoleDesktop, "", nil
	}
	hash := tokenHash(token)
	g.mu.Lock()
	defer g.mu.Unlock()
	for id, device := range g.devices {
		if device.RevokedAt.IsZero() && subtle.ConstantTimeCompare([]byte(device.TokenHash), []byte(hash)) == 1 {
			device.LastConnectedAt = g.now()
			return mobileRoleDevice, id, nil
		}
	}
	return "", "", errors.New("unauthorized")
}

func (g *MobileGateway) isDesktopRequest(r *http.Request) bool {
	token := bearerToken(r)
	if token == "" {
		token = strings.TrimSpace(r.URL.Query().Get("token"))
	}
	return token != "" && subtle.ConstantTimeCompare([]byte(token), []byte(g.config.DesktopToken)) == 1
}

func (g *MobileGateway) registerConnection(peer *mobileConnection) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if peer.role == mobileRoleDesktop {
		if g.desktop != nil {
			g.desktop.close()
		}
		g.desktop = peer
	}
	g.connections[peer] = struct{}{}
}

func (g *MobileGateway) unregisterConnection(peer *mobileConnection) {
	g.mu.Lock()
	defer g.mu.Unlock()
	delete(g.connections, peer)
	if g.desktop == peer {
		g.desktop = nil
	}
	peer.close()
}

func (g *MobileGateway) readConnection(ctx context.Context, peer *mobileConnection) {
	defer peer.close()
	peer.conn.SetReadLimit(mobileMaxMessageBytes)
	for {
		var message MobileEnvelope
		if err := peer.conn.ReadJSON(&message); err != nil {
			return
		}
		if message.Timestamp == "" {
			message.Timestamp = g.now().UTC().Format(time.RFC3339Nano)
		}
		switch peer.role {
		case mobileRoleDesktop:
			g.handleDesktopEnvelope(message)
		case mobileRoleDevice:
			g.handleMobileEnvelope(peer, message)
		}
	}
}

func (g *MobileGateway) writeConnection(peer *mobileConnection) {
	defer peer.close()
	for {
		select {
		case <-peer.done:
			return
		case message := <-peer.send:
			_ = peer.conn.SetWriteDeadline(time.Now().Add(mobileWriteTimeout))
			if err := peer.conn.WriteJSON(message); err != nil {
				return
			}
		}
	}
}

func (g *MobileGateway) handleDesktopEnvelope(message MobileEnvelope) {
	if _, ok := mobileDesktopEventTypes[message.Type]; !ok {
		message = MobileEnvelope{
			ID:        message.ID,
			Type:      "error",
			SessionID: message.SessionID,
			Payload: map[string]any{
				"message": "unknown desktop event",
				"type":    message.Type,
			},
			Timestamp: g.now().UTC().Format(time.RFC3339Nano),
		}
	}
	g.broadcastToDevices(message)
}

func (g *MobileGateway) handleMobileEnvelope(peer *mobileConnection, message MobileEnvelope) {
	if _, ok := mobileCommandTypes[message.Type]; !ok {
		peer.enqueue(MobileEnvelope{
			ID:        message.ID,
			Type:      "error",
			SessionID: message.SessionID,
			Payload: map[string]any{
				"message": "unknown mobile command",
				"type":    message.Type,
			},
			Timestamp: g.now().UTC().Format(time.RFC3339Nano),
		})
		return
	}
	desktop := g.desktopConnection()
	if desktop == nil {
		peer.enqueue(MobileEnvelope{
			ID:        message.ID,
			Type:      "error",
			SessionID: message.SessionID,
			Payload: map[string]any{
				"message": "desktop peer is not connected",
				"type":    message.Type,
			},
			Timestamp: g.now().UTC().Format(time.RFC3339Nano),
		})
		return
	}
	message.Payload = clonePayload(message.Payload)
	message.Payload["_device_id"] = peer.deviceID
	desktop.enqueue(message)
	peer.enqueue(MobileEnvelope{
		ID:        message.ID,
		Type:      "ack",
		SessionID: message.SessionID,
		Payload: map[string]any{
			"type": message.Type,
		},
		Timestamp: g.now().UTC().Format(time.RFC3339Nano),
	})
}

func (g *MobileGateway) desktopConnection() *mobileConnection {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.desktop
}

func (g *MobileGateway) broadcastToDevices(message MobileEnvelope) {
	g.mu.Lock()
	peers := make([]*mobileConnection, 0, len(g.connections))
	for peer := range g.connections {
		if peer.role == mobileRoleDevice {
			peers = append(peers, peer)
		}
	}
	g.mu.Unlock()
	for _, peer := range peers {
		peer.enqueue(message)
	}
}

func (g *MobileGateway) pairingAvailableLocked(now time.Time) bool {
	return g.config.AllowPairing &&
		g.pairingToken != "" &&
		!g.pairingClaimed &&
		now.Before(g.pairingExpires)
}

func (g *MobileGateway) pairingPayloadLocked(now time.Time) map[string]any {
	if !g.pairingAvailableLocked(now) {
		return nil
	}
	return map[string]any{
		"base_url":         g.pairingBaseURLLocked(),
		"pairing_token":    g.pairingToken,
		"protocol_version": MobileGatewayProtocolVersion,
		"desktop_name":     g.config.DesktopName,
		"expires_at":       g.pairingExpires.UTC().Format(time.RFC3339Nano),
	}
}

func (g *MobileGateway) pairingBaseURLLocked() string {
	if g.config.PairingBaseURL != "" {
		return g.config.PairingBaseURL
	}
	return "http://" + net.JoinHostPort(g.config.Host, strconv.Itoa(g.config.Port))
}

func (g *MobileGateway) rotatePairingTokenLocked(now time.Time) error {
	token, err := randomToken()
	if err != nil {
		return err
	}
	g.pairingToken = token
	g.pairingExpires = now.Add(g.config.PairingTTL)
	g.pairingClaimed = false
	return nil
}

func (peer *mobileConnection) enqueue(message MobileEnvelope) {
	select {
	case <-peer.done:
		return
	case peer.send <- message:
	default:
		peer.close()
	}
}

func (peer *mobileConnection) close() {
	peer.once.Do(func() {
		close(peer.done)
		_ = peer.conn.Close()
	})
}

func bearerToken(r *http.Request) string {
	auth := strings.TrimSpace(r.Header.Get("Authorization"))
	if auth == "" {
		return ""
	}
	const prefix = "Bearer "
	if !strings.HasPrefix(auth, prefix) {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(auth, prefix))
}

func clonePayload(payload map[string]any) map[string]any {
	if payload == nil {
		return map[string]any{}
	}
	clone := make(map[string]any, len(payload)+1)
	for key, value := range payload {
		clone[key] = value
	}
	return clone
}

func tokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func randomID(prefix string) (string, error) {
	token, err := randomTokenBytes(12)
	if err != nil {
		return "", err
	}
	return prefix + "_" + base64.RawURLEncoding.EncodeToString(token), nil
}

func randomToken() (string, error) {
	token, err := randomTokenBytes(32)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(token), nil
}

func randomTokenBytes(size int) ([]byte, error) {
	token := make([]byte, size)
	if _, err := rand.Read(token); err != nil {
		return nil, fmt.Errorf("generate token: %w", err)
	}
	return token, nil
}

func RedactMobileSecret(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	if len(value) <= 8 {
		return "<redacted>"
	}
	return value[:4] + "…" + value[len(value)-4:]
}

func DecodeMobileEnvelope(data []byte) (MobileEnvelope, error) {
	var envelope MobileEnvelope
	err := json.Unmarshal(data, &envelope)
	return envelope, err
}
