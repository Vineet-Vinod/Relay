#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
agent_dir="$(cd -- "${script_dir}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/run-agent.sh [additional run flags...]

Examples:
  ./scripts/run-agent.sh
  ./scripts/run-agent.sh --config /Users/you/.relay-agent/config.json

Environment:
  RELAY_AGENT_CONFIG          Default config path if --config is not provided.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

config_path="${RELAY_AGENT_CONFIG:-}"
extra_args=("$@")

if [[ -n "${config_path}" ]]; then
  extra_args=("--config" "${config_path}" "${extra_args[@]}")
fi

cd "${agent_dir}"
exec go run . run "${extra_args[@]}"
