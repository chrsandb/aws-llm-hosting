#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  apply-with-az-fallback.sh --tfvars FILE [options] [-- terraform_apply_args...]

Attempt terraform apply by trying one backend private subnet (AZ) at a time.
If apply fails with an EC2 capacity error, the script retries using the next
subnet from backend_private_subnet_ids until one succeeds or all are exhausted.

Options:
  --tfvars FILE                Terraform tfvars file
  --terraform-dir DIR          Terraform directory (default: terraform)
  --region REGION              AWS region used only for AZ lookup output
  --profile PROFILE            Optional AWS profile for AZ lookup output
  --help                       Show help

Examples:
  ./scripts/apply-with-az-fallback.sh \
    --tfvars examples/generated.prod.tfvars \
    --region eu-north-1

  ./scripts/apply-with-az-fallback.sh \
    --tfvars examples/generated.prod.tfvars \
    -- --auto-approve
EOF
}

parse_tfvars_array() {
  local key="$1"
  local path="$2"
  python3 - "$key" "$path" <<'PY'
import re
import sys

key, path = sys.argv[1], sys.argv[2]
text = open(path, "r", encoding="utf-8").read()
match = re.search(rf"^\s*{re.escape(key)}\s*=\s*\[(.*?)\]", text, re.M | re.S)
if not match:
    sys.exit(0)
for value in re.findall(r'"([^"]+)"', match.group(1)):
    print(value)
PY
}

TFVARS=""
TERRAFORM_DIR="terraform"
REGION=""
PROFILE=""
TF_APPLY_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tfvars) TFVARS="$2"; shift 2 ;;
    --terraform-dir) TERRAFORM_DIR="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --)
      shift
      TF_APPLY_ARGS=("$@")
      break
      ;;
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

for cmd in terraform python3; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
done

SUBNET_IDS=()
while IFS= read -r subnet_id; do
  [[ -n "${subnet_id}" ]] && SUBNET_IDS+=("${subnet_id}")
done < <(parse_tfvars_array "backend_private_subnet_ids" "${TFVARS}")

if (( ${#SUBNET_IDS[@]} == 0 )); then
  echo "backend_private_subnet_ids is empty or missing in ${TFVARS}." >&2
  exit 1
fi

if [[ -n "${REGION}" ]]; then
  AWS_ARGS=(--region "${REGION}")
  if [[ -n "${PROFILE}" ]]; then
    AWS_ARGS+=(--profile "${PROFILE}")
  fi
fi

echo "Trying terraform apply across ${#SUBNET_IDS[@]} backend subnet(s) with AZ fallback..."

LAST_LOG=""
for subnet_id in "${SUBNET_IDS[@]}"; do
  az="unknown-AZ"
  if [[ -n "${REGION}" ]] && command -v aws >/dev/null 2>&1; then
    az="$(aws "${AWS_ARGS[@]}" ec2 describe-subnets --subnet-ids "${subnet_id}" --query 'Subnets[0].AvailabilityZone' --output text 2>/dev/null || echo unknown-AZ)"
  fi

  echo
  echo "=== Attempting apply with backend subnet ${subnet_id} (${az}) ==="

  LAST_LOG="$(mktemp)"
  set +e
  terraform -chdir="${TERRAFORM_DIR}" apply \
    -var-file="${TFVARS}" \
    -var="backend_private_subnet_ids=[\"${subnet_id}\"]" \
    "${TF_APPLY_ARGS[@]}" 2>&1 | tee "${LAST_LOG}"
  rc=${PIPESTATUS[0]}
  set -e

  if (( rc == 0 )); then
    echo
    echo "Apply succeeded using subnet ${subnet_id} (${az})."
    exit 0
  fi

  if rg -qi "do not have sufficient|insufficient.*capacity|insufficientinstancecapacity|capacity.*availability zone" "${LAST_LOG}"; then
    echo "Capacity-related failure detected for ${subnet_id} (${az}); trying next subnet..."
    continue
  fi

  echo "Apply failed for a non-capacity reason; stopping fallback." >&2
  exit "${rc}"
done

echo

echo "All candidate backend subnets failed due to capacity-related errors." >&2
if [[ -n "${LAST_LOG}" && -f "${LAST_LOG}" ]]; then
  echo "Last apply log: ${LAST_LOG}" >&2
fi
exit 1
