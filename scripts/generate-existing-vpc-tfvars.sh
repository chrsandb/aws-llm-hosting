#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: generate-existing-vpc-tfvars.sh \
  --frontend-vpc-id VPC_ID \
  --backend-vpc-id VPC_ID \
  --project-name NAME \
  --environment ENV \
  --domain-name DOMAIN \
  [--route53-zone-id ZONE_ID] \
  [--region REGION] \
  [--profile PROFILE]

Discovers subnet and route table inputs for two existing VPCs and prints a
starter tfvars file to stdout.
EOF
}

FRONTEND_VPC_ID=""
BACKEND_VPC_ID=""
PROJECT_NAME=""
ENVIRONMENT=""
DOMAIN_NAME=""
ROUTE53_ZONE_ID=""
REGION="eu-north-1"
PROFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --frontend-vpc-id) FRONTEND_VPC_ID="$2"; shift 2 ;;
    --backend-vpc-id) BACKEND_VPC_ID="$2"; shift 2 ;;
    --project-name) PROJECT_NAME="$2"; shift 2 ;;
    --environment) ENVIRONMENT="$2"; shift 2 ;;
    --domain-name) DOMAIN_NAME="$2"; shift 2 ;;
    --route53-zone-id) ROUTE53_ZONE_ID="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "${FRONTEND_VPC_ID}" || -z "${BACKEND_VPC_ID}" || -z "${PROJECT_NAME}" || -z "${ENVIRONMENT}" || -z "${DOMAIN_NAME}" ]]; then
  usage
  exit 1
fi

for cmd in jq; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_ARGS=(--region "${REGION}")
if [[ -n "${PROFILE}" ]]; then
  COMMON_ARGS+=(--profile "${PROFILE}")
fi

FRONTEND_JSON="$("${SCRIPT_DIR}/discover-vpc-details.sh" --vpc-id "${FRONTEND_VPC_ID}" "${COMMON_ARGS[@]}")"
BACKEND_JSON="$("${SCRIPT_DIR}/discover-vpc-details.sh" --vpc-id "${BACKEND_VPC_ID}" "${COMMON_ARGS[@]}")"

format_array() {
  jq -r 'map(@json) | join(", ")'
}

FRONTEND_PUBLIC_SUBNETS="$(jq -r '.summary.public_subnet_ids' <<<"${FRONTEND_JSON}" | format_array)"
FRONTEND_PRIVATE_SUBNETS="$(jq -r '.summary.private_subnet_ids' <<<"${FRONTEND_JSON}" | format_array)"
FRONTEND_ROUTE_TABLES="$(jq -r '.summary.route_table_ids' <<<"${FRONTEND_JSON}" | format_array)"
BACKEND_PRIVATE_SUBNETS="$(jq -r '.summary.private_subnet_ids' <<<"${BACKEND_JSON}" | format_array)"
BACKEND_ROUTE_TABLES="$(jq -r '.summary.route_table_ids' <<<"${BACKEND_JSON}" | format_array)"

if [[ -n "${ROUTE53_ZONE_ID}" ]]; then
  ROUTE53_ZONE_LITERAL="\"${ROUTE53_ZONE_ID}\""
else
  ROUTE53_ZONE_LITERAL="null"
fi

cat <<EOF
aws_region   = "${REGION}"
project_name = "${PROJECT_NAME}"
environment  = "${ENVIRONMENT}"
domain_name  = "${DOMAIN_NAME}"

create_route53_zone = false
route53_zone_id     = ${ROUTE53_ZONE_LITERAL}

frontend_vpc_id             = "${FRONTEND_VPC_ID}"
frontend_public_subnet_ids  = [${FRONTEND_PUBLIC_SUBNETS}]
frontend_private_subnet_ids = [${FRONTEND_PRIVATE_SUBNETS}]
frontend_route_table_ids    = [${FRONTEND_ROUTE_TABLES}]

backend_vpc_id             = "${BACKEND_VPC_ID}"
backend_private_subnet_ids = [${BACKEND_PRIVATE_SUBNETS}]
backend_route_table_ids    = [${BACKEND_ROUTE_TABLES}]

assume_existing_vpc_routing = true

# Fill these in after AMI and model preparation.
backend_ami_id        = "ami-REPLACE_ME"
model_ebs_snapshot_id = "snap-REPLACE_ME"
EOF
