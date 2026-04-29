#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: cleanup-deployment.sh [options]

Destroys Terraform-managed resources for this repository and optionally removes
image artifacts that were created outside Terraform.

Safe defaults:
- destroys only resources tracked in Terraform state
- refuses to proceed if Terraform state contains managed VPC/network resources,
  unless you explicitly allow it
- does not delete pre-existing VPCs, subnets, route tables, or hosted zones
- does not delete manually created AMIs or snapshots unless you pass them in

Options:
  --tfvars FILE
  --terraform-dir DIR
  --region REGION
  --profile PROFILE
  --delete-ami-id AMI_ID
  --delete-snapshot-id SNAPSHOT_ID
  --delete-volume-id VOLUME_ID
  --allow-network-destroy
  --force

Examples:
  ./scripts/cleanup-deployment.sh --tfvars examples/generated.prod.tfvars
  ./scripts/cleanup-deployment.sh \
    --tfvars examples/generated.prod.tfvars \
    --delete-ami-id ami-0123456789abcdef0 \
    --delete-snapshot-id snap-0123456789abcdef0 \
    --force
EOF
}

TFVARS=""
TERRAFORM_DIR="terraform"
REGION=""
PROFILE=""
ALLOW_NETWORK_DESTROY="false"
FORCE="false"

DELETE_AMI_IDS=()
DELETE_SNAPSHOT_IDS=()
DELETE_VOLUME_IDS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tfvars) TFVARS="$2"; shift 2 ;;
    --terraform-dir) TERRAFORM_DIR="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --delete-ami-id) DELETE_AMI_IDS+=("$2"); shift 2 ;;
    --delete-snapshot-id) DELETE_SNAPSHOT_IDS+=("$2"); shift 2 ;;
    --delete-volume-id) DELETE_VOLUME_IDS+=("$2"); shift 2 ;;
    --allow-network-destroy) ALLOW_NETWORK_DESTROY="true"; shift ;;
    --force) FORCE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "${TFVARS}" ]]; then
  usage
  exit 1
fi

if [[ ! -f "${TFVARS}" ]]; then
  echo "tfvars file not found: ${TFVARS}" >&2
  exit 1
fi

TFVARS_ABS="$(cd "$(dirname "${TFVARS}")" && pwd)/$(basename "${TFVARS}")"

for cmd in terraform aws; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
done

AWS_ARGS=()
if [[ -n "${PROFILE}" ]]; then
  AWS_ARGS+=(--profile "${PROFILE}")
fi
if [[ -n "${REGION}" ]]; then
  AWS_ARGS+=(--region "${REGION}")
fi

echo "Initializing Terraform in ${TERRAFORM_DIR}..."
terraform -chdir="${TERRAFORM_DIR}" init >/dev/null

echo "Inspecting Terraform state..."
STATE_LIST="$(terraform -chdir="${TERRAFORM_DIR}" state list 2>/dev/null || true)"

if [[ -z "${STATE_LIST}" ]]; then
  echo "No Terraform state resources found. Nothing to destroy."
else
  echo "${STATE_LIST}" | sed 's/^/  - /'
fi

NETWORK_MATCHES="$(printf '%s\n' "${STATE_LIST}" | rg '(^|\.)(aws_vpc|aws_subnet|aws_route_table|aws_internet_gateway|aws_nat_gateway|aws_vpn_gateway|aws_customer_gateway|aws_ec2_transit_gateway|aws_route)$' || true)"

if [[ -n "${NETWORK_MATCHES}" && "${ALLOW_NETWORK_DESTROY}" != "true" ]]; then
  echo
  echo "Refusing cleanup because Terraform state includes managed network resources:"
  printf '%s\n' "${NETWORK_MATCHES}" | sed 's/^/  - /'
  echo
  echo "This repository is expected to consume existing VPCs by default."
  echo "If you intentionally added managed network resources and want to destroy them,"
  echo "rerun with --allow-network-destroy."
  exit 1
fi

echo
echo "Cleanup plan:"
echo "  - Terraform destroy using ${TFVARS}"
if [[ "${#DELETE_AMI_IDS[@]}" -gt 0 ]]; then
  printf '  - Deregister AMIs: %s\n' "${DELETE_AMI_IDS[*]}"
fi
if [[ "${#DELETE_SNAPSHOT_IDS[@]}" -gt 0 ]]; then
  printf '  - Delete snapshots: %s\n' "${DELETE_SNAPSHOT_IDS[*]}"
fi
if [[ "${#DELETE_VOLUME_IDS[@]}" -gt 0 ]]; then
  printf '  - Delete volumes: %s\n' "${DELETE_VOLUME_IDS[*]}"
fi
echo "  - Existing VPCs/subnets/route tables/hosted zones not tracked in Terraform state will not be touched."

if [[ "${FORCE}" != "true" ]]; then
  echo
  read -r -p "Proceed with cleanup? Type 'delete' to continue: " CONFIRM
  if [[ "${CONFIRM}" != "delete" ]]; then
    echo "Cleanup cancelled."
    exit 1
  fi
fi

echo
echo "Running terraform destroy..."
terraform -chdir="${TERRAFORM_DIR}" destroy -var-file="${TFVARS_ABS}" -auto-approve

for ami_id in "${DELETE_AMI_IDS[@]}"; do
  echo "Deregistering AMI ${ami_id}..."
  aws "${AWS_ARGS[@]}" ec2 deregister-image --image-id "${ami_id}"
done

for snapshot_id in "${DELETE_SNAPSHOT_IDS[@]}"; do
  echo "Deleting snapshot ${snapshot_id}..."
  aws "${AWS_ARGS[@]}" ec2 delete-snapshot --snapshot-id "${snapshot_id}"
done

for volume_id in "${DELETE_VOLUME_IDS[@]}"; do
  echo "Deleting volume ${volume_id}..."
  aws "${AWS_ARGS[@]}" ec2 delete-volume --volume-id "${volume_id}"
done

echo
echo "Cleanup completed."
