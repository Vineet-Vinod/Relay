package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type Runner struct {
	cfg        AgentConfig
	logger     *log.Logger
	writeMu    sync.Mutex
	sessionsMu sync.RWMutex
	sessions   map[string]*shellSession
	conn       *websocket.Conn
}

func NewRunner(cfg AgentConfig, logger *log.Logger) *Runner {
	return &Runner{
		cfg:      cfg,
		logger:   logger,
		sessions: map[string]*shellSession{},
	}
}

func (r *Runner) Run(ctx context.Context) error {
	backoff := time.Second

	for {
		err := r.runOnce(ctx)
		if ctx.Err() != nil {
			return nil
		}

		r.logger.Printf("relay agent disconnected: %v", err)

		select {
		case <-time.After(backoff):
		case <-ctx.Done():
			return nil
		}

		if backoff < 15*time.Second {
			backoff *= 2
		}
	}
}

func (r *Runner) runOnce(ctx context.Context) error {
	webSocketURL, err := agentWebSocketURL(r.cfg.ServerURL, r.cfg.AgentToken)
	if err != nil {
		return err
	}

	dialer := websocket.Dialer{
		HandshakeTimeout: 10 * time.Second,
		TLSClientConfig: &tls.Config{
			MinVersion:         tls.VersionTLS12,
			InsecureSkipVerify: r.cfg.AllowInsecureTLS,
		},
	}

	conn, _, err := dialer.DialContext(ctx, webSocketURL, nil)
	if err != nil {
		return fmt.Errorf("dial relay server: %w", err)
	}

	r.logger.Printf("connected to %s", webSocketURL)
	r.conn = conn
	done := make(chan struct{})
	defer func() {
		close(done)
		r.conn = nil
		_ = conn.Close()
		r.closeAllSessions("Relay disconnected the agent.")
	}()

	heartbeatTicker := time.NewTicker(20 * time.Second)
	defer heartbeatTicker.Stop()

	go func() {
		for {
			select {
			case <-heartbeatTicker.C:
				_ = r.writeEnvelope(relayEnvelope{Type: "heartbeat"})
			case <-done:
				return
			case <-ctx.Done():
				return
			}
		}
	}()

	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			return err
		}

		var envelope relayEnvelope
		if err := json.Unmarshal(data, &envelope); err != nil {
			r.logger.Printf("decode server envelope: %v", err)
			continue
		}

		if err := r.handleEnvelope(envelope); err != nil {
			r.logger.Printf("handle server envelope: %v", err)
			if envelope.SessionID != "" {
				r.closeSession(envelope.SessionID, err.Error())
			}
		}
	}
}

func (r *Runner) handleEnvelope(envelope relayEnvelope) error {
	switch envelope.Type {
	case "session.start":
		cols := 80
		rows := 24
		if envelope.Payload != nil {
			if envelope.Payload.Cols > 0 {
				cols = envelope.Payload.Cols
			}
			if envelope.Payload.Rows > 0 {
				rows = envelope.Payload.Rows
			}
		}
		return r.startShellSession(envelope.SessionID, cols, rows)
	case "session.input":
		if envelope.Payload == nil {
			return fmt.Errorf("missing session input payload")
		}
		return r.writeInput(envelope.SessionID, envelope.Payload.DataBase64)
	case "session.resize":
		if envelope.Payload == nil {
			return fmt.Errorf("missing session resize payload")
		}
		return r.resizeSession(envelope.SessionID, envelope.Payload.Cols, envelope.Payload.Rows)
	case "session.close":
		r.closeSession(envelope.SessionID, payloadReason(envelope.Payload, "Relay closed the session."))
		return nil
	default:
		return fmt.Errorf("unsupported relay envelope type: %s", envelope.Type)
	}
}

func (r *Runner) writeEnvelope(envelope relayEnvelope) error {
	if r.conn == nil {
		return fmt.Errorf("relay websocket is not connected")
	}

	r.writeMu.Lock()
	defer r.writeMu.Unlock()
	return r.conn.WriteJSON(envelope)
}

func (r *Runner) closeAllSessions(reason string) {
	r.sessionsMu.RLock()
	sessionIDs := make([]string, 0, len(r.sessions))
	for sessionID := range r.sessions {
		sessionIDs = append(sessionIDs, sessionID)
	}
	r.sessionsMu.RUnlock()

	for _, sessionID := range sessionIDs {
		r.closeSession(sessionID, reason)
	}
}

func httpClient(allowInsecureTLS bool) *http.Client {
	return &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				MinVersion:         tls.VersionTLS12,
				InsecureSkipVerify: allowInsecureTLS,
			},
		},
	}
}
