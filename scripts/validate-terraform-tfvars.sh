#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: validate-terraform-tfvars.sh --tfvars FILE

Checks a Terraform tfvars file for Packer-only keys that should live in
packer/backend.auto.pkrvars.hcl instead.
EOF
}

TFVARS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tfvars) TFVARS="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
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

for cmd in rg; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
done

PACKER_ONLY_KEYS=(
  source_ami_id
  source_ami_name_pattern
  packer_instance_profile_name
  aws_poll_delay_seconds
  aws_max_attempts
  subnet_id
  security_group_id
  ssh_username
  ami_name_prefix
  root_volume_encrypted
  root_volume_kms_key_id
  copy_model_into_ami
  model_local_path
)

FOUND_KEYS=()
for key in "${PACKER_ONLY_KEYS[@]}"; do
  if rg -n "^[[:space:]]*${key}[[:space:]]*=" "${TFVARS}" >/dev/null; then
    FOUND_KEYS+=("${key}")
  fi
done

if (( ${#FOUND_KEYS[@]} > 0 )); then
  echo "Packer-only keys were found in Terraform tfvars: ${TFVARS}" >&2
  printf '  - %s\n' "${FOUND_KEYS[@]}" >&2
  echo >&2
  echo "Move these settings to packer/backend.auto.pkrvars.hcl (or your chosen Packer vars file)." >&2
  echo "Terraform tfvars like ${TFVARS} should only contain Terraform input variables." >&2
  exit 1
fi

echo "No Packer-only keys found in ${TFVARS}."
