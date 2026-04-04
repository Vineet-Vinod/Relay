package main

import (
	"bufio"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

var errInterfaceUnavailable = errors.New("wireguard interface unavailable")

type WireGuardManager struct {
	cfg            AppConfig
	logger         *log.Logger
	privateKeyPath string
	privateKey     string
	publicKey      string
	syncConfigPath string

	mu            sync.Mutex
	realInterface string
}

type WGPeerState struct {
	PublicKey           string
	AllowedIPs          []string
	LatestHandshake     time.Time
	PersistentKeepalive int
}

func NewWireGuardManager(cfg AppConfig, logger *log.Logger) (*WireGuardManager, error) {
	if _, err := exec.LookPath("wg"); err != nil {
		return nil, fmt.Errorf("wg not found in PATH")
	}
	if _, err := exec.LookPath("wireguard-go"); err != nil {
		return nil, fmt.Errorf("wireguard-go not found in PATH")
	}

	privateKeyPath := filepath.Join(cfg.StateDir, "server.key")
	privateKey, publicKey, err := loadOrCreateServerKeypair(privateKeyPath)
	if err != nil {
		return nil, err
	}

	return &WireGuardManager{
		cfg:            cfg,
		logger:         logger,
		privateKeyPath: privateKeyPath,
		privateKey:     privateKey,
		publicKey:      publicKey,
		syncConfigPath: filepath.Join(cfg.StateDir, cfg.InterfaceName+".setconf"),
	}, nil
}

func (m *WireGuardManager) PublicKey() string {
	return m.publicKey
}

func (m *WireGuardManager) RealInterface() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.realInterface
}

func (m *WireGuardManager) EnsureInterfaceUp() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	return m.ensureInterfaceUpLocked()
}

func (m *WireGuardManager) ResetPeers() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if err := m.ensureInterfaceUpLocked(); err != nil {
		return err
	}

	return m.applyConfigLocked(nil)
}

func (m *WireGuardManager) EnsurePeer(peer Peer) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if err := m.ensureInterfaceUpLocked(); err != nil {
		return err
	}

	allowedIPs := peer.AssignedIP + "/32"
	_, err := runCommand(
		"wg",
		"set",
		m.realInterface,
		"peer",
		peer.PublicKey,
		"allowed-ips",
		allowedIPs,
		"persistent-keepalive",
		strconv.Itoa(m.cfg.PersistentKeepalive),
	)
	if err != nil {
		return fmt.Errorf("configure peer %s: %w", peer.UserID, err)
	}

	return nil
}

func (m *WireGuardManager) RemovePeer(publicKey string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if err := m.ensureInterfaceUpLocked(); err != nil {
		return err
	}

	_, err := runCommand("wg", "set", m.realInterface, "peer", publicKey, "remove")
	if err != nil {
		return fmt.Errorf("remove peer %s: %w", publicKey, err)
	}
	return nil
}

func (m *WireGuardManager) DumpPeerStates() (map[string]WGPeerState, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if err := m.ensureInterfaceUpLocked(); err != nil {
		return nil, err
	}

	output, err := runCommand("wg", "show", m.realInterface, "dump")
	if err != nil {
		return nil, fmt.Errorf("dump wireguard state: %w", err)
	}

	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	peerStates := make(map[string]WGPeerState)
	lineNumber := 0

	for scanner.Scan() {
		lineNumber++
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		if lineNumber == 1 {
			continue
		}

		fields := strings.Split(line, "\t")
		if len(fields) < 8 {
			return nil, fmt.Errorf("unexpected wg dump format on line %d", lineNumber)
		}

		latestHandshakeUnix, err := strconv.ParseInt(fields[4], 10, 64)
		if err != nil {
			return nil, fmt.Errorf("parse latest handshake for %s: %w", fields[0], err)
		}

		persistentKeepalive, err := strconv.Atoi(fields[7])
		if err != nil {
			return nil, fmt.Errorf("parse keepalive for %s: %w", fields[0], err)
		}

		state := WGPeerState{
			PublicKey:           fields[0],
			AllowedIPs:          splitAllowedIPs(fields[3]),
			PersistentKeepalive: persistentKeepalive,
		}
		if latestHandshakeUnix > 0 {
			state.LatestHandshake = time.Unix(latestHandshakeUnix, 0).UTC()
		}

		peerStates[state.PublicKey] = state
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan wg dump: %w", err)
	}

	return peerStates, nil
}

