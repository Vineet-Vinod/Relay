package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	defaultHTTPListenAddr      = ":8080"
	defaultWireGuardInterface  = "wg0"
	defaultWireGuardAddress    = "10.0.0.1/24"
	defaultWireGuardListenPort = 51820
	defaultPersistentKeepalive = 25
	defaultStateDir            = "./.state"
)

type AppConfig struct {
	HTTPListenAddr        string
	InterfaceName         string
	InterfaceAddress      string
	InterfaceIP           netip.Addr
	InterfaceNetwork      netip.Prefix
	ListenPort            int
	PersistentKeepalive   int
	StateDir              string
	ServerEndpoint        string
	ExternalInterface     string
	ClientAddressMaskBits int
}

func main() {
	logger := log.New(os.Stdout, "relay-server ", log.LstdFlags|log.Lmsgprefix)

	if err := loadDotEnv(); err != nil {
		logger.Fatalf("load .env: %v", err)
	}

	if os.Geteuid() != 0 {
		logger.Fatal("run this server as root or with sudo on macOS; wg, ifconfig, sysctl, and pfctl require elevated privileges")
	}

	cfg, err := loadConfig()
	if err != nil {
		logger.Fatal(err)
	}

	if err := os.MkdirAll(cfg.StateDir, 0o700); err != nil {
		logger.Fatalf("create state directory: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	store, err := NewPeerStore(cfg.InterfaceNetwork.String(), cfg.InterfaceIP.String())
	if err != nil {
		logger.Fatalf("initialize peer store: %v", err)
	}

	wgManager, err := NewWireGuardManager(cfg, logger)
	if err != nil {
		logger.Fatalf("initialize wireguard manager: %v", err)
	}

	if err := wgManager.EnsureInterfaceUp(); err != nil {
		logger.Fatalf("bring up wireguard interface: %v", err)
	}

	if err := wgManager.ResetPeers(); err != nil {
		logger.Fatalf("reset wireguard peers: %v", err)
	}

	natManager := NewPFNATManager(cfg, logger)
	if err := natManager.Configure(); err != nil {
		logger.Fatalf("configure pf nat: %v", err)
	}

	if cfg.ServerEndpoint == "" {
		egressIP, err := natManager.EgressIPv4()
		if err != nil {
			logger.Fatalf("detect server endpoint: %v", err)
		}
		cfg.ServerEndpoint = net.JoinHostPort(egressIP, strconv.Itoa(cfg.ListenPort))
		logger.Printf("RELAY_SERVER_ENDPOINT was not set; using detected egress endpoint %s", cfg.ServerEndpoint)
	}

	apiServer := NewAPIServer(cfg, store, wgManager, logger)
	liveness := NewLivenessMonitor(store, wgManager, logger, 15*time.Second, 2*time.Minute)
	reconciler := NewReconciler(store, wgManager, logger, 30*time.Second, cfg.PersistentKeepalive)

	go liveness.Start(ctx)
	go reconciler.Start(ctx)

	httpServer := &http.Server{
		Addr:              cfg.HTTPListenAddr,
		Handler:           apiServer.Routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		<-ctx.Done()

		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()

		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			logger.Printf("http shutdown: %v", err)
		}
	}()

	logger.Printf(
		"wireguard ready desired_interface=%s real_interface=%s nat_interface=%s http=%s",
		cfg.InterfaceName,
		wgManager.RealInterface(),
		natManager.EgressInterface(),
		cfg.HTTPListenAddr,
	)

	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Fatalf("http server failed: %v", err)
	}
}

func loadConfig() (AppConfig, error) {
	interfaceName := envOrDefault("RELAY_WG_INTERFACE", defaultWireGuardInterface)
	interfaceAddress := envOrDefault("RELAY_WG_ADDRESS", defaultWireGuardAddress)
	httpListenAddr := envOrDefault("RELAY_HTTP_ADDR", defaultHTTPListenAddr)
	stateDir := envOrDefault("RELAY_STATE_DIR", defaultStateDir)
	serverEndpoint := strings.TrimSpace(os.Getenv("RELAY_SERVER_ENDPOINT"))
	externalInterface := strings.TrimSpace(os.Getenv("RELAY_EGRESS_INTERFACE"))

	listenPort, err := envInt("RELAY_WG_LISTEN_PORT", defaultWireGuardListenPort)
	if err != nil {
		return AppConfig{}, err
	}

	persistentKeepalive, err := envInt("RELAY_PERSISTENT_KEEPALIVE", defaultPersistentKeepalive)
	if err != nil {
		return AppConfig{}, err
	}

	interfacePrefix, err := netip.ParsePrefix(interfaceAddress)
	if err != nil {
		return AppConfig{}, fmt.Errorf("parse RELAY_WG_ADDRESS: %w", err)
	}
	if !interfacePrefix.Addr().Is4() {
		return AppConfig{}, fmt.Errorf("RELAY_WG_ADDRESS must be an IPv4 CIDR")
	}
	if interfacePrefix.Bits() != 24 {
		return AppConfig{}, fmt.Errorf("RELAY_WG_ADDRESS must use /24; got /%d", interfacePrefix.Bits())
	}

	if serverEndpoint != "" {
		if _, _, err := net.SplitHostPort(serverEndpoint); err != nil {
			return AppConfig{}, fmt.Errorf("RELAY_SERVER_ENDPOINT must be host:port: %w", err)
		}
	}

	absStateDir, err := filepath.Abs(stateDir)
	if err != nil {
		return AppConfig{}, fmt.Errorf("resolve state directory: %w", err)
	}

	return AppConfig{
		HTTPListenAddr:        httpListenAddr,
		InterfaceName:         interfaceName,
		InterfaceAddress:      interfaceAddress,
		InterfaceIP:           interfacePrefix.Addr(),
		InterfaceNetwork:      interfacePrefix.Masked(),
		ListenPort:            listenPort,
		PersistentKeepalive:   persistentKeepalive,
		StateDir:              absStateDir,
		ServerEndpoint:        serverEndpoint,
		ExternalInterface:     externalInterface,
		ClientAddressMaskBits: interfacePrefix.Bits(),
	}, nil
}

func envOrDefault(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

func envInt(key string, fallback int) (int, error) {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback, nil
	}

	parsed, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("parse %s: %w", key, err)
	}
	return parsed, nil
}
