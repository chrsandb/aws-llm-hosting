#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: aws-preflight.sh [--region REGION] [--profile PROFILE] [--instance-type TYPE]

Checks AWS-related local and account prerequisites for this repository:

- required local commands
- AWS CLI authentication and active identity
- active region and available availability zones
- Session Manager plugin presence
- read-only access to AWS services used by this repository
- whether the target GPU instance type is offered in the target region

Examples:
  ./scripts/aws-preflight.sh --region eu-north-1
  ./scripts/aws-preflight.sh --profile prod-admin --region eu-north-1
EOF
}

REGION=""
PROFILE=""
INSTANCE_TYPE="g6e.2xlarge"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
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

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
FAILURES=()

status_line() {
  local level="$1"
  local label="$2"
  local detail="$3"
  printf "%-5s %-26s %s\n" "${level}" "${label}" "${detail}"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  status_line "PASS" "$1" "$2"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  status_line "WARN" "$1" "$2"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILURES+=("$1: $2")
  status_line "FAIL" "$1" "$2"
}

check_cmd() {
  local cmd="$1"
  if command -v "${cmd}" >/dev/null 2>&1; then
    pass "command:${cmd}" "found"
  else
    fail "command:${cmd}" "missing from PATH"
  fi
}

check_optional_cmd() {
  local cmd="$1"
  if command -v "${cmd}" >/dev/null 2>&1; then
    pass "command:${cmd}" "found"
  else
    warn "command:${cmd}" "missing from PATH"
  fi
}

check_aws_call() {
  local label="$1"
  shift

  if output="$(aws "${AWS_ARGS[@]}" "$@" 2>&1)"; then
    pass "${label}" "ok"
  else
    fail "${label}" "$(tr '\n' ' ' <<<"${output}" | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
  fi
}

check_aws_call_with_parse() {
  local label="$1"
  local success_detail="$2"
  shift 2

  if output="$(aws "${AWS_ARGS[@]}" "$@" 2>&1)"; then
    pass "${label}" "${success_detail}"
    printf '%s' "${output}"
    return 0
  else
    fail "${label}" "$(tr '\n' ' ' <<<"${output}" | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
    return 1
  fi
}

echo "AWS preflight checks"
echo

check_cmd aws
check_cmd jq
check_optional_cmd session-manager-plugin
check_optional_cmd terraform
check_optional_cmd packer

if (( FAIL_COUNT > 0 )); then
  echo
  echo "Stopping early because required local commands are missing."
  exit 1
fi

AWS_VERSION_RAW="$(aws --version 2>&1 || true)"
if [[ "${AWS_VERSION_RAW}" == aws-cli/2* ]]; then
  pass "aws-cli-version" "${AWS_VERSION_RAW}"
else
  warn "aws-cli-version" "expected AWS CLI v2, got: ${AWS_VERSION_RAW}"
fi

if command -v session-manager-plugin >/dev/null 2>&1; then
  SMP_VERSION="$(session-manager-plugin --version 2>&1 || true)"
  pass "session-manager-plugin" "${SMP_VERSION:-installed}"
else
  warn "session-manager-plugin" "required for aws ssm start-session"
fi

IDENTITY_JSON="$(aws "${AWS_ARGS[@]}" sts get-caller-identity 2>/tmp/aws-preflight-sts.err || true)"
if [[ -z "${IDENTITY_JSON}" ]]; then
  fail "sts:get-caller-identity" "$(tr '\n' ' ' </tmp/aws-preflight-sts.err | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
  echo
  echo "Preflight failed before AWS service checks."
  exit 1
fi

ACCOUNT_ID="$(jq -r '.Account' <<<"${IDENTITY_JSON}")"
ARN="$(jq -r '.Arn' <<<"${IDENTITY_JSON}")"
USER_ID="$(jq -r '.UserId' <<<"${IDENTITY_JSON}")"
ACTIVE_REGION="${REGION:-$(aws "${AWS_ARGS[@]}" configure get region || true)}"

pass "sts:get-caller-identity" "account ${ACCOUNT_ID}"

if [[ -n "${ACTIVE_REGION}" ]]; then
  pass "region" "${ACTIVE_REGION}"
else
  fail "region" "no region configured; pass --region or set AWS region config"
fi

if (( FAIL_COUNT > 0 )); then
  echo
  echo "Preflight failed before AWS service checks."
  exit 1
fi

AZ_JSON="$(check_aws_call_with_parse "ec2:availability-zones" "queried" ec2 describe-availability-zones --all-availability-zones --output json || true)"
if [[ -n "${AZ_JSON}" ]]; then
  AZ_COUNT="$(jq '.AvailabilityZones | length' <<<"${AZ_JSON}")"
  pass "ec2:availability-zones" "${AZ_COUNT} zones visible"
fi

check_aws_call "ec2:vpcs" ec2 describe-vpcs --max-items 5
check_aws_call "ec2:subnets" ec2 describe-subnets --max-items 5
check_aws_call "ec2:route-tables" ec2 describe-route-tables --max-items 5
check_aws_call "autoscaling:account-limits" autoscaling describe-account-limits
check_aws_call "elbv2:account-limits" elbv2 describe-account-limits
check_aws_call "ecs:list-clusters" ecs list-clusters --max-results 5
check_aws_call "rds:describe-db-instances" rds describe-db-instances --max-records 5
check_aws_call "secretsmanager:list-secrets" secretsmanager list-secrets --max-results 5
check_aws_call "ssm:describe-parameters" ssm describe-parameters --max-results 5
check_aws_call "acm:list-certificates" acm list-certificates --max-items 5
check_aws_call "route53:list-hosted-zones" route53 list-hosted-zones --max-items 5
check_aws_call "iam:get-account-summary" iam get-account-summary

INSTANCE_JSON="$(check_aws_call_with_parse "ec2:instance-type-offerings" "queried" ec2 describe-instance-type-offerings --location-type region --filters "Name=instance-type,Values=${INSTANCE_TYPE}" --output json || true)"
if [[ -n "${INSTANCE_JSON}" ]]; then
  OFFER_COUNT="$(jq '.InstanceTypeOfferings | length' <<<"${INSTANCE_JSON}")"
  if (( OFFER_COUNT > 0 )); then
    pass "instance-type:${INSTANCE_TYPE}" "offered in ${ACTIVE_REGION}"
  else
    warn "instance-type:${INSTANCE_TYPE}" "not returned for ${ACTIVE_REGION}"
  fi
fi

echo
cat <<EOF
Identity summary
Account ID : ${ACCOUNT_ID}
Caller ARN : ${ARN}
User ID    : ${USER_ID}
Region     : ${ACTIVE_REGION}
Profile    : ${PROFILE:-<default>}
EOF

echo
cat <<EOF
Totals
Pass : ${PASS_COUNT}
Warn : ${WARN_COUNT}
Fail : ${FAIL_COUNT}
EOF

if (( FAIL_COUNT > 0 )); then
  echo
  echo "Failures:"
  for item in "${FAILURES[@]}"; do
    echo "- ${item}"
  done
  exit 1
fi
