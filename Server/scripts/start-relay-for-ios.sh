#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${SERVER_DIR}"

if [[ ! -f ".env" ]]; then
  echo "Missing ${SERVER_DIR}/.env"
  echo "Create it from .env.example first."
  exit 1
fi

echo "Building relay-server..."
go build -o relay-server .

echo
echo "Starting Relay server for iOS app onboarding."
echo "The Relay app will need LAN access to http://<server-ip>:8080/register."
echo "Keep RELAY_HTTP_ADDR on a LAN-reachable address such as 0.0.0.0:8080 for smoke tests."
echo

sudo ./relay-server
