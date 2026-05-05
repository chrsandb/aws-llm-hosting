#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: aws-preflight.sh [--region REGION] [--profile PROFILE] [--instance-type TYPE] \
  [--domain-name DOMAIN] [--route53-zone-id ZONE_ID] \
  [--frontend-vpc-id VPC_ID] [--backend-vpc-id VPC_ID] \
  [--packer-vars-file PATH]

Checks AWS-related local and account prerequisites for this repository:

- required local commands
- AWS CLI authentication and active identity
- active region and available availability zones
- Session Manager plugin presence
- read-only access to AWS services used by this repository
- whether the target GPU instance type is offered in the target region
- Route53 hosted zone presence for a supplied domain or zone ID
- frontend/backend VPC subnet shape and routing sanity checks
- EC2 service quota visibility for GPU families
- optional Packer build permission checks using a Packer vars file

Examples:
  ./scripts/aws-preflight.sh --region eu-north-1
  ./scripts/aws-preflight.sh --profile prod-admin --region eu-north-1
  ./scripts/aws-preflight.sh --region eu-north-1 --domain-name llm.example.com --frontend-vpc-id vpc-123 --backend-vpc-id vpc-456
  ./scripts/aws-preflight.sh --region eu-north-1 --packer-vars-file packer/backend.auto.pkrvars.hcl
EOF
}

REGION=""
PROFILE=""
INSTANCE_TYPE="g6e.2xlarge"
DOMAIN_NAME=""
ROUTE53_ZONE_ID=""
FRONTEND_VPC_ID=""
BACKEND_VPC_ID=""
PACKER_VARS_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
    --domain-name) DOMAIN_NAME="$2"; shift 2 ;;
    --route53-zone-id) ROUTE53_ZONE_ID="$2"; shift 2 ;;
    --frontend-vpc-id) FRONTEND_VPC_ID="$2"; shift 2 ;;
    --backend-vpc-id) BACKEND_VPC_ID="$2"; shift 2 ;;
    --packer-vars-file) PACKER_VARS_FILE="$2"; shift 2 ;;
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_STS_ERR="$(mktemp)"
TMP_VPC_ERR="$(mktemp)"
TMP_AZ_ERR="$(mktemp)"
TMP_INSTANCE_ERR="$(mktemp)"
trap 'rm -f "${TMP_STS_ERR}" "${TMP_VPC_ERR}" "${TMP_AZ_ERR}" "${TMP_INSTANCE_ERR}"' EXIT

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

check_script() {
  local path="$1"
  if [[ -x "${path}" ]]; then
    pass "script:$(basename "${path}")" "executable"
  else
    fail "script:$(basename "${path}")" "missing or not executable"
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

parse_hcl_string() {
  local key="$1"
  local path="$2"
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]+)\"[[:space:]]*$/\\1/p" "${path}" | head -n1
}

normalize_principal_arn() {
  local arn="$1"
  if [[ "${arn}" =~ ^arn:aws:sts::([0-9]+):assumed-role/([^/]+)/.+$ ]]; then
    printf 'arn:aws:iam::%s:role/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '%s\n' "${arn}"
  fi
}

check_ec2_dry_run() {
  local label="$1"
  shift
  local output
  if output="$(aws "${AWS_ARGS[@]}" ec2 "$@" --dry-run 2>&1)"; then
    pass "${label}" "ok"
  elif grep -qi "DryRunOperation" <<<"${output}"; then
    pass "${label}" "authorized"
  else
    fail "${label}" "$(tr '\n' ' ' <<<"${output}" | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
  fi
}

