package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func loadDotEnv() error {
	path := strings.TrimSpace(os.Getenv("RELAY_ENV_FILE"))
	if path != "" {
		return loadEnvFile(path)
	}

	defaultPath := ".env"
	if _, err := os.Stat(defaultPath); err == nil {
		return loadEnvFile(defaultPath)
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("stat %s: %w", defaultPath, err)
	}

	return nil
}

func loadEnvFile(path string) error {
	absPath, err := filepath.Abs(path)
	if err != nil {
		return fmt.Errorf("resolve env file path %q: %w", path, err)
	}

	file, err := os.Open(absPath)
	if err != nil {
		return fmt.Errorf("open %s: %w", absPath, err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for lineNumber := 1; scanner.Scan(); lineNumber++ {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		line = strings.TrimPrefix(line, "export ")

		key, value, ok := strings.Cut(line, "=")
		if !ok {
			return fmt.Errorf("%s:%d: expected KEY=VALUE", absPath, lineNumber)
		}

		key = strings.TrimSpace(key)
		if key == "" {
			return fmt.Errorf("%s:%d: empty environment variable name", absPath, lineNumber)
		}

		if _, exists := os.LookupEnv(key); exists {
			continue
		}

		parsedValue, err := parseEnvValue(strings.TrimSpace(value))
		if err != nil {
			return fmt.Errorf("%s:%d: %w", absPath, lineNumber, err)
		}

		if err := os.Setenv(key, parsedValue); err != nil {
			return fmt.Errorf("%s:%d: set %s: %w", absPath, lineNumber, key, err)
		}
	}

	if err := scanner.Err(); err != nil {
		return fmt.Errorf("scan %s: %w", absPath, err)
	}

	return nil
}

func parseEnvValue(value string) (string, error) {
	if value == "" {
		return "", nil
	}

	if strings.HasPrefix(value, "\"") {
		unquoted, err := strconv.Unquote(value)
		if err != nil {
			return "", fmt.Errorf("invalid double-quoted value: %w", err)
		}
		return unquoted, nil
	}

	if strings.HasPrefix(value, "'") {
		if len(value) < 2 || !strings.HasSuffix(value, "'") {
			return "", fmt.Errorf("invalid single-quoted value")
		}
		return value[1 : len(value)-1], nil
	}

	return value, nil
}
