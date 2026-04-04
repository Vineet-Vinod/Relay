package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

type AgentConfig struct {
	ServerURL        string `json:"server_url"`
	AgentID          string `json:"agent_id"`
	AgentToken       string `json:"agent_token"`
	DeviceName       string `json:"device_name"`
	Platform         string `json:"platform"`
	AllowInsecureTLS bool   `json:"allow_insecure_tls"`
}

type AgentPairResponse struct {
	AgentID          string `json:"agent_id"`
	AgentToken       string `json:"agent_token"`
	ServerURL        string `json:"server_url"`
	WebSocketURL     string `json:"websocket_url"`
	AllowInsecureTLS bool   `json:"allow_insecure_tls"`
	AppOwnerName     string `json:"app_owner_name"`
	RegisteredAppID  string `json:"registered_app_id"`
}

func defaultConfigPath() (string, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("find home directory: %w", err)
	}

	return filepath.Join(homeDir, ".relay-agent", "config.json"), nil
}

func loadConfig(path string) (AgentConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return AgentConfig{}, fmt.Errorf("read config: %w", err)
	}

	var cfg AgentConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return AgentConfig{}, fmt.Errorf("decode config: %w", err)
	}

	return cfg, validateConfig(cfg)
}

func saveConfig(path string, cfg AgentConfig) error {
	if err := validateConfig(cfg); err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("create config directory: %w", err)
	}

	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return fmt.Errorf("encode config: %w", err)
	}

	if err := os.WriteFile(path, data, 0o600); err != nil {
		return fmt.Errorf("write config: %w", err)
	}

	return nil
}

func validateConfig(cfg AgentConfig) error {
	if strings.TrimSpace(cfg.ServerURL) == "" {
		return errors.New("server_url is required")
	}
	if strings.TrimSpace(cfg.AgentID) == "" {
		return errors.New("agent_id is required")
	}
	if strings.TrimSpace(cfg.AgentToken) == "" {
		return errors.New("agent_token is required")
	}
	return nil
}

func agentWebSocketURL(serverURL, agentToken string) (string, error) {
	parsedURL, err := url.Parse(serverURL)
	if err != nil {
		return "", fmt.Errorf("parse server url: %w", err)
	}

	switch parsedURL.Scheme {
	case "https":
		parsedURL.Scheme = "wss"
	case "http":
		parsedURL.Scheme = "ws"
	default:
		return "", errors.New("server url must use https or http")
	}

	parsedURL.Path = "/v1/ws/agent"
	query := parsedURL.Query()
	query.Set("agent_token", agentToken)
	parsedURL.RawQuery = query.Encode()

	return parsedURL.String(), nil
}
