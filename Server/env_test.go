package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadEnvFileSetsVariables(t *testing.T) {
	unsetEnvForTest(t, "RELAY_HTTP_ADDR")
	unsetEnvForTest(t, "RELAY_STATE_DIR")
	unsetEnvForTest(t, "RELAY_SERVER_ENDPOINT")
	unsetEnvForTest(t, "RELAY_EGRESS_INTERFACE")

	tempDir := t.TempDir()
	path := filepath.Join(tempDir, ".env")
	content := "" +
		"# comment\n" +
		"RELAY_HTTP_ADDR=127.0.0.1:8080\n" +
		"RELAY_STATE_DIR=./.state\n" +
		"RELAY_SERVER_ENDPOINT=\"vpn.example.com:51820\"\n" +
		"RELAY_EGRESS_INTERFACE='en0'\n"

	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	if err := loadEnvFile(path); err != nil {
		t.Fatalf("loadEnvFile() error = %v", err)
	}

	if got := os.Getenv("RELAY_HTTP_ADDR"); got != "127.0.0.1:8080" {
		t.Fatalf("RELAY_HTTP_ADDR = %q, want %q", got, "127.0.0.1:8080")
	}
	if got := os.Getenv("RELAY_SERVER_ENDPOINT"); got != "vpn.example.com:51820" {
		t.Fatalf("RELAY_SERVER_ENDPOINT = %q, want %q", got, "vpn.example.com:51820")
	}
	if got := os.Getenv("RELAY_EGRESS_INTERFACE"); got != "en0" {
		t.Fatalf("RELAY_EGRESS_INTERFACE = %q, want %q", got, "en0")
	}
}

func TestLoadEnvFileDoesNotOverrideExistingEnvironment(t *testing.T) {
	t.Setenv("RELAY_HTTP_ADDR", ":9999")

	tempDir := t.TempDir()
	path := filepath.Join(tempDir, ".env")
	if err := os.WriteFile(path, []byte("RELAY_HTTP_ADDR=127.0.0.1:8080\n"), 0o600); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	if err := loadEnvFile(path); err != nil {
		t.Fatalf("loadEnvFile() error = %v", err)
	}

	if got := os.Getenv("RELAY_HTTP_ADDR"); got != ":9999" {
		t.Fatalf("RELAY_HTTP_ADDR = %q, want %q", got, ":9999")
	}
}

func unsetEnvForTest(t *testing.T, key string) {
	t.Helper()

	originalValue, hadOriginal := os.LookupEnv(key)
	if err := os.Unsetenv(key); err != nil {
		t.Fatalf("Unsetenv(%q) error = %v", key, err)
	}

	t.Cleanup(func() {
		if hadOriginal {
			_ = os.Setenv(key, originalValue)
			return
		}
		_ = os.Unsetenv(key)
	})
}
