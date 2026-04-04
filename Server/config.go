package main

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	HTTPAddr        string
	PublicURL       *url.URL
	TLSCertFile     string
	TLSKeyFile      string
	DataFile        string
	PairingTTL      time.Duration
	SessionTTL      time.Duration
	CleanupInterval time.Duration
}

func LoadConfig() (Config, error) {
	cfg := Config{
		HTTPAddr:        envOrDefault("RELAY_HTTP_ADDR", ":8443"),
		TLSCertFile:     strings.TrimSpace(os.Getenv("RELAY_TLS_CERT_FILE")),
		TLSKeyFile:      strings.TrimSpace(os.Getenv("RELAY_TLS_KEY_FILE")),
		DataFile:        envOrDefault("RELAY_DATA_FILE", filepath.Join("data", "relay-store.json")),
		PairingTTL:      durationOrDefault("RELAY_PAIRING_TTL", 10*time.Minute),
		SessionTTL:      durationOrDefault("RELAY_SESSION_TTL", 2*time.Minute),
		CleanupInterval: durationOrDefault("RELAY_CLEANUP_INTERVAL", 30*time.Second),
	}

	publicURL := strings.TrimSpace(os.Getenv("RELAY_PUBLIC_URL"))
	if publicURL == "" {
		return Config{}, errors.New("RELAY_PUBLIC_URL is required")
	}

	parsedURL, err := url.Parse(publicURL)
	if err != nil {
		return Config{}, fmt.Errorf("parse RELAY_PUBLIC_URL: %w", err)
	}

	if parsedURL.Scheme != "https" && parsedURL.Scheme != "http" {
		return Config{}, errors.New("RELAY_PUBLIC_URL must use https or http")
	}

	if parsedURL.Host == "" {
		return Config{}, errors.New("RELAY_PUBLIC_URL must include a host")
	}

	if cfg.TLSCertFile == "" || cfg.TLSKeyFile == "" {
		return Config{}, errors.New("RELAY_TLS_CERT_FILE and RELAY_TLS_KEY_FILE are required")
	}

	cfg.PublicURL = parsedURL
	return cfg, nil
}

func (c Config) SessionWebSocketURL() string {
	wsURL := *c.PublicURL
	switch wsURL.Scheme {
	case "https":
		wsURL.Scheme = "wss"
	case "http":
		wsURL.Scheme = "ws"
	}
	wsURL.Path = "/v1/ws/session"
	wsURL.RawQuery = ""
	return wsURL.String()
}

func (c Config) AgentWebSocketURL() string {
	wsURL := *c.PublicURL
	switch wsURL.Scheme {
	case "https":
		wsURL.Scheme = "wss"
	case "http":
		wsURL.Scheme = "ws"
	}
	wsURL.Path = "/v1/ws/agent"
	wsURL.RawQuery = ""
	return wsURL.String()
}

func envOrDefault(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

func durationOrDefault(key string, fallback time.Duration) time.Duration {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return fallback
	}

	if seconds, err := strconv.Atoi(raw); err == nil {
		return time.Duration(seconds) * time.Second
	}

	parsed, err := time.ParseDuration(raw)
	if err != nil {
		return fallback
	}
	return parsed
}
