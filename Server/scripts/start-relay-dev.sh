#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${RELAY_PUBLIC_URL:?set RELAY_PUBLIC_URL, for example https://192.168.1.10:8443}"
: "${RELAY_TLS_CERT_FILE:?set RELAY_TLS_CERT_FILE to your TLS certificate path}"
: "${RELAY_TLS_KEY_FILE:?set RELAY_TLS_KEY_FILE to your TLS private key path}"

export RELAY_HTTP_ADDR="${RELAY_HTTP_ADDR:-:8443}"
export RELAY_DATA_FILE="${RELAY_DATA_FILE:-$ROOT_DIR/data/relay-store.json}"
export RELAY_PAIRING_TTL="${RELAY_PAIRING_TTL:-10m}"
export RELAY_SESSION_TTL="${RELAY_SESSION_TTL:-2m}"

mkdir -p "$(dirname "$RELAY_DATA_FILE")"

cd "$ROOT_DIR"
go run .
