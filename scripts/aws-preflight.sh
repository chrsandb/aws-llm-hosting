#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: aws-preflight.sh [--region REGION] [--profile PROFILE]

Checks that the AWS CLI can authenticate and prints the active identity,
region, and account details used for this repository.
EOF
}

REGION=""
PROFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

AWS_ARGS=()
if [[ -n "${PROFILE}" ]]; then
  AWS_ARGS+=(--profile "${PROFILE}")
fi
if [[ -n "${REGION}" ]]; then
  AWS_ARGS+=(--region "${REGION}")
fi

for cmd in aws jq; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
done

IDENTITY_JSON="$(aws "${AWS_ARGS[@]}" sts get-caller-identity)"
ACCOUNT_ID="$(jq -r '.Account' <<<"${IDENTITY_JSON}")"
ARN="$(jq -r '.Arn' <<<"${IDENTITY_JSON}")"
USER_ID="$(jq -r '.UserId' <<<"${IDENTITY_JSON}")"
ACTIVE_REGION="${REGION:-$(aws "${AWS_ARGS[@]}" configure get region || true)}"

cat <<EOF
AWS preflight passed.
Account ID : ${ACCOUNT_ID}
Caller ARN : ${ARN}
User ID    : ${USER_ID}
Region     : ${ACTIVE_REGION:-<not-set>}
Profile    : ${PROFILE:-<default>}
EOF