check_iam_simulation() {
  local source_arn="$1"
  shift
  local label="$1"
  shift
  local output
  if output="$(aws "${AWS_ARGS[@]}" iam simulate-principal-policy --policy-source-arn "${source_arn}" --action-names "$@" 2>&1)"; then
    local denied
    denied="$(jq -r '.EvaluationResults[] | select(.EvalDecision != "allowed") | .EvalActionName' <<<"${output}" | paste -sd ', ' -)"
    if [[ -z "${denied}" ]]; then
      pass "${label}" "simulated actions allowed"
    else
      warn "${label}" "simulation denied: ${denied}"
    fi
  else
    warn "${label}" "$(tr '\n' ' ' <<<"${output}" | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
  fi
}

check_aws_call_with_parse() {
  local label="$1"
  local success_detail="$2"
  shift 2

  if output="$(aws "${AWS_ARGS[@]}" "$@" 2>&1)"; then
    pass "${label}" "${success_detail}"
    printf '%s' "${output}" >&2
    return 0
  else
    fail "${label}" "$(tr '\n' ' ' <<<"${output}" | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
    return 1
  fi
}

check_hosted_zone() {
  local domain="$1"
  local zone_id="$2"
  local output

  if [[ -n "${zone_id}" ]]; then
    if output="$(aws "${AWS_ARGS[@]}" route53 get-hosted-zone --id "${zone_id}" 2>&1)"; then
      local zone_name
      zone_name="$(jq -r '.HostedZone.Name' <<<"${output}")"
      pass "route53:hosted-zone-id" "${zone_id} -> ${zone_name}"
    else
      fail "route53:hosted-zone-id" "$(tr '\n' ' ' <<<"${output}" | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
    fi
  fi

  if [[ -n "${domain}" ]]; then
    local fqdn="${domain%.}."
    if output="$(aws "${AWS_ARGS[@]}" route53 list-hosted-zones-by-name --dns-name "${domain}" --max-items 5 2>&1)"; then
      if jq -e --arg fqdn "${fqdn}" '.HostedZones | any(.Name == $fqdn)' <<<"${output}" >/dev/null; then
        pass "route53:domain-zone" "hosted zone exists for ${domain}"
      else
        warn "route53:domain-zone" "no exact hosted zone found for ${domain}"
      fi
    else
      fail "route53:domain-zone" "$(tr '\n' ' ' <<<"${output}" | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
    fi
  fi
}

check_quota_visibility() {
  local output
  if output="$(aws "${AWS_ARGS[@]}" service-quotas list-service-quotas --service-code ec2 2>&1)"; then
    pass "service-quotas:ec2" "visible"
    local gpu_quota
    gpu_quota="$(jq -r '
      .Quotas[]
      | select(
          .QuotaName
          | test("Running On-Demand G and VT instances|Running On-Demand G instances|Running On-Demand.*GPU"; "i")
        )
      | "\(.QuotaName)=\(.Value)"
    ' <<<"${output}" | head -n 1)"
    if [[ -n "${gpu_quota}" ]]; then
      pass "quota:g-vt-on-demand" "${gpu_quota}"
    else
      warn "quota:g-vt-on-demand" "no matching GPU quota name found in EC2 service quotas; review Service Quotas manually if needed"
    fi
  else
    warn "service-quotas:ec2" "$(tr '\n' ' ' <<<"${output}" | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
  fi
}

