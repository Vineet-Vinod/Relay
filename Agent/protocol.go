package main

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

type agentPairRequest struct {
	Code       string `json:"code"`
	DeviceName string `json:"device_name"`
	Platform   string `json:"platform"`
}

func payloadReason(payload *relayPayload, fallback string) string {
	if payload != nil && payload.Reason != "" {
		return payload.Reason
	}
	return fallback
}
