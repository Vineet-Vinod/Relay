package main

import "time"

type AppRecord struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	TokenHash string    `json:"token_hash"`
	CreatedAt time.Time `json:"created_at"`
}

type AgentRecord struct {
	ID         string     `json:"id"`
	AppID      string     `json:"app_id"`
	Name       string     `json:"name"`
	Platform   string     `json:"platform"`
	TokenHash  string     `json:"token_hash"`
	CreatedAt  time.Time  `json:"created_at"`
	LastSeenAt *time.Time `json:"last_seen_at,omitempty"`
}

type persistentState struct {
	Apps   map[string]*AppRecord   `json:"apps"`
	Agents map[string]*AgentRecord `json:"agents"`
}

type relayErrorResponse struct {
	Error string `json:"error"`
}

type appBootstrapRequest struct {
	DeviceName string `json:"device_name"`
}

type appBootstrapResponse struct {
	AppID     string    `json:"app_id"`
	AppToken  string    `json:"app_token"`
	CreatedAt time.Time `json:"created_at"`
}

type pairingResponse struct {
	Code      string    `json:"code"`
	ExpiresAt time.Time `json:"expires_at"`
}

type agentPairRequest struct {
	Code       string `json:"code"`
	DeviceName string `json:"device_name"`
	Platform   string `json:"platform"`
}

type agentPairResponse struct {
	AgentID          string `json:"agent_id"`
	AgentToken       string `json:"agent_token"`
	ServerURL        string `json:"server_url"`
	WebSocketURL     string `json:"websocket_url"`
	AllowInsecureTLS bool   `json:"allow_insecure_tls"`
	AppOwnerName     string `json:"app_owner_name"`
	RegisteredAppID  string `json:"registered_app_id"`
}

type pairedDeviceResponse struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	OwnerName  string     `json:"owner_name"`
	Platform   string     `json:"platform"`
	Online     bool       `json:"online"`
	LastSeenAt *time.Time `json:"last_seen_at,omitempty"`
}

type createSessionRequest struct {
	DeviceID string `json:"device_id"`
	Cols     int    `json:"cols"`
	Rows     int    `json:"rows"`
}

type createSessionResponse struct {
	SessionID    string `json:"session_id"`
	WebSocketURL string `json:"websocket_url"`
	SessionToken string `json:"session_token"`
}

type relayEnvelope struct {
	Type      string        `json:"type"`
	SessionID string        `json:"session_id,omitempty"`
	Payload   *relayPayload `json:"payload,omitempty"`
}

type relayPayload struct {
	Message    string `json:"message,omitempty"`
	DataBase64 string `json:"data_base64,omitempty"`
	Cols       int    `json:"cols,omitempty"`
	Rows       int    `json:"rows,omitempty"`
	Reason     string `json:"reason,omitempty"`
}