check_packer_build_permissions() {
  local pkrvars_path="$1"
  local build_subnet
  local build_sg
  local build_ami
  local build_vpc
  local build_instance_profile
  local ami_name_prefix
  local model_source
  local llama_cpp_image_tag
  local root_volume_encrypted
  local root_volume_kms_key_id
  local caller_role_arn
  local image_output
  local run_args=()

  if [[ ! -f "${pkrvars_path}" ]]; then
    fail "packer:vars-file" "not found: ${pkrvars_path}"
    return
  fi

  build_subnet="$(parse_hcl_string "subnet_id" "${pkrvars_path}")"
  build_sg="$(parse_hcl_string "security_group_id" "${pkrvars_path}")"
  build_ami="$(parse_hcl_string "source_ami_id" "${pkrvars_path}")"
  build_instance_profile="$(parse_hcl_string "packer_instance_profile_name" "${pkrvars_path}")"
  ami_name_prefix="$(parse_hcl_string "ami_name_prefix" "${pkrvars_path}")"
  model_source="$(parse_hcl_string "model_source" "${pkrvars_path}")"
  llama_cpp_image_tag="$(parse_hcl_string "llama_cpp_image_tag" "${pkrvars_path}")"
  root_volume_encrypted="$(sed -nE 's/^[[:space:]]*root_volume_encrypted[[:space:]]*=[[:space:]]*(true|false)[[:space:]]*$/\1/p' "${pkrvars_path}" | head -n1)"
  root_volume_kms_key_id="$(parse_hcl_string "root_volume_kms_key_id" "${pkrvars_path}")"
  root_volume_encrypted="${root_volume_encrypted:-true}"

  if [[ -z "${build_subnet}" || -z "${build_sg}" ]]; then
    fail "packer:vars-file" "subnet_id and security_group_id must be populated in ${pkrvars_path}"
    return
  fi

  if [[ -z "${build_ami}" ]]; then
    warn "packer:source-ami" "source_ami_id not set in ${pkrvars_path}; skipping exact RunInstances dry-run"
  else
    if image_output="$(aws "${AWS_ARGS[@]}" ec2 describe-images --image-ids "${build_ami}" --output json 2>&1)"; then
      pass "packer:source-ami" "${build_ami} visible"
    else
      fail "packer:source-ami" "$(tr '\n' ' ' <<<"${image_output}" | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
    fi
  fi

  build_vpc="$(aws "${AWS_ARGS[@]}" ec2 describe-subnets --subnet-ids "${build_subnet}" --query 'Subnets[0].VpcId' --output text 2>/dev/null || true)"
  if [[ -n "${build_vpc}" && "${build_vpc}" != "None" ]]; then
    pass "packer:subnet" "${build_subnet} in ${build_vpc}"
  else
    fail "packer:subnet" "unable to resolve ${build_subnet}"
  fi

  if aws "${AWS_ARGS[@]}" ec2 describe-security-groups --group-ids "${build_sg}" >/dev/null 2>&1; then
    pass "packer:security-group" "${build_sg} visible"
  else
    fail "packer:security-group" "${build_sg} not visible"
  fi

  if [[ -n "${build_instance_profile}" ]]; then
    if aws "${AWS_ARGS[@]}" iam get-instance-profile --instance-profile-name "${build_instance_profile}" >/dev/null 2>&1; then
      pass "packer:instance-profile" "${build_instance_profile} visible"
    else
      fail "packer:instance-profile" "${build_instance_profile} not visible"
    fi
  else
    warn "packer:instance-profile" "using temporary Packer role/profile flow"
  fi

  check_ec2_dry_run "packer:create-security-group" create-security-group \
    --group-name "preflight-dryrun-$(date +%s)" \
    --description "AWS preflight dry run" \
    --vpc-id "${build_vpc}"

  check_ec2_dry_run "packer:create-key-pair" create-key-pair \
    --key-name "preflight-dryrun-$(date +%s)"

  if [[ -n "${build_ami}" ]]; then
    run_args=(
      run-instances
      --image-id "${build_ami}"
      --instance-type "${INSTANCE_TYPE}"
      --subnet-id "${build_subnet}"
      --security-group-ids "${build_sg}"
      --metadata-options 'HttpEndpoint=enabled,HttpTokens=required,HttpPutResponseHopLimit=2'
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${ami_name_prefix:-llm-backend}-backend},{Key=ImageRole,Value=llama-backend},{Key=ManagedBy,Value=packer},{Key=ModelMode,Value=${model_source:-ebs_snapshot}},{Key=LlamaTag,Value=${llama_cpp_image_tag:-server-cuda}}]"
      --count 1
    )

    if [[ -n "${root_volume_kms_key_id}" ]]; then
      run_args+=(--block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":100,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true,\"Encrypted\":${root_volume_encrypted},\"KmsKeyId\":\"${root_volume_kms_key_id}\"}}]")
    else
      run_args+=(--block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":100,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true,\"Encrypted\":${root_volume_encrypted}}}]")
    fi

    if [[ -n "${build_instance_profile}" ]]; then
      run_args+=(--iam-instance-profile "Name=${build_instance_profile}")
    fi

    check_ec2_dry_run "packer:run-instances" "${run_args[@]}"
  fi

  caller_role_arn="$(normalize_principal_arn "${ARN}")"
  check_iam_simulation "${caller_role_arn}" "packer:iam-simulation" \
    iam:CreateRole \
    iam:DeleteRole \
    iam:CreateInstanceProfile \
    iam:DeleteInstanceProfile \
    iam:AddRoleToInstanceProfile \
    iam:RemoveRoleFromInstanceProfile \
    iam:AttachRolePolicy \
    iam:DetachRolePolicy \
    iam:PassRole
}

