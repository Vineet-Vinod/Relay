package main

import (
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	logger := log.New(os.Stdout, "relay-server ", log.LstdFlags|log.Lmicroseconds)

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
	}

	logger.Printf("listening on %s", cfg.HTTPAddr)
	logger.Printf("public url %s", cfg.PublicURL.String())
	logger.Printf("session websocket %s", cfg.SessionWebSocketURL())

	if err := httpServer.ListenAndServeTLS(cfg.TLSCertFile, cfg.TLSKeyFile); err != nil && err != http.ErrServerClosed {
		logger.Fatalf("serve: %v", err)
	}
}
