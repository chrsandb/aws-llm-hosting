#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: create-litellm-secret.sh --name SECRET_NAME [--region REGION] [--profile PROFILE]

Creates or updates a Secrets Manager secret containing a random LiteLLM master key.
EOF
}

SECRET_NAME=""
REGION=""
PROFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) SECRET_NAME="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "${SECRET_NAME}" ]]; then
  usage
  exit 1
fi

for cmd in aws openssl; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
done

AWS_ARGS=()
if [[ -n "${PROFILE}" ]]; then
  AWS_ARGS+=(--profile "${PROFILE}")
fi
if [[ -n "${REGION}" ]]; then
  AWS_ARGS+=(--region "${REGION}")
fi

SECRET_VALUE="$(openssl rand -hex 32)"

if aws "${AWS_ARGS[@]}" secretsmanager describe-secret --secret-id "${SECRET_NAME}" >/dev/null 2>&1; then
  aws "${AWS_ARGS[@]}" secretsmanager put-secret-value \
    --secret-id "${SECRET_NAME}" \
    --secret-string "${SECRET_VALUE}" >/dev/null
  echo "Updated secret: ${SECRET_NAME}"
else
  aws "${AWS_ARGS[@]}" secretsmanager create-secret \
    --name "${SECRET_NAME}" \
    --secret-string "${SECRET_VALUE}" >/dev/null
  echo "Created secret: ${SECRET_NAME}"
fi
