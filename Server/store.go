package main

import (
	"encoding/base64"
	"errors"
	"fmt"
	"net/netip"
	"regexp"
	"sort"
	"sync"
	"time"
)

var (
	ErrDuplicateUserID    = errors.New("user_id already registered")
	ErrDuplicatePublicKey = errors.New("public_key already registered")
)

var userIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

type Peer struct {
	UserID        string
	PublicKey     string
	AssignedIP    string
	LastHandshake time.Time
	LastSeen      time.Time
	Online        bool
}

type PeerStore struct {
	mu               sync.RWMutex
	network          netip.Prefix
	serverIP         netip.Addr
	nextHost         uint8
	peersByUser      map[string]*Peer
	userByPublicKey  map[string]string
	userByAssignedIP map[string]string
}

func NewPeerStore(networkCIDR, serverIP string) (*PeerStore, error) {
	network, err := netip.ParsePrefix(networkCIDR)
	if err != nil {
		return nil, fmt.Errorf("parse network CIDR: %w", err)
	}
	if !network.Addr().Is4() || network.Bits() != 24 {
		return nil, fmt.Errorf("peer store only supports IPv4 /24 networks")
	}

	serverAddress, err := netip.ParseAddr(serverIP)
	if err != nil {
		return nil, fmt.Errorf("parse server IP: %w", err)
	}
	if !network.Contains(serverAddress) {
		return nil, fmt.Errorf("server IP %s is not in network %s", serverIP, networkCIDR)
	}

	return &PeerStore{
		network:          network.Masked(),
		serverIP:         serverAddress,
		nextHost:         2,
		peersByUser:      make(map[string]*Peer),
		userByPublicKey:  make(map[string]string),
		userByAssignedIP: make(map[string]string),
	}, nil
}

func (s *PeerStore) Register(userID, publicKey string) (Peer, error) {
	if err := validateUserID(userID); err != nil {
		return Peer{}, err
	}
	if err := validatePublicKey(publicKey); err != nil {
		return Peer{}, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.peersByUser[userID]; exists {
		return Peer{}, ErrDuplicateUserID
	}
	if _, exists := s.userByPublicKey[publicKey]; exists {
		return Peer{}, ErrDuplicatePublicKey
	}

	assignedIP, err := s.nextAvailableIPLocked()
	if err != nil {
		return Peer{}, err
	}

	peer := &Peer{
		UserID:     userID,
		PublicKey:  publicKey,
		AssignedIP: assignedIP.String(),
	}

	s.peersByUser[userID] = peer
	s.userByPublicKey[publicKey] = userID
	s.userByAssignedIP[peer.AssignedIP] = userID

	return clonePeer(peer), nil
}

func (s *PeerStore) Delete(userID string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	peer, ok := s.peersByUser[userID]
	if !ok {
		return
	}

	delete(s.peersByUser, userID)
	delete(s.userByPublicKey, peer.PublicKey)
	delete(s.userByAssignedIP, peer.AssignedIP)
}

func (s *PeerStore) Get(userID string) (Peer, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	peer, ok := s.peersByUser[userID]
	if !ok {
		return Peer{}, false
	}
	return clonePeer(peer), true
}

func (s *PeerStore) List() []Peer {
	s.mu.RLock()
	defer s.mu.RUnlock()

	peers := make([]Peer, 0, len(s.peersByUser))
	for _, peer := range s.peersByUser {
		peers = append(peers, clonePeer(peer))
	}

	sort.Slice(peers, func(i, j int) bool {
		return peers[i].UserID < peers[j].UserID
	})

	return peers
}

func (s *PeerStore) SnapshotByPublicKey() map[string]Peer {
	s.mu.RLock()
	defer s.mu.RUnlock()

	result := make(map[string]Peer, len(s.userByPublicKey))
	for publicKey, userID := range s.userByPublicKey {
		result[publicKey] = clonePeer(s.peersByUser[userID])
	}
	return result
}

func (s *PeerStore) UpdateLiveness(handshakes map[string]time.Time, observedAt time.Time, onlineWindow time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()

	for _, peer := range s.peersByUser {
		handshake, ok := handshakes[peer.PublicKey]
		if ok && !handshake.IsZero() {
			peer.LastHandshake = handshake.UTC()
			if observedAt.Sub(handshake) < onlineWindow {
				peer.LastSeen = observedAt.UTC()
				peer.Online = true
				continue
			}
		}
		peer.Online = false
	}
}

func (s *PeerStore) nextAvailableIPLocked() (netip.Addr, error) {
	base := s.network.Addr().As4()

	for attempt := 0; attempt < 253; attempt++ {
		host := 2 + ((int(s.nextHost) - 2 + attempt) % 253)

		candidateBytes := base
		candidateBytes[3] = byte(host)
		candidate := netip.AddrFrom4(candidateBytes)

		if candidate == s.serverIP {
			continue
		}
		if _, inUse := s.userByAssignedIP[candidate.String()]; inUse {
			continue
		}

		s.nextHost = byte(host + 1)
		if s.nextHost > 254 {
			s.nextHost = 2
		}

		return candidate, nil
	}

	return netip.Addr{}, fmt.Errorf("no addresses available in %s", s.network.String())
}

func clonePeer(peer *Peer) Peer {
	if peer == nil {
		return Peer{}
	}
	return Peer{
		UserID:        peer.UserID,
		PublicKey:     peer.PublicKey,
		AssignedIP:    peer.AssignedIP,
		LastHandshake: peer.LastHandshake,
		LastSeen:      peer.LastSeen,
		Online:        peer.Online,
	}
}

func validateUserID(userID string) error {
	if !userIDPattern.MatchString(userID) {
		return fmt.Errorf("user_id must match %s", userIDPattern.String())
	}
	return nil
}

func validatePublicKey(publicKey string) error {
	decoded, err := base64.StdEncoding.DecodeString(publicKey)
	if err != nil {
		return fmt.Errorf("public_key must be valid base64: %w", err)
	}
	if len(decoded) != 32 {
		return fmt.Errorf("public_key must decode to 32 bytes")
	}
	return nil
}
