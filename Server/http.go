package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

type Server struct {
	cfg      Config
	store    *Store
	hub      *Hub
	logger   *log.Logger
	upgrader websocket.Upgrader
}

func NewServer(cfg Config, store *Store, hub *Hub, logger *log.Logger) *Server {
	server := &Server{
		cfg:    cfg,
		store:  store,
		hub:    hub,
		logger: logger,
	}

	server.upgrader = websocket.Upgrader{
		CheckOrigin: func(r *http.Request) bool {
			return checkWebSocketOrigin(cfg.PublicURL, r)
		},
	}

	return server
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.handleHealthz)
	mux.HandleFunc("POST /v1/app/bootstrap", s.handleBootstrapApp)
	mux.HandleFunc("POST /v1/pairings", s.handleCreatePairing)
	mux.HandleFunc("POST /v1/agent/pair", s.handlePairAgent)
	mux.HandleFunc("GET /v1/devices", s.handleListDevices)
	mux.HandleFunc("POST /v1/sessions", s.handleCreateSession)
	mux.HandleFunc("GET /v1/ws/agent", s.handleAgentWebSocket)
	mux.HandleFunc("GET /v1/ws/session", s.handleSessionWebSocket)
	return loggingMiddleware(s.logger, mux)
}

func (s *Server) handleHealthz(writer http.ResponseWriter, _ *http.Request) {
	writeJSON(writer, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleBootstrapApp(writer http.ResponseWriter, request *http.Request) {
	var payload appBootstrapRequest
	if err := decodeJSON(request, &payload); err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}

	name := strings.TrimSpace(payload.DeviceName)
	if name == "" {
		writeError(writer, http.StatusBadRequest, errors.New("device_name is required"))
		return
	}

	record, token, err := s.store.CreateApp(name)
	if err != nil {
		writeError(writer, http.StatusInternalServerError, err)
		return
	}

	writeJSON(writer, http.StatusCreated, appBootstrapResponse{
		AppID:     record.ID,
		AppToken:  token,
		CreatedAt: record.CreatedAt,
	})
}

func (s *Server) handleCreatePairing(writer http.ResponseWriter, request *http.Request) {
	app, err := s.appFromRequest(request)
	if err != nil {
		writeError(writer, http.StatusUnauthorized, err)
		return
	}

	pairing, err := s.hub.CreatePairing(app.ID)
	if err != nil {
		writeError(writer, http.StatusInternalServerError, err)
		return
	}

	writeJSON(writer, http.StatusCreated, pairingResponse{
		Code:      pairing.Code,
		ExpiresAt: pairing.ExpiresAt,
	})
}

func (s *Server) handlePairAgent(writer http.ResponseWriter, request *http.Request) {
	var payload agentPairRequest
	if err := decodeJSON(request, &payload); err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}

	if strings.TrimSpace(payload.Code) == "" {
		writeError(writer, http.StatusBadRequest, errors.New("code is required"))
		return
	}

	deviceName := strings.TrimSpace(payload.DeviceName)
	if deviceName == "" {
		writeError(writer, http.StatusBadRequest, errors.New("device_name is required"))
		return
	}

	platform := strings.TrimSpace(payload.Platform)
	if platform == "" {
		platform = "macOS"
	}

	app, err := s.hub.ConsumePairing(strings.ToUpper(payload.Code))
	if err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}

	record, token, err := s.store.CreateAgent(app.ID, deviceName, platform)
	if err != nil {
		writeError(writer, http.StatusInternalServerError, err)
		return
	}

	writeJSON(writer, http.StatusCreated, agentPairResponse{
		AgentID:          record.ID,
		AgentToken:       token,
		ServerURL:        s.cfg.PublicURL.String(),
		WebSocketURL:     s.hub.agentWebSocketURL(),
		AllowInsecureTLS: false,
		AppOwnerName:     app.Name,
		RegisteredAppID:  app.ID,
	})
}

func (s *Server) handleListDevices(writer http.ResponseWriter, request *http.Request) {
	app, err := s.appFromRequest(request)
	if err != nil {
		writeError(writer, http.StatusUnauthorized, err)
		return
	}

	agents := s.store.ListAgentsForApp(app.ID)
	response := make([]pairedDeviceResponse, 0, len(agents))
	for _, agent := range agents {
		response = append(response, pairedDeviceResponse{
			ID:         agent.ID,
			Name:       agent.Name,
			OwnerName:  app.Name,
			Platform:   agent.Platform,
			Online:     s.hub.IsAgentOnline(agent.ID),
			LastSeenAt: agent.LastSeenAt,
		})
	}

	writeJSON(writer, http.StatusOK, response)
}

