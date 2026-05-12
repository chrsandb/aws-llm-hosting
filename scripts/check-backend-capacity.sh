#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  check-backend-capacity.sh --region REGION --tfvars FILE [options]

Probe live EC2 capacity for the backend instance type by attempting a short-
lived instance launch in each candidate backend private subnet.

This is more useful than a dry-run because AWS does not expose a reliable
read-only "capacity available in this AZ right now" API for On-Demand GPU
instances. A successful probe is still not a guarantee; capacity can change
before Terraform apply.

Options:
  --region REGION              AWS region
  --tfvars FILE                Terraform tfvars file with backend VPC/subnets
  --profile PROFILE            AWS CLI profile
  --instance-type TYPE         Override backend instance type
  --helper-ami-id AMI_ID       AMI to use for the probe, default: ami-00e2c2ccdcd58e2ba
  --subnet-id SUBNET_ID        Probe only this subnet; repeatable
  --keep-probe-instance        Do not terminate the successful probe instance
  --help                       Show this help text

Example:
  ./scripts/check-backend-capacity.sh \
    --region eu-north-1 \
    --tfvars examples/generated.prod.tfvars
EOF
}

parse_tfvars_string() {
  local key="$1"
  local path="$2"
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]+)\"([[:space:]]*#.*)?$/\\1/p" "${path}" | head -n1
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

REGION=""
TFVARS=""
PROFILE=""
INSTANCE_TYPE=""
HELPER_AMI_ID="ami-00e2c2ccdcd58e2ba"
KEEP_PROBE_INSTANCE="false"
SUBNET_IDS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --tfvars) TFVARS="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
    --helper-ami-id) HELPER_AMI_ID="$2"; shift 2 ;;
    --subnet-id) SUBNET_IDS+=("$2"); shift 2 ;;
    --keep-probe-instance) KEEP_PROBE_INSTANCE="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${REGION}" || -z "${TFVARS}" ]]; then
  usage >&2
  exit 1
fi

if [[ ! -f "${TFVARS}" ]]; then
  echo "tfvars file not found: ${TFVARS}" >&2
  exit 1
fi

for cmd in aws python3 jq; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
done

AWS_ARGS=(--region "${REGION}")
if [[ -n "${PROFILE}" ]]; then
  AWS_ARGS+=(--profile "${PROFILE}")
fi

BACKEND_VPC_ID="$(parse_tfvars_string "backend_vpc_id" "${TFVARS}")"
INSTANCE_TYPE="${INSTANCE_TYPE:-$(parse_tfvars_string "backend_instance_type" "${TFVARS}")}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g6e.2xlarge}"

