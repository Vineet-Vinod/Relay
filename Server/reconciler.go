package main

import (
	"context"
	"log"
	"time"
)

type Reconciler struct {
	store     *PeerStore
	wg        *WireGuardManager
	logger    *log.Logger
	interval  time.Duration
	keepalive int
}

func NewReconciler(store *PeerStore, wg *WireGuardManager, logger *log.Logger, interval time.Duration, keepalive int) *Reconciler {
	return &Reconciler{
		store:     store,
		wg:        wg,
		logger:    logger,
		interval:  interval,
		keepalive: keepalive,
	}
}

func (r *Reconciler) Start(ctx context.Context) {
	r.runOnce()

	ticker := time.NewTicker(r.interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			r.runOnce()
		}
	}
}

func (r *Reconciler) runOnce() {
	if err := r.wg.EnsureInterfaceUp(); err != nil {
		r.logger.Printf("reconciler could not ensure interface: %v", err)
		return
	}

	current, err := r.wg.DumpPeerStates()
	if err != nil {
		r.logger.Printf("reconciler could not dump peers: %v", err)
		return
	}

	desired := r.store.SnapshotByPublicKey()
	for publicKey, peer := range desired {
		state, ok := current[publicKey]
		if !ok || !state.HasAllowedIP(peer.AssignedIP+"/32") || state.PersistentKeepalive != r.keepalive {
			if err := r.wg.EnsurePeer(peer); err != nil {
				r.logger.Printf("reconciler failed to ensure peer %s: %v", peer.UserID, err)
			}
		}
	}

	for publicKey := range current {
		if _, ok := desired[publicKey]; ok {
			continue
		}
		if err := r.wg.RemovePeer(publicKey); err != nil {
			r.logger.Printf("reconciler failed to remove unmanaged peer %s: %v", publicKey, err)
		}
	}
}