func (s *Server) handleCreateSession(writer http.ResponseWriter, request *http.Request) {
	app, err := s.appFromRequest(request)
	if err != nil {
		writeError(writer, http.StatusUnauthorized, err)
		return
	}

	var payload createSessionRequest
	if err := decodeJSON(request, &payload); err != nil {
		writeError(writer, http.StatusBadRequest, err)
		return
	}

	agentID := strings.TrimSpace(payload.DeviceID)
	if agentID == "" {
		writeError(writer, http.StatusBadRequest, errors.New("device_id is required"))
		return
	}

	agent, ok := s.store.AgentByID(agentID)
	if !ok || agent.AppID != app.ID {
		writeError(writer, http.StatusNotFound, errors.New("paired device not found"))
		return
	}

	if !s.hub.IsAgentOnline(agent.ID) {
		writeError(writer, http.StatusConflict, errors.New("the selected Mac agent is offline"))
		return
	}

	cols := payload.Cols
	rows := payload.Rows
	if cols <= 0 {
		cols = 80
	}
	if rows <= 0 {
		rows = 24
	}

	session, token, err := s.hub.CreateSession(app.ID, agent.ID, cols, rows)
	if err != nil {
		writeError(writer, http.StatusInternalServerError, err)
		return
	}

	writeJSON(writer, http.StatusCreated, createSessionResponse{
		SessionID:    session.ID,
		WebSocketURL: s.hub.sessionWebSocketURL(),
		SessionToken: token,
	})
}

func (s *Server) handleAgentWebSocket(writer http.ResponseWriter, request *http.Request) {
	token := strings.TrimSpace(request.URL.Query().Get("agent_token"))
	if token == "" {
		writeError(writer, http.StatusUnauthorized, errors.New("agent_token is required"))
		return
	}

	agent, ok := s.store.FindAgentByToken(token)
	if !ok {
		writeError(writer, http.StatusUnauthorized, errors.New("invalid agent token"))
		return
	}

	conn, err := s.upgrader.Upgrade(writer, request, nil)
	if err != nil {
		s.logger.Printf("upgrade agent websocket: %v", err)
		return
	}

	connection := s.hub.RegisterAgentConnection(agent, conn)
	_ = s.store.TouchAgent(agent.ID, time.Now().UTC())
	s.logger.Printf("agent connected: %s (%s)", agent.Name, agent.ID)

	defer func() {
		s.hub.UnregisterAgentConnection(agent.ID, connection)
		_ = connection.Peer.Close()
		s.logger.Printf("agent disconnected: %s (%s)", agent.Name, agent.ID)
	}()

	for {
		var envelope relayEnvelope
		if err := conn.ReadJSON(&envelope); err != nil {
			return
		}
		s.hub.ForwardAgentEnvelope(agent.ID, envelope)
	}
}

func (s *Server) handleSessionWebSocket(writer http.ResponseWriter, request *http.Request) {
	token := strings.TrimSpace(request.URL.Query().Get("session_token"))
	if token == "" {
		writeError(writer, http.StatusUnauthorized, errors.New("session_token is required"))
		return
	}

	conn, err := s.upgrader.Upgrade(writer, request, nil)
	if err != nil {
		s.logger.Printf("upgrade session websocket: %v", err)
		return
	}

	session, _, err := s.hub.AttachAppToSession(token, conn)
	if err != nil {
		_ = conn.WriteJSON(relayEnvelope{
			Type: "error",
			Payload: &relayPayload{
				Message: err.Error(),
			},
		})
		_ = conn.Close()
		return
	}

	s.logger.Printf("app attached to session %s", session.ID)

	if err := session.AppSocket.WriteEnvelope(relayEnvelope{
		Type:      "session.waiting",
		SessionID: session.ID,
		Payload:   &relayPayload{Message: "Waiting for the Mac agent to start a shell..."},
	}); err != nil {
		s.hub.CloseSession(session.ID, "Relay could not attach the terminal session.", true)
		return
	}

	if err := s.hub.SendSessionStart(session); err != nil {
		s.hub.CloseSession(session.ID, err.Error(), false)
		return
	}

	defer s.hub.CloseSession(session.ID, "Relay disconnected the terminal session.", true)

	for {
		var envelope relayEnvelope
		if err := conn.ReadJSON(&envelope); err != nil {
			return
		}

		envelope.SessionID = session.ID
		switch envelope.Type {
		case "session.input", "session.resize":
			if err := s.hub.ForwardAppEnvelope(session.ID, envelope); err != nil {
				s.hub.CloseSession(session.ID, err.Error(), false)
				return
			}
		case "session.close":
			return
		default:
			_ = session.AppSocket.WriteEnvelope(relayEnvelope{
				Type:      "error",
				SessionID: session.ID,
				Payload:   &relayPayload{Message: fmt.Sprintf("unsupported relay message: %s", envelope.Type)},
			})
		}
	}
}

func (s *Server) appFromRequest(request *http.Request) (*AppRecord, error) {
	token, err := bearerToken(request)
	if err != nil {
		return nil, err
	}

	app, ok := s.store.FindAppByToken(token)
	if !ok {
		return nil, errors.New("invalid app token")
	}
	return app, nil
}

func decodeJSON(request *http.Request, target any) error {
	defer request.Body.Close()

	decoder := json.NewDecoder(request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return fmt.Errorf("decode request: %w", err)
	}
	return nil
}

func writeJSON(writer http.ResponseWriter, status int, payload any) {
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(status)
	if err := json.NewEncoder(writer).Encode(payload); err != nil {
		http.Error(writer, err.Error(), http.StatusInternalServerError)
	}
}

func writeError(writer http.ResponseWriter, status int, err error) {
	writeJSON(writer, status, relayErrorResponse{Error: err.Error()})
}

func loggingMiddleware(logger *log.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		startedAt := time.Now()
		next.ServeHTTP(writer, request)
		logger.Printf("%s %s %s", request.Method, request.URL.Path, time.Since(startedAt).Round(time.Millisecond))
	})
}
