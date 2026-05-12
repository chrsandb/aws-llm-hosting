#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  suggest-admin-cidrs.sh --tfvars FILE [options]

Suggest candidate values for admin_allowed_cidrs, preferring your current
public IP /32 and showing private VPC CIDRs as broader alternatives.

Options:
  --tfvars FILE         Terraform tfvars file with frontend_vpc_id/backend_vpc_id
  --region REGION       AWS region override
  --profile PROFILE     AWS CLI profile
  --public-ip IP        Override detected public IP
  --help                Show this help text

Example:
  ./scripts/suggest-admin-cidrs.sh \
    --region eu-north-1 \
    --tfvars examples/generated.prod.tfvars
EOF
}

parse_tfvars_string() {
  local key="$1"
  local path="$2"
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]+)\"([[:space:]]*#.*)?$/\\1/p" "${path}" | head -n1
}

detect_public_ip() {
  local ip=""
  for url in \
    "https://checkip.amazonaws.com" \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip"; do
    ip="$(curl -fsS --connect-timeout 3 --max-time 8 "${url}" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s\n' "${ip}"
      return 0
    fi
  done
  return 1
}

TFVARS=""
REGION=""
PROFILE=""
PUBLIC_IP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tfvars) TFVARS="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --public-ip) PUBLIC_IP="$2"; shift 2 ;;
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

for cmd in aws curl jq; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
done

AWS_ARGS=()
if [[ -n "${REGION}" ]]; then
  AWS_ARGS+=(--region "${REGION}")
fi
if [[ -n "${PROFILE}" ]]; then
  AWS_ARGS+=(--profile "${PROFILE}")
fi

FRONTEND_VPC_ID="$(parse_tfvars_string "frontend_vpc_id" "${TFVARS}")"
BACKEND_VPC_ID="$(parse_tfvars_string "backend_vpc_id" "${TFVARS}")"

if [[ -z "${PUBLIC_IP}" ]]; then
  PUBLIC_IP="$(detect_public_ip || true)"
fi

fetch_vpc_cidr() {
  local vpc_id="$1"
  [[ -z "${vpc_id}" ]] && return 0
  aws "${AWS_ARGS[@]}" ec2 describe-vpcs --vpc-ids "${vpc_id}" --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null || true
}

FRONTEND_VPC_CIDR="$(fetch_vpc_cidr "${FRONTEND_VPC_ID}")"
BACKEND_VPC_CIDR="$(fetch_vpc_cidr "${BACKEND_VPC_ID}")"

echo "Admin CIDR suggestions"
echo
echo "Recommended default:"
if [[ -n "${PUBLIC_IP}" ]]; then
  echo "- Use your current public IP as a single-host CIDR:"
  echo "  admin_allowed_cidrs = [\"${PUBLIC_IP}/32\"]"
else
  echo "- Could not detect a public IP automatically."
  echo "  Pass --public-ip x.x.x.x if you want a single-host suggestion."
fi

echo
echo "Private-network alternatives:"
if [[ -n "${FRONTEND_VPC_CIDR}" && "${FRONTEND_VPC_CIDR}" != "None" ]]; then
  echo "- Frontend VPC CIDR:"
  echo "  admin_allowed_cidrs = [\"${FRONTEND_VPC_CIDR}\"]"
fi
if [[ -n "${BACKEND_VPC_CIDR}" && "${BACKEND_VPC_CIDR}" != "None" ]]; then
  echo "- Backend VPC CIDR:"
  echo "  admin_allowed_cidrs = [\"${BACKEND_VPC_CIDR}\"]"
fi

echo
echo "Notes:"
echo "- Safest default: a single public /32 for your current workstation."
echo "- Use private CIDRs only if the admin UI will be reached over VPN, Direct Connect, bastion, or another trusted internal path."
echo "- If multiple admins or office egress IPs need access, add multiple CIDRs to the same list."
