package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"

	"github.com/google/uuid"
)

type Store struct {
	mu    sync.RWMutex
	path  string
	state persistentState
}

func NewStore(path string) (*Store, error) {
	store := &Store{
		path: path,
		state: persistentState{
			Apps:   map[string]*AppRecord{},
			Agents: map[string]*AgentRecord{},
		},
	}

	if err := store.load(); err != nil {
		return nil, err
	}

	return store, nil
}

func (s *Store) CreateApp(name string) (*AppRecord, string, error) {
	token, err := newToken()
	if err != nil {
		return nil, "", err
	}

	now := time.Now().UTC()
	record := &AppRecord{
		ID:        uuid.NewString(),
		Name:      name,
		TokenHash: tokenHash(token),
		CreatedAt: now,
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.state.Apps[record.ID] = record
	if err := s.persistLocked(); err != nil {
		delete(s.state.Apps, record.ID)
		return nil, "", err
	}
	return cloneApp(record), token, nil
}

func (s *Store) FindAppByToken(token string) (*AppRecord, bool) {
	hash := tokenHash(token)

	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, record := range s.state.Apps {
		if record.TokenHash == hash {
			return cloneApp(record), true
		}
	}
	return nil, false
}

func (s *Store) AppByID(id string) (*AppRecord, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	record, ok := s.state.Apps[id]
	if !ok {
		return nil, false
	}
	return cloneApp(record), true
}

func (s *Store) CreateAgent(appID, name, platform string) (*AgentRecord, string, error) {
	token, err := newToken()
	if err != nil {
		return nil, "", err
	}

	now := time.Now().UTC()
	record := &AgentRecord{
		ID:        uuid.NewString(),
		AppID:     appID,
		Name:      name,
		Platform:  platform,
		TokenHash: tokenHash(token),
		CreatedAt: now,
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.state.Agents[record.ID] = record
	if err := s.persistLocked(); err != nil {
		delete(s.state.Agents, record.ID)
		return nil, "", err
	}
	return cloneAgent(record), token, nil
}

func (s *Store) FindAgentByToken(token string) (*AgentRecord, bool) {
	hash := tokenHash(token)

	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, record := range s.state.Agents {
		if record.TokenHash == hash {
			return cloneAgent(record), true
		}
	}
	return nil, false
}

func (s *Store) AgentByID(id string) (*AgentRecord, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	record, ok := s.state.Agents[id]
	if !ok {
		return nil, false
	}
	return cloneAgent(record), true
}

func (s *Store) ListAgentsForApp(appID string) []*AgentRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()

	agents := make([]*AgentRecord, 0, len(s.state.Agents))
	for _, record := range s.state.Agents {
		if record.AppID == appID {
			agents = append(agents, cloneAgent(record))
		}
	}

	slices.SortFunc(agents, func(lhs, rhs *AgentRecord) int {
		if lhs.Name == rhs.Name {
			return stringsCompare(lhs.ID, rhs.ID)
		}
		return stringsCompare(lhs.Name, rhs.Name)
	})

	return agents
}

func (s *Store) TouchAgent(agentID string, seenAt time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	record, ok := s.state.Agents[agentID]
	if !ok {
		return errors.New("agent not found")
	}

	timestamp := seenAt.UTC()
	record.LastSeenAt = &timestamp
	return s.persistLocked()
}

func (s *Store) load() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return fmt.Errorf("create store directory: %w", err)
	}

	data, err := os.ReadFile(s.path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("read store: %w", err)
	}

	if len(data) == 0 {
		return nil
	}

	var state persistentState
	if err := json.Unmarshal(data, &state); err != nil {
		return fmt.Errorf("decode store: %w", err)
	}

	if state.Apps == nil {
		state.Apps = map[string]*AppRecord{}
	}
	if state.Agents == nil {
		state.Agents = map[string]*AgentRecord{}
	}

	s.state = state
	return nil
}

func (s *Store) persistLocked() error {
	data, err := json.MarshalIndent(s.state, "", "  ")
	if err != nil {
		return fmt.Errorf("encode store: %w", err)
	}

	tempFile := s.path + ".tmp"
	if err := os.WriteFile(tempFile, data, 0o600); err != nil {
		return fmt.Errorf("write temp store: %w", err)
	}

	if err := os.Rename(tempFile, s.path); err != nil {
		return fmt.Errorf("replace store: %w", err)
	}

	return nil
}

func cloneApp(record *AppRecord) *AppRecord {
	if record == nil {
		return nil
	}
	copy := *record
	return &copy
}

func cloneAgent(record *AgentRecord) *AgentRecord {
	if record == nil {
		return nil
	}
	copy := *record
	if record.LastSeenAt != nil {
		timestamp := *record.LastSeenAt
		copy.LastSeenAt = &timestamp
	}
	return &copy
}

func stringsCompare(lhs, rhs string) int {
	switch {
	case lhs < rhs:
		return -1
	case lhs > rhs:
		return 1
	default:
		return 0
	}
}
