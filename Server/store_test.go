package main

import (
	"encoding/base64"
	"testing"
	"time"
)

func TestRegisterAssignsSequentialAddresses(t *testing.T) {
	store, err := NewPeerStore("10.0.0.0/24", "10.0.0.1")
	if err != nil {
		t.Fatalf("NewPeerStore() error = %v", err)
	}

	first, err := store.Register("alpha", validPublicKey(1))
	if err != nil {
		t.Fatalf("Register(alpha) error = %v", err)
	}

	second, err := store.Register("beta", validPublicKey(2))
	if err != nil {
		t.Fatalf("Register(beta) error = %v", err)
	}

	if first.AssignedIP != "10.0.0.2" {
		t.Fatalf("first assigned IP = %s, want 10.0.0.2", first.AssignedIP)
	}
	if second.AssignedIP != "10.0.0.3" {
		t.Fatalf("second assigned IP = %s, want 10.0.0.3", second.AssignedIP)
	}
}

func TestRegisterRejectsDuplicates(t *testing.T) {
	store, err := NewPeerStore("10.0.0.0/24", "10.0.0.1")
	if err != nil {
		t.Fatalf("NewPeerStore() error = %v", err)
	}

	key := validPublicKey(10)
	if _, err := store.Register("alpha", key); err != nil {
		t.Fatalf("Register(alpha) error = %v", err)
	}

	if _, err := store.Register("alpha", validPublicKey(11)); err != ErrDuplicateUserID {
		t.Fatalf("duplicate user_id error = %v, want %v", err, ErrDuplicateUserID)
	}

	if _, err := store.Register("beta", key); err != ErrDuplicatePublicKey {
		t.Fatalf("duplicate public_key error = %v, want %v", err, ErrDuplicatePublicKey)
	}
}

func TestUpdateLivenessMarksRecentPeersOnline(t *testing.T) {
	store, err := NewPeerStore("10.0.0.0/24", "10.0.0.1")
	if err != nil {
		t.Fatalf("NewPeerStore() error = %v", err)
	}

	peer, err := store.Register("alpha", validPublicKey(20))
	if err != nil {
		t.Fatalf("Register(alpha) error = %v", err)
	}

	observedAt := time.Date(2026, 4, 4, 18, 0, 0, 0, time.UTC)
	handshake := observedAt.Add(-30 * time.Second)

	store.UpdateLiveness(map[string]time.Time{
		peer.PublicKey: handshake,
	}, observedAt, 2*time.Minute)

	current, ok := store.Get("alpha")
	if !ok {
		t.Fatal("expected alpha to be present")
	}
	if !current.Online {
		t.Fatal("expected alpha to be online")
	}
	if !current.LastHandshake.Equal(handshake) {
		t.Fatalf("last handshake = %v, want %v", current.LastHandshake, handshake)
	}
	if !current.LastSeen.Equal(observedAt) {
		t.Fatalf("last seen = %v, want %v", current.LastSeen, observedAt)
	}
}

func validPublicKey(seed byte) string {
	key := make([]byte, 32)
	for i := range key {
		key[i] = seed + byte(i)
	}
	return base64.StdEncoding.EncodeToString(key)
}
