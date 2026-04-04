//go:build darwin

package main

import (
	"bufio"
	"bytes"
	"fmt"
	"log"
	"net"
	"strings"
)

const relayPFAnchor = "com.apple/relay"

type PFNATManager struct {
	cfg             AppConfig
	logger          *log.Logger
	egressInterface string
}

func NewPFNATManager(cfg AppConfig, logger *log.Logger) *PFNATManager {
	return &PFNATManager{
		cfg:    cfg,
		logger: logger,
	}
}

func (m *PFNATManager) Configure() error {
	egressInterface := m.cfg.ExternalInterface
	if egressInterface == "" {
		detected, err := detectDefaultRouteInterface()
		if err != nil {
			return fmt.Errorf("detect default route interface: %w", err)
		}
		egressInterface = detected
	}

	if _, err := net.InterfaceByName(egressInterface); err != nil {
		return fmt.Errorf("lookup egress interface %q: %w", egressInterface, err)
	}

	if _, err := runCommand("sysctl", "-w", "net.inet.ip.forwarding=1"); err != nil {
		return fmt.Errorf("enable IPv4 forwarding: %w", err)
	}

	if _, err := runCommand("pfctl", "-E"); err != nil {
		return fmt.Errorf("enable pf: %w", err)
	}

	rule := fmt.Sprintf("nat on %s from %s to any -> (%s)\n", egressInterface, m.cfg.InterfaceNetwork.String(), egressInterface)
	if _, err := runCommandInput(rule, "pfctl", "-a", relayPFAnchor, "-f", "-"); err != nil {
		return fmt.Errorf("load pf nat rule: %w", err)
	}

	if output, err := runCommand("pfctl", "-a", relayPFAnchor, "-s", "nat"); err != nil {
		return fmt.Errorf("verify pf nat rule: %w", err)
	} else if !bytes.Contains(output, []byte("nat on "+egressInterface)) {
		return fmt.Errorf("pf nat rule did not apply to %s", egressInterface)
	}

	m.egressInterface = egressInterface
	m.logger.Printf("configured pf NAT on %s for %s", egressInterface, m.cfg.InterfaceNetwork.String())
	return nil
}

func (m *PFNATManager) EgressInterface() string {
	return m.egressInterface
}

func (m *PFNATManager) EgressIPv4() (string, error) {
	if m.egressInterface == "" {
		return "", fmt.Errorf("egress interface not configured")
	}

	iface, err := net.InterfaceByName(m.egressInterface)
	if err != nil {
		return "", fmt.Errorf("lookup interface %s: %w", m.egressInterface, err)
	}

	addresses, err := iface.Addrs()
	if err != nil {
		return "", fmt.Errorf("list addresses for %s: %w", m.egressInterface, err)
	}

	for _, address := range addresses {
		ipNet, ok := address.(*net.IPNet)
		if !ok {
			continue
		}
		if ip := ipNet.IP.To4(); ip != nil {
			return ip.String(), nil
		}
	}

	return "", fmt.Errorf("no IPv4 address found on %s", m.egressInterface)
}

func detectDefaultRouteInterface() (string, error) {
	output, err := runCommand("route", "-n", "get", "default")
	if err != nil {
		return "", err
	}

	scanner := bufio.NewScanner(bytes.NewReader(output))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, "interface:") {
			continue
		}
		value := strings.TrimSpace(strings.TrimPrefix(line, "interface:"))
		if value != "" {
			return value, nil
		}
	}

	if err := scanner.Err(); err != nil {
		return "", err
	}

	return "", fmt.Errorf("default route interface not found")
}
