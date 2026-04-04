package main

import (
	"errors"
	"log"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"
)

type Pairing struct {
	Code      string
	AppID     string
	ExpiresAt time.Time
}

type Session struct {
	ID        string
	TokenHash string
	AppID     string
	AgentID   string
	Cols      int
	Rows      int
	CreatedAt time.Time
	AppSocket *wsPeer
}

type agentConnection struct {
	Agent *AgentRecord
	Peer  *wsPeer
}

type wsPeer struct {
	conn *websocket.Conn
	mu   sync.Mutex
}

func newWSPeer(conn *websocket.Conn) *wsPeer {
	return &wsPeer{conn: conn}
}

func (p *wsPeer) WriteEnvelope(envelope relayEnvelope) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.conn.WriteJSON(envelope)
}

func (p *wsPeer) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.conn.Close()
}

type Hub struct {
	mu       sync.RWMutex
	store    *Store
	cfg      Config
	logger   *log.Logger
	pairings map[string]*Pairing
	agents   map[string]*agentConnection
	sessions map[string]*Session
}

func NewHub(cfg Config, store *Store, logger *log.Logger) *Hub {
	return &Hub{
		store:    store,
		cfg:      cfg,
		logger:   logger,
		pairings: map[string]*Pairing{},
		agents:   map[string]*agentConnection{},
		sessions: map[string]*Session{},
	}
}

func (h *Hub) StartCleanup(stop <-chan struct{}) {
	ticker := time.NewTicker(h.cfg.CleanupInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			h.cleanupExpired()
		case <-stop:
			return
		}
	}
}

func (h *Hub) CreatePairing(appID string) (*Pairing, error) {
	code, err := newPairingCode()
	if err != nil {
		return nil, err
	}

	pairing := &Pairing{
		Code:      code,
		AppID:     appID,
		ExpiresAt: time.Now().UTC().Add(h.cfg.PairingTTL),
	}

	h.mu.Lock()
	defer h.mu.Unlock()

	for {
		if _, exists := h.pairings[pairing.Code]; !exists {
			h.pairings[pairing.Code] = pairing
			return pairing, nil
		}

		code, err = newPairingCode()
		if err != nil {
			return nil, err
		}
		pairing.Code = code
	}
}

func (h *Hub) ConsumePairing(code string) (*AppRecord, error) {
	h.mu.Lock()
	defer h.mu.Unlock()

	pairing, ok := h.pairings[code]
	if !ok {
		return nil, errors.New("pairing code not found")
	}

	delete(h.pairings, code)
	if time.Now().UTC().After(pairing.ExpiresAt) {
		return nil, errors.New("pairing code expired")
	}

	app, ok := h.store.AppByID(pairing.AppID)
	if !ok {
		return nil, errors.New("paired app no longer exists")
	}

	return app, nil
}

func (h *Hub) RegisterAgentConnection(agent *AgentRecord, conn *websocket.Conn) *agentConnection {
	connection := &agentConnection{
		Agent: agent,
		Peer:  newWSPeer(conn),
	}

	h.mu.Lock()
	defer h.mu.Unlock()

	if existing, ok := h.agents[agent.ID]; ok {
		_ = existing.Peer.Close()
	}

	h.agents[agent.ID] = connection
	return connection
}

func (h *Hub) UnregisterAgentConnection(agentID string, connection *agentConnection) {
	h.mu.Lock()
	current, ok := h.agents[agentID]
	if ok && current == connection {
		delete(h.agents, agentID)
	}

	sessionIDs := make([]string, 0)
	for sessionID, session := range h.sessions {
		if session.AgentID == agentID {
			sessionIDs = append(sessionIDs, sessionID)
		}
	}
	h.mu.Unlock()

	for _, sessionID := range sessionIDs {
		h.CloseSession(sessionID, "Relay lost the connection to the Mac agent.", false)
	}
}

func (h *Hub) IsAgentOnline(agentID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	_, ok := h.agents[agentID]
	return ok
}

