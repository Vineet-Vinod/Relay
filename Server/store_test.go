package main

import (
	"path/filepath"
	"testing"
)

func TestStorePersistsAppsAndAgents(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "relay-store.json")
	store, err := NewStore(path)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}

	app, token, err := store.CreateApp("My iPhone")
	if err != nil {
		t.Fatalf("create app: %v", err)
	}

	agent, _, err := store.CreateAgent(app.ID, "Home Mac", "macOS")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}

	reloaded, err := NewStore(path)
	if err != nil {
		t.Fatalf("reload store: %v", err)
	}

	storedApp, ok := reloaded.FindAppByToken(token)
	if !ok {
		t.Fatalf("expected reloaded app")
	}

	if storedApp.ID != app.ID {
		t.Fatalf("app id mismatch: got %s want %s", storedApp.ID, app.ID)
	}

	storedAgent, ok := reloaded.AgentByID(agent.ID)
	if !ok {
		t.Fatalf("expected reloaded agent")
	}

	if storedAgent.Name != agent.Name {
		t.Fatalf("agent name mismatch: got %s want %s", storedAgent.Name, agent.Name)
	}
}
