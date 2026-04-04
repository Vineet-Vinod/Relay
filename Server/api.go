package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type APIServer struct {
	cfg    AppConfig
	store  *PeerStore
	wg     *WireGuardManager
	logger *log.Logger
}

type registerRequest struct {
	UserID    string `json:"user_id"`
	PublicKey string `json:"public_key"`
}

type registerResponse struct {
	AssignedIP          string `json:"assigned_ip"`
	ServerPublicKey     string `json:"server_public_key"`
	ServerEndpoint      string `json:"server_endpoint"`
	PersistentKeepalive int    `json:"persistent_keepalive"`
}

type peerResponse struct {
	UserID        string `json:"user_id"`
	AssignedIP    string `json:"assigned_ip"`
	LastHandshake string `json:"last_handshake"`
	LastSeen      string `json:"last_seen"`
	Online        bool   `json:"online"`
}

type errorResponse struct {
	Error string `json:"error"`
}

func NewAPIServer(cfg AppConfig, store *PeerStore, wg *WireGuardManager, logger *log.Logger) *APIServer {
	return &APIServer{
		cfg:    cfg,
		store:  store,
		wg:     wg,
		logger: logger,
	}
}

func (s *APIServer) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealth)
	mux.HandleFunc("/register", s.handleRegister)
	mux.HandleFunc("/peers", s.handlePeers)
	mux.HandleFunc("/config/", s.handleConfig)
	return mux
}

func (s *APIServer) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeMethodNotAllowed(w, http.MethodGet)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *APIServer) handleRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeMethodNotAllowed(w, http.MethodPost)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 8*1024)
	defer r.Body.Close()

	var req registerRequest
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("invalid JSON body: %v", err))
		return
	}

	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		writeError(w, http.StatusBadRequest, "request body must contain a single JSON object")
		return
	}

	peer, err := s.store.Register(req.UserID, req.PublicKey)
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, ErrDuplicateUserID) || errors.Is(err, ErrDuplicatePublicKey) {
			status = http.StatusConflict
		}
		writeError(w, status, err.Error())
		return
	}

	if err := s.wg.EnsurePeer(peer); err != nil {
		s.store.Delete(peer.UserID)
		_ = s.wg.RemovePeer(peer.PublicKey)
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("add peer to wireguard: %v", err))
		return
	}

	s.logger.Printf("registered user_id=%s assigned_ip=%s public_key=%s", peer.UserID, peer.AssignedIP, peer.PublicKey)

	writeJSON(w, http.StatusCreated, registerResponse{
		AssignedIP:          peer.AssignedIP,
		ServerPublicKey:     s.wg.PublicKey(),
		ServerEndpoint:      s.cfg.ServerEndpoint,
		PersistentKeepalive: s.cfg.PersistentKeepalive,
	})
}

func (s *APIServer) handlePeers(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeMethodNotAllowed(w, http.MethodGet)
		return
	}

	peers := s.store.List()
	response := make([]peerResponse, 0, len(peers))
	for _, peer := range peers {
		response = append(response, peerResponse{
			UserID:        peer.UserID,
			AssignedIP:    peer.AssignedIP,
			LastHandshake: formatTimestamp(peer.LastHandshake),
			LastSeen:      formatTimestamp(peer.LastSeen),
			Online:        peer.Online,
		})
	}

	writeJSON(w, http.StatusOK, response)
}

func (s *APIServer) handleConfig(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeMethodNotAllowed(w, http.MethodGet)
		return
	}

	userID, err := userIDFromPath(r.URL.Path)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}

	peer, ok := s.store.Get(userID)
	if !ok {
		writeError(w, http.StatusNotFound, "peer not found")
		return
	}

	config := buildClientConfig(peer.AssignedIP, s.cfg.ClientAddressMaskBits, s.wg.PublicKey(), s.cfg.ServerEndpoint, s.cfg.PersistentKeepalive)
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, config)
}

func userIDFromPath(path string) (string, error) {
	if !strings.HasPrefix(path, "/config/") {
		return "", errors.New("route not found")
	}

	rawUserID := strings.TrimPrefix(path, "/config/")
	if rawUserID == "" || strings.Contains(rawUserID, "/") {
		return "", errors.New("route not found")
	}

	userID, err := url.PathUnescape(rawUserID)
	if err != nil {
		return "", fmt.Errorf("decode user_id: %w", err)
	}

	return userID, nil
}

func buildClientConfig(assignedIP string, maskBits int, serverPublicKey, serverEndpoint string, keepalive int) string {
	return fmt.Sprintf(
		"[Interface]\n# Generate on the client with: wg genkey\nPrivateKey = REPLACE_WITH_CLIENT_PRIVATE_KEY\nAddress = %s/%d\n\n[Peer]\nPublicKey = %s\nEndpoint = %s\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = %d\n",
		assignedIP,
		maskBits,
		serverPublicKey,
		serverEndpoint,
		keepalive,
	)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, errorResponse{Error: message})
}

func writeMethodNotAllowed(w http.ResponseWriter, allow string) {
	w.Header().Set("Allow", allow)
	writeError(w, http.StatusMethodNotAllowed, "method not allowed")
}

func formatTimestamp(value time.Time) string {
	if value.IsZero() {
		return ""
	}
	return value.UTC().Format(time.RFC3339)
}