func (s WGPeerState) HasAllowedIP(value string) bool {
	for _, allowedIP := range s.AllowedIPs {
		if allowedIP == value {
			return true
		}
	}
	return false
}

func (m *WireGuardManager) ensureInterfaceUpLocked() error {
	realInterface, err := m.resolveRealInterfaceLocked()
	if err != nil {
		if !errors.Is(err, errInterfaceUnavailable) {
			return err
		}

		if err := m.createInterfaceLocked(); err != nil {
			return err
		}

		realInterface, err = m.resolveRealInterfaceLocked()
		if err != nil {
			return err
		}
	}

	m.realInterface = realInterface

	if _, err := runCommand("wg", "set", m.realInterface, "private-key", m.privateKeyPath, "listen-port", strconv.Itoa(m.cfg.ListenPort)); err != nil {
		return fmt.Errorf("set interface settings: %w", err)
	}

	if err := m.ensureAddressLocked(); err != nil {
		return err
	}

	return nil
}

func (m *WireGuardManager) createInterfaceLocked() error {
	if err := os.MkdirAll("/var/run/wireguard", 0o755); err != nil {
		return fmt.Errorf("create /var/run/wireguard: %w", err)
	}

	nameFile := m.nameFilePath()
	_ = os.Remove(nameFile)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "wireguard-go", "utun")
	cmd.Env = append(os.Environ(), "WG_TUN_NAME_FILE="+nameFile)
	output, err := cmd.CombinedOutput()
	if err != nil {
		trimmed := strings.TrimSpace(string(output))
		if trimmed == "" {
			return fmt.Errorf("wireguard-go utun: %w", err)
		}
		return fmt.Errorf("wireguard-go utun: %w: %s", err, trimmed)
	}

	if err := waitForFile(nameFile, 2*time.Second); err != nil {
		return fmt.Errorf("wait for wireguard interface name file: %w", err)
	}

	return nil
}

func (m *WireGuardManager) resolveRealInterfaceLocked() (string, error) {
	output, err := runCommand("wg", "show", "interfaces")
	if err != nil {
		return "", fmt.Errorf("list wireguard interfaces: %w", err)
	}

	available := make(map[string]struct{})
	for _, name := range strings.Fields(string(output)) {
		available[name] = struct{}{}
	}

	if candidate, err := os.ReadFile(m.nameFilePath()); err == nil {
		name := strings.TrimSpace(string(candidate))
		if _, ok := available[name]; ok && name != "" {
			return name, nil
		}
	}

	if _, ok := available[m.cfg.InterfaceName]; ok {
		return m.cfg.InterfaceName, nil
	}

	if m.realInterface != "" {
		if _, ok := available[m.realInterface]; ok {
			return m.realInterface, nil
		}
	}

	return "", errInterfaceUnavailable
}

func (m *WireGuardManager) ensureAddressLocked() error {
	output, err := runCommand("ifconfig", m.realInterface)
	if err != nil {
		return fmt.Errorf("inspect interface %s: %w", m.realInterface, err)
	}

	needle := "inet " + m.cfg.InterfaceIP.String() + " "
	if !strings.Contains(string(output), needle) {
		if _, err := runCommand(
			"ifconfig",
			m.realInterface,
			"inet",
			m.cfg.InterfaceAddress,
			m.cfg.InterfaceIP.String(),
			"alias",
		); err != nil {
			return fmt.Errorf("assign %s to %s: %w", m.cfg.InterfaceAddress, m.realInterface, err)
		}
	}

	if _, err := runCommand("ifconfig", m.realInterface, "up"); err != nil {
		return fmt.Errorf("bring interface %s up: %w", m.realInterface, err)
	}

	return nil
}

func (m *WireGuardManager) applyConfigLocked(peers []Peer) error {
	if err := m.writeSyncConfigLocked(peers); err != nil {
		return err
	}

	if _, err := runCommand("wg", "setconf", m.realInterface, m.syncConfigPath); err != nil {
		return fmt.Errorf("apply wireguard config: %w", err)
	}

	return nil
}

func (m *WireGuardManager) writeSyncConfigLocked(peers []Peer) error {
	config := m.renderSetConf(peers)
	if err := os.WriteFile(m.syncConfigPath, []byte(config), 0o600); err != nil {
		return fmt.Errorf("write sync config: %w", err)
	}
	return nil
}

