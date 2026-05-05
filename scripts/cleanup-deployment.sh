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
- auto-discovers the latest locally built Packer AMI from packer/manifest.json
  when available, and removes that AMI plus its backing snapshots
- auto-discovers temporary Packer build security groups tagged by
  prepare-packer-build.sh and removes them
- does not touch reusable Packer instance profiles or manually created artifacts
  outside the discovered manifest unless you pass them in

Options:
  --tfvars FILE
  --terraform-dir DIR
  --region REGION
  --profile PROFILE
  --packer-manifest FILE
  --skip-packer-artifacts
  --delete-ami-id AMI_ID
  --delete-snapshot-id SNAPSHOT_ID
  --delete-volume-id VOLUME_ID
  --delete-security-group-id SG_ID
  --allow-network-destroy
  --force

Examples:
  ./scripts/cleanup-deployment.sh --tfvars examples/generated.prod.tfvars
  ./scripts/cleanup-deployment.sh \
    --tfvars examples/generated.prod.tfvars \
    --skip-packer-artifacts \
    --delete-ami-id ami-0123456789abcdef0 \
    --force
EOF
}

TFVARS=""
TERRAFORM_DIR="terraform"
PACKER_MANIFEST="packer/manifest.json"
REGION=""
PROFILE=""
ALLOW_NETWORK_DESTROY="false"
FORCE="false"
SKIP_PACKER_ARTIFACTS="false"

DELETE_AMI_IDS=()
DELETE_SNAPSHOT_IDS=()
DELETE_VOLUME_IDS=()
DELETE_SECURITY_GROUP_IDS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tfvars) TFVARS="$2"; shift 2 ;;
    --terraform-dir) TERRAFORM_DIR="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --packer-manifest) PACKER_MANIFEST="$2"; shift 2 ;;
    --skip-packer-artifacts) SKIP_PACKER_ARTIFACTS="true"; shift ;;
    --delete-ami-id) DELETE_AMI_IDS+=("$2"); shift 2 ;;
    --delete-snapshot-id) DELETE_SNAPSHOT_IDS+=("$2"); shift 2 ;;
    --delete-volume-id) DELETE_VOLUME_IDS+=("$2"); shift 2 ;;
    --delete-security-group-id) DELETE_SECURITY_GROUP_IDS+=("$2"); shift 2 ;;
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

PACKER_DISCOVERED_AMI_IDS=()
PACKER_DISCOVERED_SNAPSHOT_IDS=()
PACKER_DISCOVERED_SECURITY_GROUP_IDS=()

append_unique() {
  local item="$1"
  shift
  local -n arr_ref="$1"
  local existing
  for existing in "${arr_ref[@]}"; do
    [[ "${existing}" == "${item}" ]] && return 0
  done
  arr_ref+=("${item}")
}

discover_packer_artifacts() {
  local manifest_path="$1"
  local manifest_ami_ids=()
  local artifact_id
  local ami_id
  local image_json
  local snapshot_id
  local security_group_id

  [[ "${SKIP_PACKER_ARTIFACTS}" == "true" ]] && return 0

  command -v jq >/dev/null 2>&1 || {
    echo "Missing required command: jq (needed to parse ${manifest_path})" >&2
    exit 1
  }

  if [[ -f "${manifest_path}" ]]; then
    while IFS= read -r artifact_id; do
      [[ -z "${artifact_id}" ]] && continue
      ami_id="${artifact_id##*:}"
      if [[ "${ami_id}" =~ ^ami- ]]; then
        append_unique "${ami_id}" manifest_ami_ids
      fi
    done < <(jq -r '.builds[]?.artifact_id // empty' "${manifest_path}")
  fi

  for ami_id in "${manifest_ami_ids[@]}"; do
    append_unique "${ami_id}" PACKER_DISCOVERED_AMI_IDS
    if image_json="$(aws "${AWS_ARGS[@]}" ec2 describe-images --image-ids "${ami_id}" --output json 2>/dev/null)"; then
      while IFS= read -r snapshot_id; do
        [[ -z "${snapshot_id}" || "${snapshot_id}" == "null" ]] && continue
        append_unique "${snapshot_id}" PACKER_DISCOVERED_SNAPSHOT_IDS
      done < <(jq -r '.Images[0].BlockDeviceMappings[]?.Ebs.SnapshotId // empty' <<<"${image_json}")
    fi
  done

  while IFS= read -r security_group_id; do
    [[ -z "${security_group_id}" || "${security_group_id}" == "None" ]] && continue
    append_unique "${security_group_id}" PACKER_DISCOVERED_SECURITY_GROUP_IDS
  done < <(aws "${AWS_ARGS[@]}" ec2 describe-security-groups \
    --filters \
      "Name=tag:ManagedBy,Values=prepare-packer-build.sh" \
      "Name=tag:Role,Values=packer-build" \
    --query 'SecurityGroups[].GroupId' \
    --output text 2>/dev/null | tr '\t' '\n')
}

discover_packer_artifacts "${PACKER_MANIFEST}"

for ami_id in "${PACKER_DISCOVERED_AMI_IDS[@]}"; do
  append_unique "${ami_id}" DELETE_AMI_IDS
done

for snapshot_id in "${PACKER_DISCOVERED_SNAPSHOT_IDS[@]}"; do
  append_unique "${snapshot_id}" DELETE_SNAPSHOT_IDS
done

for security_group_id in "${PACKER_DISCOVERED_SECURITY_GROUP_IDS[@]}"; do
  append_unique "${security_group_id}" DELETE_SECURITY_GROUP_IDS
done

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
if [[ "${#DELETE_SECURITY_GROUP_IDS[@]}" -gt 0 ]]; then
  printf '  - Delete Packer build security groups: %s\n' "${DELETE_SECURITY_GROUP_IDS[*]}"
fi
echo "  - Existing VPCs/subnets/route tables/hosted zones not tracked in Terraform state will not be touched."
if [[ "${SKIP_PACKER_ARTIFACTS}" != "true" && -f "${PACKER_MANIFEST}" ]]; then
  echo "  - Reusable Packer instance profiles are not deleted automatically."
fi

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
  aws "${AWS_ARGS[@]}" ec2 deregister-image --image-id "${ami_id}" || true
done

for snapshot_id in "${DELETE_SNAPSHOT_IDS[@]}"; do
  echo "Deleting snapshot ${snapshot_id}..."
  aws "${AWS_ARGS[@]}" ec2 delete-snapshot --snapshot-id "${snapshot_id}" || true
done

for volume_id in "${DELETE_VOLUME_IDS[@]}"; do
  echo "Deleting volume ${volume_id}..."
  aws "${AWS_ARGS[@]}" ec2 delete-volume --volume-id "${volume_id}"
done

for security_group_id in "${DELETE_SECURITY_GROUP_IDS[@]}"; do
  echo "Deleting security group ${security_group_id}..."
  aws "${AWS_ARGS[@]}" ec2 delete-security-group --group-id "${security_group_id}" || true
done

echo
echo "Cleanup completed."
