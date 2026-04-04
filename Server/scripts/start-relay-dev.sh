#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${RELAY_ENV_FILE:-$ROOT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

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
