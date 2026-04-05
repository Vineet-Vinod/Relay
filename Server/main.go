package main

import (
	"crypto/tls"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	logger := log.New(os.Stdout, "relay-server ", log.LstdFlags|log.Lmicroseconds)

	if err := loadDotEnv(defaultEnvFilePath()); err != nil {
		logger.Fatalf("load .env: %v", err)
	}

	cfg, err := LoadConfig()
	if err != nil {
		logger.Fatalf("load config: %v", err)
	}

	store, err := NewStore(cfg.DataFile)
	if err != nil {
		logger.Fatalf("open store: %v", err)
	}

	hub := NewHub(cfg, store, logger)
	stopCleanup := make(chan struct{})
	defer close(stopCleanup)
	go hub.StartCleanup(stopCleanup)

	server := NewServer(cfg, store, hub, logger)

	httpServer := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           server.Routes(),
		ReadHeaderTimeout: 10 * time.Second,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
			NextProtos: []string{"http/1.1"},
		},
		TLSNextProto: map[string]func(*http.Server, *tls.Conn, http.Handler){},
	}

	logger.Printf("listening on %s", cfg.HTTPAddr)
	logger.Printf("public url %s", cfg.PublicURL.String())
	logger.Printf("session websocket %s", cfg.SessionWebSocketURL())

	if err := httpServer.ListenAndServeTLS(cfg.TLSCertFile, cfg.TLSKeyFile); err != nil && err != http.ErrServerClosed {
		logger.Fatalf("serve: %v", err)
	}
}
