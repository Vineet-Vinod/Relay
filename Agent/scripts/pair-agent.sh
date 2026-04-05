#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
agent_dir="$(cd -- "${script_dir}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/pair-agent.sh <server-url-or-host:port> <pair-code> [additional pair flags...]

Examples:
  ./scripts/pair-agent.sh 192.168.1.10:8443 ABC12345 --allow-insecure-tls
  ./scripts/pair-agent.sh https://relay.example.com:8443 ABC12345 --name "Home Mac"

Environment:
  RELAY_SERVER_URL            Default server URL if the first argument is omitted.
  RELAY_PAIR_CODE             Default pairing code if the second argument is omitted.
  RELAY_AGENT_ALLOW_INSECURE  When set to 1, adds --allow-insecure-tls automatically.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

server_input="${1:-${RELAY_SERVER_URL:-}}"
pair_code="${2:-${RELAY_PAIR_CODE:-}}"

if [[ -z "${server_input}" || -z "${pair_code}" ]]; then
  usage
  exit 1
fi

if [[ "${server_input}" != http://* && "${server_input}" != https://* ]]; then
  server_input="https://${server_input}"
fi

cd "${agent_dir}"
if [[ "${RELAY_AGENT_ALLOW_INSECURE:-0}" == "1" ]]; then
  if [[ $# -gt 2 ]]; then
    exec go run . pair \
      --server "${server_input}" \
      --code "${pair_code}" \
      --allow-insecure-tls \
      "${@:3}"
  fi

  exec go run . pair \
    --server "${server_input}" \
    --code "${pair_code}" \
    --allow-insecure-tls
fi

if [[ $# -gt 2 ]]; then
  exec go run . pair \
    --server "${server_input}" \
    --code "${pair_code}" \
    "${@:3}"
fi

exec go run . pair \
  --server "${server_input}" \
  --code "${pair_code}"