func (m *WireGuardManager) renderSetConf(peers []Peer) string {
	var builder strings.Builder

	builder.WriteString("[Interface]\n")
	builder.WriteString("PrivateKey = " + m.privateKey + "\n")
	builder.WriteString("ListenPort = " + strconv.Itoa(m.cfg.ListenPort) + "\n")

	for _, peer := range peers {
		builder.WriteString("\n[Peer]\n")
		builder.WriteString("PublicKey = " + peer.PublicKey + "\n")
		builder.WriteString("AllowedIPs = " + peer.AssignedIP + "/32\n")
		builder.WriteString("PersistentKeepalive = " + strconv.Itoa(m.cfg.PersistentKeepalive) + "\n")
	}

	return builder.String()
}

func (m *WireGuardManager) nameFilePath() string {
	return filepath.Join("/var/run/wireguard", m.cfg.InterfaceName+".name")
}

func splitAllowedIPs(value string) []string {
	if value == "" || value == "(none)" {
		return nil
	}
	parts := strings.Split(value, ",")
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		trimmed := strings.TrimSpace(part)
		if trimmed != "" {
			result = append(result, trimmed)
		}
	}
	return result
}

func loadOrCreateServerKeypair(path string) (string, string, error) {
	privateKey, err := os.ReadFile(path)
	if err == nil {
		if err := os.Chmod(path, 0o600); err != nil {
			return "", "", fmt.Errorf("harden permissions on %s: %w", path, err)
		}
		trimmed := strings.TrimSpace(string(privateKey))
		publicKey, err := publicKeyFromPrivateKey(trimmed)
		if err != nil {
			return "", "", fmt.Errorf("derive public key from %s: %w", path, err)
		}
		return trimmed, publicKey, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return "", "", fmt.Errorf("read %s: %w", path, err)
	}

	privateKeyBytes, publicKeyBytes, err := generateKeypair()
	if err != nil {
		return "", "", err
	}

	privateKeyString := base64.StdEncoding.EncodeToString(privateKeyBytes)
	publicKeyString := base64.StdEncoding.EncodeToString(publicKeyBytes)

	if err := os.WriteFile(path, []byte(privateKeyString+"\n"), 0o600); err != nil {
		return "", "", fmt.Errorf("write %s: %w", path, err)
	}

	return privateKeyString, publicKeyString, nil
}

func generateKeypair() ([]byte, []byte, error) {
	privateKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, nil, fmt.Errorf("generate x25519 keypair: %w", err)
	}

	return privateKey.Bytes(), privateKey.PublicKey().Bytes(), nil
}

func publicKeyFromPrivateKey(privateKey string) (string, error) {
	decoded, err := base64.StdEncoding.DecodeString(privateKey)
	if err != nil {
		return "", fmt.Errorf("decode private key: %w", err)
	}

	key, err := ecdh.X25519().NewPrivateKey(decoded)
	if err != nil {
		return "", fmt.Errorf("parse private key: %w", err)
	}

	return base64.StdEncoding.EncodeToString(key.PublicKey().Bytes()), nil
}

func runCommand(name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, name, args...)
	output, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return output, fmt.Errorf("%s timed out", commandString(name, args...))
	}
	if err != nil {
		trimmed := strings.TrimSpace(string(output))
		if trimmed == "" {
			return output, fmt.Errorf("%s: %w", commandString(name, args...), err)
		}
		return output, fmt.Errorf("%s: %w: %s", commandString(name, args...), err, trimmed)
	}

	return output, nil
}

func runCommandInput(input, name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdin = strings.NewReader(input)

	output, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return output, fmt.Errorf("%s timed out", commandString(name, args...))
	}
	if err != nil {
		trimmed := strings.TrimSpace(string(output))
		if trimmed == "" {
			return output, fmt.Errorf("%s: %w", commandString(name, args...), err)
		}
		return output, fmt.Errorf("%s: %w: %s", commandString(name, args...), err, trimmed)
	}

	return output, nil
}

func commandString(name string, args ...string) string {
	if len(args) == 0 {
		return name
	}
	return name + " " + strings.Join(args, " ")
}

func waitForFile(path string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("%s was not created within %s", path, timeout)
}