func (h *Hub) CreateSession(appID, agentID string, cols, rows int) (*Session, string, error) {
	token, err := newToken()
	if err != nil {
		return nil, "", err
	}

	session := &Session{
		ID:        uuid.NewString(),
		TokenHash: tokenHash(token),
		AppID:     appID,
		AgentID:   agentID,
		Cols:      cols,
		Rows:      rows,
		CreatedAt: time.Now().UTC(),
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	h.sessions[session.ID] = session
	return session, token, nil
}

func (h *Hub) AttachAppToSession(token string, conn *websocket.Conn) (*Session, *agentConnection, error) {
	hash := tokenHash(token)

	h.mu.Lock()
	defer h.mu.Unlock()

	for _, session := range h.sessions {
		if session.TokenHash != hash {
			continue
		}

		if session.AppSocket != nil {
			return nil, nil, errors.New("relay session already attached")
		}

		agent, ok := h.agents[session.AgentID]
		if !ok {
			delete(h.sessions, session.ID)
			return nil, nil, errors.New("relay agent is offline")
		}

		session.AppSocket = newWSPeer(conn)
		return cloneSession(session), agent, nil
	}

	return nil, nil, errors.New("relay session not found")
}

func (h *Hub) ForwardAgentEnvelope(agentID string, envelope relayEnvelope) {
	switch envelope.Type {
	case "heartbeat":
		if err := h.store.TouchAgent(agentID, time.Now().UTC()); err != nil {
			h.logger.Printf("touch agent heartbeat: %v", err)
		}
	case "session.ready", "session.output", "status":
		h.forwardToApp(envelope)
	case "error":
		h.forwardToApp(envelope)
		if envelope.SessionID != "" {
			h.CloseSession(envelope.SessionID, payloadMessage(envelope.Payload, "Relay session failed."), false)
		}
	case "session.closed":
		reason := payloadReason(envelope.Payload, "Relay closed the session.")
		h.CloseSession(envelope.SessionID, reason, false)
	}
}

func (h *Hub) ForwardAppEnvelope(sessionID string, envelope relayEnvelope) error {
	h.mu.RLock()
	session, ok := h.sessions[sessionID]
	if !ok {
		h.mu.RUnlock()
		return errors.New("relay session not found")
	}

	agent, ok := h.agents[session.AgentID]
	h.mu.RUnlock()
	if !ok {
		return errors.New("relay agent is offline")
	}

	return agent.Peer.WriteEnvelope(envelope)
}

func (h *Hub) forwardToApp(envelope relayEnvelope) {
	if envelope.SessionID == "" {
		return
	}

	h.mu.RLock()
	session, ok := h.sessions[envelope.SessionID]
	if !ok || session.AppSocket == nil {
		h.mu.RUnlock()
		return
	}
	appSocket := session.AppSocket
	h.mu.RUnlock()

	if err := appSocket.WriteEnvelope(envelope); err != nil {
		h.logger.Printf("forward to app: %v", err)
		h.CloseSession(envelope.SessionID, "Relay lost the app-side session connection.", true)
	}
}

func (h *Hub) SendSessionStart(session *Session) error {
	h.mu.RLock()
	agent, ok := h.agents[session.AgentID]
	h.mu.RUnlock()
	if !ok {
		return errors.New("relay agent is offline")
	}

	return agent.Peer.WriteEnvelope(relayEnvelope{
		Type:      "session.start",
		SessionID: session.ID,
		Payload: &relayPayload{
			Cols: session.Cols,
			Rows: session.Rows,
		},
	})
}

func (h *Hub) CloseSession(sessionID, reason string, notifyAgent bool) {
	if sessionID == "" {
		return
	}

	var (
		appSocket *wsPeer
		agent     *agentConnection
	)

	h.mu.Lock()
	session, ok := h.sessions[sessionID]
	if !ok {
		h.mu.Unlock()
		return
	}

	delete(h.sessions, sessionID)
	appSocket = session.AppSocket
	agent = h.agents[session.AgentID]
	h.mu.Unlock()

	if notifyAgent && agent != nil {
		_ = agent.Peer.WriteEnvelope(relayEnvelope{
			Type:      "session.close",
			SessionID: sessionID,
			Payload:   &relayPayload{Reason: "client_disconnect"},
		})
	}

	if appSocket != nil {
		_ = appSocket.WriteEnvelope(relayEnvelope{
			Type:      "session.closed",
			SessionID: sessionID,
			Payload:   &relayPayload{Reason: reason},
		})
		_ = appSocket.Close()
	}
}

func (h *Hub) cleanupExpired() {
	now := time.Now().UTC()

	h.mu.Lock()
	for code, pairing := range h.pairings {
		if now.After(pairing.ExpiresAt) {
			delete(h.pairings, code)
		}
	}

	sessionIDs := make([]string, 0)
	for sessionID, session := range h.sessions {
		if now.Sub(session.CreatedAt) > h.cfg.SessionTTL && session.AppSocket == nil {
			sessionIDs = append(sessionIDs, sessionID)
		}
	}
	h.mu.Unlock()

	for _, sessionID := range sessionIDs {
		h.CloseSession(sessionID, "Relay session expired before the app connected.", false)
	}
}

func (h *Hub) sessionWebSocketURL() string {
	return h.cfg.SessionWebSocketURL()
}

func (h *Hub) agentWebSocketURL() string {
	return h.cfg.AgentWebSocketURL()
}

func cloneSession(session *Session) *Session {
	if session == nil {
		return nil
	}
	copy := *session
	return &copy
}

func payloadMessage(payload *relayPayload, fallback string) string {
	if payload != nil && payload.Message != "" {
		return payload.Message
	}
	return fallback
}

func payloadReason(payload *relayPayload, fallback string) string {
	if payload != nil && payload.Reason != "" {
		return payload.Reason
	}
	return fallback
}

func checkWebSocketOrigin(publicURL *url.URL, r *http.Request) bool {
	originHeader := r.Header.Get("Origin")
	if originHeader == "" {
		return true
	}

	originURL, err := url.Parse(originHeader)
	if err != nil {
		return false
	}

	return stringsEqualFold(originURL.Host, publicURL.Host)
}

func stringsEqualFold(lhs, rhs string) bool {
	if len(lhs) != len(rhs) {
		return false
	}
	return equalFoldASCII(lhs, rhs)
}

func equalFoldASCII(lhs, rhs string) bool {
	for i := 0; i < len(lhs); i++ {
		lhsByte := lhs[i]
		rhsByte := rhs[i]
		if lhsByte|0x20 != rhsByte|0x20 && lhsByte != rhsByte {
			return false
		}
	}
	return true
}
