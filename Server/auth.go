package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"strings"
)

const pairingAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

func newToken() (string, error) {
	buffer := make([]byte, 32)
	if _, err := rand.Read(buffer); err != nil {
		return "", fmt.Errorf("generate token: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(buffer), nil
}

func tokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func newPairingCode() (string, error) {
	buffer := make([]byte, 8)
	if _, err := rand.Read(buffer); err != nil {
		return "", fmt.Errorf("generate pairing code: %w", err)
	}

	var builder strings.Builder
	builder.Grow(len(buffer))
	for _, b := range buffer {
		builder.WriteByte(pairingAlphabet[int(b)%len(pairingAlphabet)])
	}
	return builder.String(), nil
}

func bearerToken(request *http.Request) (string, error) {
	header := strings.TrimSpace(request.Header.Get("Authorization"))
	if header == "" {
		return "", errors.New("missing Authorization header")
	}

	prefix := "Bearer "
	if !strings.HasPrefix(header, prefix) {
		return "", errors.New("expected bearer token")
	}

	token := strings.TrimSpace(strings.TrimPrefix(header, prefix))
	if token == "" {
		return "", errors.New("empty bearer token")
	}
	return token, nil
}