if [[ ${#SUBNET_IDS[@]} -eq 0 ]]; then
  while IFS= read -r subnet_id; do
    [[ -n "${subnet_id}" ]] && SUBNET_IDS+=("${subnet_id}")
  done < <(parse_tfvars_array "backend_private_subnet_ids" "${TFVARS}")
fi

if [[ -z "${BACKEND_VPC_ID}" || ${#SUBNET_IDS[@]} -eq 0 ]]; then
  echo "backend_vpc_id and at least one backend_private_subnet_ids entry are required in ${TFVARS}." >&2
  exit 1
fi

TEMP_SG_NAME="backend-capacity-probe-$(date +%Y%m%d%H%M%S)"
TEMP_SG_ID=""
PROBE_INSTANCE_ID=""

cleanup() {
  if [[ "${KEEP_PROBE_INSTANCE}" != "true" && -n "${PROBE_INSTANCE_ID}" ]]; then
    aws "${AWS_ARGS[@]}" ec2 terminate-instances --instance-ids "${PROBE_INSTANCE_ID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${TEMP_SG_ID}" ]]; then
    aws "${AWS_ARGS[@]}" ec2 delete-security-group --group-id "${TEMP_SG_ID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

TEMP_SG_ID="$(aws "${AWS_ARGS[@]}" ec2 create-security-group \
  --group-name "${TEMP_SG_NAME}" \
  --description "Temporary SG for backend capacity probes" \
  --vpc-id "${BACKEND_VPC_ID}" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${TEMP_SG_NAME}},{Key=ManagedBy,Value=check-backend-capacity.sh},{Key=Role,Value=capacity-probe}]" \
  --query 'GroupId' \
  --output text)"

echo "Checking live ${INSTANCE_TYPE} capacity in ${#SUBNET_IDS[@]} backend subnet(s)..."
echo

SUCCESSFUL_SUBNETS=()
FAILED_SUBNETS=()

for subnet_id in "${SUBNET_IDS[@]}"; do
  az="$(aws "${AWS_ARGS[@]}" ec2 describe-subnets --subnet-ids "${subnet_id}" --query 'Subnets[0].AvailabilityZone' --output text 2>/dev/null || true)"
  echo "Probing ${subnet_id} (${az:-unknown AZ})..."

  set +e
  launch_output="$(aws "${AWS_ARGS[@]}" ec2 run-instances \
    --image-id "${HELPER_AMI_ID}" \
    --instance-type "${INSTANCE_TYPE}" \
    --subnet-id "${subnet_id}" \
    --security-group-ids "${TEMP_SG_ID}" \
    --metadata-options 'HttpEndpoint=enabled,HttpTokens=required,HttpPutResponseHopLimit=2' \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3","DeleteOnTermination":true,"Encrypted":true}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=backend-capacity-probe},{Key=ManagedBy,Value=check-backend-capacity.sh},{Key=Role,Value=capacity-probe}]" \
    --query 'Instances[0].InstanceId' \
    --output text 2>&1)"
  rc=$?
  set -e

  if (( rc == 0 )); then
    PROBE_INSTANCE_ID="${launch_output}"
    SUCCESSFUL_SUBNETS+=("${subnet_id}|${az}")
    echo "  PASS  launched probe instance ${PROBE_INSTANCE_ID}"
    if [[ "${KEEP_PROBE_INSTANCE}" != "true" ]]; then
      aws "${AWS_ARGS[@]}" ec2 terminate-instances --instance-ids "${PROBE_INSTANCE_ID}" >/dev/null 2>&1 || true
      echo "  PASS  termination requested for ${PROBE_INSTANCE_ID}"
      PROBE_INSTANCE_ID=""
    fi
  else
    compact="$(tr '\n' ' ' <<<"${launch_output}" | sed 's/[[:space:]]\+/ /g')"
    FAILED_SUBNETS+=("${subnet_id}|${az}|${compact}")
    echo "  FAIL  ${compact}"
  fi
done

echo
if (( ${#SUCCESSFUL_SUBNETS[@]} > 0 )); then
  echo "Capacity probe summary:"
  for entry in "${SUCCESSFUL_SUBNETS[@]}"; do
    IFS='|' read -r subnet_id az <<<"${entry}"
    echo "  PASS  ${subnet_id} (${az})"
  done
  if (( ${#FAILED_SUBNETS[@]} > 0 )); then
    echo
    echo "Unavailable or failing subnets right now:"
    for entry in "${FAILED_SUBNETS[@]}"; do
      IFS='|' read -r subnet_id az message <<<"${entry}"
      echo "  FAIL  ${subnet_id} (${az}): ${message}"
    done
  fi
  echo
  echo "Notes:"
  echo "- This is a point-in-time check only; EC2 capacity can still change before terraform apply."
  echo "- If only some subnets succeed, consider temporarily prioritizing or restricting backend_private_subnet_ids to the successful AZs for the initial deployment."
  exit 0
fi

echo "No candidate backend subnet could launch ${INSTANCE_TYPE} right now." >&2
for entry in "${FAILED_SUBNETS[@]}"; do
  IFS='|' read -r subnet_id az message <<<"${entry}"
  echo "  ${subnet_id} (${az}): ${message}" >&2
done
exit 1