check_vpc_shape() {
  local role="$1"
  local vpc_id="$2"
  local vpc_json
  local common_args=()
  local public_count
  local private_count

  [[ -n "${PROFILE}" ]] && common_args+=(--profile "${PROFILE}")
  [[ -n "${ACTIVE_REGION}" ]] && common_args+=(--region "${ACTIVE_REGION}")

  if ! vpc_json="$("${SCRIPT_DIR}/discover-vpc-details.sh" --vpc-id "${vpc_id}" "${common_args[@]}" 2>"${TMP_VPC_ERR}")"; then
    fail "vpc:${role}" "$(tr '\n' ' ' <"${TMP_VPC_ERR}" | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
    return
  fi

  pass "vpc:${role}" "${vpc_id} inspected"

  public_count="$(jq '.summary.public_subnet_ids | length' <<<"${vpc_json}")"
  private_count="$(jq '.summary.private_subnet_ids | length' <<<"${vpc_json}")"

  if [[ "${role}" == "frontend" ]]; then
    if (( public_count >= 2 )); then
      pass "vpc:${role}:public-subnets" "${public_count} public subnets"
    else
      fail "vpc:${role}:public-subnets" "need at least 2 public subnets, found ${public_count}"
    fi

    if (( private_count >= 2 )); then
      pass "vpc:${role}:private-subnets" "${private_count} private subnets"
    else
      fail "vpc:${role}:private-subnets" "need at least 2 private subnets, found ${private_count}"
    fi
  else
    if (( private_count >= 2 )); then
      pass "vpc:${role}:private-subnets" "${private_count} private subnets"
    else
      fail "vpc:${role}:private-subnets" "need at least 2 private subnets, found ${private_count}"
    fi

    if (( public_count > 0 )); then
      warn "vpc:${role}:public-subnets" "${public_count} public subnets exist; backend should use private subnets only"
    else
      pass "vpc:${role}:public-subnets" "no public subnets inferred"
    fi
  fi

  local private_without_default
  private_without_default="$(jq '
    .route_tables as $rts
    | [
        .subnets[]
        | select(.inferred_type == "private")
        | .route_table_id as $rtid
        | select(
            any(
              $rts[]?
              | select(.route_table_id == $rtid)
              | .routes[]?;
              ((.DestinationCidrBlock // "") == "0.0.0.0/0") and
              (
                ((.NatGatewayId // "") != "") or
                ((.TransitGatewayId // "") != "") or
                ((.InstanceId // "") != "") or
                ((.VpcPeeringConnectionId // "") != "") or
                ((.NetworkInterfaceId // "") != "")
              )
            ) | not
          )
      ] | length
  ' <<<"${vpc_json}")"

  if [[ -n "${private_without_default}" && "${private_without_default}" != "0" ]]; then
    warn "vpc:${role}:private-egress" "${private_without_default} private subnet(s) lack obvious default egress via NAT/TGW/instance/ENI"
  else
    pass "vpc:${role}:private-egress" "private subnets have an apparent default egress path"
  fi
}

echo "AWS preflight checks"
echo

check_cmd aws
check_cmd jq
check_script "${SCRIPT_DIR}/discover-vpc-details.sh"
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

IDENTITY_JSON="$(aws "${AWS_ARGS[@]}" sts get-caller-identity 2>"${TMP_STS_ERR}" || true)"
if [[ -z "${IDENTITY_JSON}" ]]; then
  fail "sts:get-caller-identity" "$(tr '\n' ' ' <"${TMP_STS_ERR}" | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
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

AZ_JSON="$(aws "${AWS_ARGS[@]}" ec2 describe-availability-zones --all-availability-zones --output json 2>"${TMP_AZ_ERR}" || true)"
if [[ -n "${AZ_JSON}" ]]; then
  pass "ec2:availability-zones" "queried"
  AZ_COUNT="$(jq '.AvailabilityZones | length' <<<"${AZ_JSON}")"
  pass "ec2:availability-zones" "${AZ_COUNT} zones visible"
else
  fail "ec2:availability-zones" "$(tr '\n' ' ' <"${TMP_AZ_ERR}" | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
fi

check_aws_call "ec2:vpcs" ec2 describe-vpcs --max-items 5
check_aws_call "ec2:subnets" ec2 describe-subnets --max-items 5
check_aws_call "ec2:route-tables" ec2 describe-route-tables --max-items 5
check_aws_call "autoscaling:account-limits" autoscaling describe-account-limits
check_aws_call "elbv2:account-limits" elbv2 describe-account-limits
check_aws_call "ecs:list-clusters" ecs list-clusters --max-results 5
check_aws_call "rds:describe-db-instances" rds describe-db-instances --max-records 20
check_aws_call "secretsmanager:list-secrets" secretsmanager list-secrets --max-results 5
check_aws_call "ssm:describe-parameters" ssm describe-parameters --max-results 5
check_aws_call "acm:list-certificates" acm list-certificates --max-items 5
check_aws_call "route53:list-hosted-zones" route53 list-hosted-zones --max-items 5
check_aws_call "iam:get-account-summary" iam get-account-summary

check_quota_visibility

INSTANCE_JSON="$(aws "${AWS_ARGS[@]}" ec2 describe-instance-type-offerings --location-type region --filters "Name=instance-type,Values=${INSTANCE_TYPE}" --output json 2>"${TMP_INSTANCE_ERR}" || true)"
if [[ -n "${INSTANCE_JSON}" ]]; then
  pass "ec2:instance-type-offerings" "queried"
  OFFER_COUNT="$(jq '.InstanceTypeOfferings | length' <<<"${INSTANCE_JSON}")"
  if (( OFFER_COUNT > 0 )); then
    pass "instance-type:${INSTANCE_TYPE}" "offered in ${ACTIVE_REGION}"
  else
    warn "instance-type:${INSTANCE_TYPE}" "not returned for ${ACTIVE_REGION}"
  fi
else
  fail "ec2:instance-type-offerings" "$(tr '\n' ' ' <"${TMP_INSTANCE_ERR}" | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
fi

if [[ -n "${DOMAIN_NAME}" || -n "${ROUTE53_ZONE_ID}" ]]; then
  check_hosted_zone "${DOMAIN_NAME}" "${ROUTE53_ZONE_ID}"
fi

if [[ -n "${FRONTEND_VPC_ID}" ]]; then
  check_vpc_shape "frontend" "${FRONTEND_VPC_ID}"
fi

if [[ -n "${BACKEND_VPC_ID}" ]]; then
  check_vpc_shape "backend" "${BACKEND_VPC_ID}"
fi

if [[ -n "${PACKER_VARS_FILE}" ]]; then
  check_packer_build_permissions "${PACKER_VARS_FILE}"
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
