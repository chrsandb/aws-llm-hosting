#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: destroy-preserve-secrets.sh --tfvars FILE [--terraform-dir DIR]

Runs Terraform destroy, but first removes the Terraform-managed Postgres secret
resources from state so the secret container remains in Secrets Manager for a
later re-apply.
EOF
}

TFVARS=""
TERRAFORM_DIR="terraform"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tfvars) TFVARS="$2"; shift 2 ;;
    --terraform-dir) TERRAFORM_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "${TFVARS}" ]]; then
  usage >&2
  exit 1
fi

if [[ ! -f "${TFVARS}" ]]; then
  echo "tfvars file not found: ${TFVARS}" >&2
  exit 1
fi

TFVARS_ABS="$(cd "$(dirname "${TFVARS}")" && pwd)/$(basename "${TFVARS}")"

command -v terraform >/dev/null 2>&1 || {
  echo "Missing required command: terraform" >&2
  exit 1
}

terraform -chdir="${TERRAFORM_DIR}" init >/dev/null

for addr in \
  module.litellm_frontend.aws_secretsmanager_secret.postgres[0] \
  module.litellm_frontend.aws_secretsmanager_secret_version.postgres; do
  if terraform -chdir="${TERRAFORM_DIR}" state show "${addr}" >/dev/null 2>&1; then
    echo "Preserving ${addr} by removing it from Terraform state before destroy..."
    terraform -chdir="${TERRAFORM_DIR}" state rm "${addr}" >/dev/null
  fi
done

terraform -chdir="${TERRAFORM_DIR}" destroy -var-file="${TFVARS_ABS}"
