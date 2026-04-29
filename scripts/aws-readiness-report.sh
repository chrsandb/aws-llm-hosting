#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: aws-readiness-report.sh --region REGION [options]

Generates a Markdown deployment-readiness report for this repository.

Options:
  --profile PROFILE
  --instance-type TYPE
  --domain-name DOMAIN
  --route53-zone-id ZONE_ID
  --frontend-vpc-id VPC_ID
  --backend-vpc-id VPC_ID
  --output FILE

Examples:
  ./scripts/aws-readiness-report.sh --region eu-north-1
  ./scripts/aws-readiness-report.sh \
    --region eu-north-1 \
    --domain-name llm.example.com \
    --route53-zone-id Z1234567890EXAMPLE \
    --frontend-vpc-id vpc-frontend123 \
    --backend-vpc-id vpc-backend123 \
    --output docs/readiness-report.md
EOF
}

REGION=""
PROFILE=""
INSTANCE_TYPE="g6e.2xlarge"
DOMAIN_NAME=""
ROUTE53_ZONE_ID=""
FRONTEND_VPC_ID=""
BACKEND_VPC_ID=""
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
    --domain-name) DOMAIN_NAME="$2"; shift 2 ;;
    --route53-zone-id) ROUTE53_ZONE_ID="$2"; shift 2 ;;
    --frontend-vpc-id) FRONTEND_VPC_ID="$2"; shift 2 ;;
    --backend-vpc-id) BACKEND_VPC_ID="$2"; shift 2 ;;
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "${REGION}" ]]; then
  usage
  exit 1
fi

for cmd in aws jq; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWS_ARGS=(--region "${REGION}")
if [[ -n "${PROFILE}" ]]; then
  AWS_ARGS+=(--profile "${PROFILE}")
fi

REPORT_TMP="$(mktemp)"
trap 'rm -f "${REPORT_TMP}"' EXIT

status_emoji() {
  case "$1" in
    pass) echo "PASS" ;;
    warn) echo "WARN" ;;
    fail) echo "FAIL" ;;
    *) echo "INFO" ;;
  esac
}

add_check() {
  local status="$1"
  local area="$2"
  local detail="$3"
  printf "| %s | %s | %s |\n" "$(status_emoji "${status}")" "${area}" "${detail}" >>"${REPORT_TMP}"
}

call_aws() {
  aws "${AWS_ARGS[@]}" "$@"
}

safe_call_json() {
  local __var_name="$1"
  shift
  local output
  if output="$(call_aws "$@" 2>/dev/null)"; then
    printf -v "${__var_name}" '%s' "${output}"
    return 0
  fi
  return 1
}

STARTED_AT="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
AWS_VERSION="$(aws --version 2>&1 || true)"
IDENTITY_JSON="$(call_aws sts get-caller-identity)"
ACCOUNT_ID="$(jq -r '.Account' <<<"${IDENTITY_JSON}")"
CALLER_ARN="$(jq -r '.Arn' <<<"${IDENTITY_JSON}")"
USER_ID="$(jq -r '.UserId' <<<"${IDENTITY_JSON}")"

cat >"${REPORT_TMP}" <<EOF
# AWS Readiness Report

Generated: ${STARTED_AT}

## Scope

