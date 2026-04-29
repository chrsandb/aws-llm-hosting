#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <backend-alb-dns-name> [port]"
  exit 1
fi

HOST="$1"
PORT="${2:-80}"

curl --fail --silent --show-error "http://${HOST}:${PORT}/health"
