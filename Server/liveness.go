package main

import (
	"context"
	"log"
	"time"
)

type LivenessMonitor struct {
	store        *PeerStore
	wg           *WireGuardManager
	logger       *log.Logger
	interval     time.Duration
	onlineWindow time.Duration
}

func NewLivenessMonitor(store *PeerStore, wg *WireGuardManager, logger *log.Logger, interval, onlineWindow time.Duration) *LivenessMonitor {
	return &LivenessMonitor{
		store:        store,
		wg:           wg,
		logger:       logger,
		interval:     interval,
		onlineWindow: onlineWindow,
	}
}

func (m *LivenessMonitor) Start(ctx context.Context) {
	m.runOnce()

	ticker := time.NewTicker(m.interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.runOnce()
		}
	}
}

func (m *LivenessMonitor) runOnce() {
	peerStates, err := m.wg.DumpPeerStates()
	if err != nil {
		m.logger.Printf("liveness check failed: %v", err)
		return
	}

	handshakes := make(map[string]time.Time, len(peerStates))
	for publicKey, state := range peerStates {
		if !state.LatestHandshake.IsZero() {
			handshakes[publicKey] = state.LatestHandshake
		}
	}

	m.store.UpdateLiveness(handshakes, time.Now().UTC(), m.onlineWindow)
}