- Region: \`${REGION}\`
- Profile: \`${PROFILE:-<default>}\`
- Account ID: \`${ACCOUNT_ID}\`
- Caller ARN: \`${CALLER_ARN}\`
- User ID: \`${USER_ID}\`
- Target GPU instance type: \`${INSTANCE_TYPE}\`
- Domain: \`${DOMAIN_NAME:-<not provided>}\`
- Route53 zone ID: \`${ROUTE53_ZONE_ID:-<not provided>}\`
- Frontend VPC: \`${FRONTEND_VPC_ID:-<not provided>}\`
- Backend VPC: \`${BACKEND_VPC_ID:-<not provided>}\`

## Local Tooling

| Status | Check | Detail |
|---|---|---|
EOF

if [[ "${AWS_VERSION}" == aws-cli/2* ]]; then
  add_check pass "AWS CLI v2" "\`${AWS_VERSION}\`"
else
  add_check warn "AWS CLI version" "\`${AWS_VERSION}\`"
fi

if command -v session-manager-plugin >/dev/null 2>&1; then
  add_check pass "Session Manager plugin" "\`$(session-manager-plugin --version 2>&1 || echo installed)\`"
else
  add_check warn "Session Manager plugin" "not installed"
fi

if command -v terraform >/dev/null 2>&1; then
  add_check pass "Terraform" "\`$(terraform version | head -n 1)\`"
else
  add_check warn "Terraform" "not found in PATH"
fi

if command -v packer >/dev/null 2>&1; then
  add_check pass "Packer" "\`$(packer version)\`"
else
  add_check warn "Packer" "not found in PATH"
fi

cat >>"${REPORT_TMP}" <<'EOF'

## AWS Service Reachability

| Status | Check | Detail |
|---|---|---|
EOF

check_service() {
  local area="$1"
  shift
  if call_aws "$@" >/dev/null 2>&1; then
    add_check pass "${area}" "ok"
  else
    add_check fail "${area}" "call failed"
  fi
}

check_service "STS identity" sts get-caller-identity
check_service "EC2 VPC read" ec2 describe-vpcs --max-items 5
check_service "EC2 subnet read" ec2 describe-subnets --max-items 5
check_service "Auto Scaling read" autoscaling describe-account-limits
check_service "ELBv2 read" elbv2 describe-account-limits
check_service "ECS read" ecs list-clusters --max-results 5
check_service "RDS read" rds describe-db-instances --max-records 5
check_service "Secrets Manager read" secretsmanager list-secrets --max-results 5
check_service "SSM read" ssm describe-parameters --max-results 5
check_service "ACM read" acm list-certificates --max-items 5
check_service "Route53 read" route53 list-hosted-zones --max-items 5

cat >>"${REPORT_TMP}" <<'EOF'

## Region and Capacity

| Status | Check | Detail |
|---|---|---|
EOF

if safe_call_json AZ_JSON ec2 describe-availability-zones --all-availability-zones --output json; then
  AZ_COUNT="$(jq '.AvailabilityZones | length' <<<"${AZ_JSON}")"
  add_check pass "Availability zones" "${AZ_COUNT} visible"
else
  add_check fail "Availability zones" "query failed"
fi

if safe_call_json INSTANCE_JSON ec2 describe-instance-type-offerings --location-type region --filters "Name=instance-type,Values=${INSTANCE_TYPE}" --output json; then
  OFFER_COUNT="$(jq '.InstanceTypeOfferings | length' <<<"${INSTANCE_JSON}")"
  if (( OFFER_COUNT > 0 )); then
    add_check pass "Instance type offering" "\`${INSTANCE_TYPE}\` is offered in \`${REGION}\`"
  else
    add_check warn "Instance type offering" "\`${INSTANCE_TYPE}\` was not returned for \`${REGION}\`"
  fi
else
  add_check fail "Instance type offering" "query failed"
fi

if safe_call_json QUOTA_JSON service-quotas list-service-quotas --service-code ec2 --max-results 100; then
  GPU_QUOTA="$(jq -r '.Quotas[] | select(.QuotaName | test("Running On-Demand G and VT instances")) | "\(.QuotaName)=\(.Value)"' <<<"${QUOTA_JSON}" | head -n 1)"
  if [[ -n "${GPU_QUOTA}" ]]; then
    add_check pass "GPU service quota" "${GPU_QUOTA}"
  else
    add_check warn "GPU service quota" "quota not found in first page of Service Quotas response"
  fi
else
  add_check warn "GPU service quota" "Service Quotas call failed"
fi

cat >>"${REPORT_TMP}" <<'EOF'

## DNS and Hosted Zone

| Status | Check | Detail |
|---|---|---|
EOF

if [[ -n "${ROUTE53_ZONE_ID}" ]]; then
  if safe_call_json ZONE_JSON route53 get-hosted-zone --id "${ROUTE53_ZONE_ID}"; then
    add_check pass "Hosted zone ID" "\`${ROUTE53_ZONE_ID}\` -> \`$(jq -r '.HostedZone.Name' <<<"${ZONE_JSON}")\`"
  else
    add_check fail "Hosted zone ID" "\`${ROUTE53_ZONE_ID}\` lookup failed"
  fi
else
  add_check warn "Hosted zone ID" "not provided"
fi

if [[ -n "${DOMAIN_NAME}" ]]; then
  if safe_call_json DOMAIN_ZONE_JSON route53 list-hosted-zones-by-name --dns-name "${DOMAIN_NAME}" --max-items 5; then
    if jq -e --arg fqdn "${DOMAIN_NAME%.}." '.HostedZones | any(.Name == $fqdn)' <<<"${DOMAIN_ZONE_JSON}" >/dev/null; then
      add_check pass "Domain hosted zone" "hosted zone exists for \`${DOMAIN_NAME}\`"
    else
      add_check warn "Domain hosted zone" "no exact hosted zone found for \`${DOMAIN_NAME}\`"
    fi
  else
    add_check fail "Domain hosted zone" "lookup failed for \`${DOMAIN_NAME}\`"
  fi
else
  add_check warn "Domain hosted zone" "not provided"
fi

render_vpc_section() {
  local role="$1"
  local vpc_id="$2"
  local vpc_json=""

  cat >>"${REPORT_TMP}" <<EOF

## ${role^} VPC

| Status | Check | Detail |
|---|---|---|
EOF

  if [[ -z "${vpc_id}" ]]; then
    add_check warn "${role} VPC" "not provided"
    return
  fi

  if ! vpc_json="$("${SCRIPT_DIR}/discover-vpc-details.sh" --vpc-id "${vpc_id}" "${AWS_ARGS[@]}" 2>/dev/null)"; then
    add_check fail "${role} VPC" "inspection failed for \`${vpc_id}\`"
    return
  fi

  local cidr public_count private_count rt_count
  cidr="$(jq -r '.vpc.cidr_block' <<<"${vpc_json}")"
  public_count="$(jq '.summary.public_subnet_ids | length' <<<"${vpc_json}")"
  private_count="$(jq '.summary.private_subnet_ids | length' <<<"${vpc_json}")"
  rt_count="$(jq '.summary.route_table_ids | length' <<<"${vpc_json}")"

  add_check pass "${role} VPC" "\`${vpc_id}\` CIDR \`${cidr}\`"
  add_check pass "${role} route tables" "${rt_count} route table(s)"

  if [[ "${role}" == "frontend" ]]; then
    if (( public_count >= 2 )); then
      add_check pass "Frontend public subnets" "${public_count}"
    else
      add_check fail "Frontend public subnets" "need at least 2, found ${public_count}"
    fi
    if (( private_count >= 2 )); then
      add_check pass "Frontend private subnets" "${private_count}"
    else
      add_check fail "Frontend private subnets" "need at least 2, found ${private_count}"
    fi
  else
    if (( private_count >= 2 )); then
      add_check pass "Backend private subnets" "${private_count}"
    else
      add_check fail "Backend private subnets" "need at least 2, found ${private_count}"
    fi
    if (( public_count > 0 )); then
      add_check warn "Backend public subnets" "${public_count} public subnet(s) detected; backend should remain private-only"
    else
      add_check pass "Backend public subnets" "none inferred"
    fi
  fi

  cat >>"${REPORT_TMP}" <<EOF

Detected subnets for \`${role}\` VPC:

| Subnet ID | AZ | CIDR | Inferred Type | Route Table |
|---|---|---|---|---|
EOF
  jq -r '.subnets[] | "| `\(.subnet_id)` | `\(.availability_zone)` | `\(.cidr_block)` | \(.inferred_type) | `\(.route_table_id // "none")` |"' <<<"${vpc_json}" >>"${REPORT_TMP}"
}

render_vpc_section "frontend" "${FRONTEND_VPC_ID}"
render_vpc_section "backend" "${BACKEND_VPC_ID}"

cat >>"${REPORT_TMP}" <<'EOF'

## Recommended Next Steps

1. Resolve all `FAIL` checks before running Terraform.
2. Review all `WARN` items and decide whether they are expected for your environment.
3. Generate or update a deployment tfvars file with `scripts/generate-existing-vpc-tfvars.sh`.
4. Prepare the backend AMI and model snapshot IDs.
5. Create or rotate the LiteLLM master key secret if Terraform will not generate it.
6. Run `make init`, `make plan`, and `make apply`.
EOF

if [[ -n "${OUTPUT_FILE}" ]]; then
  mkdir -p "$(dirname "${OUTPUT_FILE}")"
  cp "${REPORT_TMP}" "${OUTPUT_FILE}"
  echo "Wrote Markdown readiness report to ${OUTPUT_FILE}"
else
  cat "${REPORT_TMP}"
fi
