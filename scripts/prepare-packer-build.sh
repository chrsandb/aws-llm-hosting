#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: prepare-packer-build.sh --region REGION [options]

Create a temporary security group for the Packer build instance and optionally
write a ready-to-use Packer vars file.

Options:
  --region REGION                 AWS region, for example eu-north-1
  --tfvars PATH                   Terraform tfvars file to read backend_vpc_id and backend_private_subnet_ids from
  --vpc-id VPC_ID                 Backend VPC ID. Required if --tfvars is not provided.
  --subnet-id SUBNET_ID           Backend private subnet ID to use for the build. Defaults to the first backend private subnet from --tfvars.
  --security-group-id SG_ID       Reuse an existing security group instead of creating one.
  --security-group-name NAME      Name for the temporary security group if one is created.
  --pkrvars-out PATH              Write a populated Packer vars file, for example packer/backend.auto.pkrvars.hcl
  --instance-type TYPE            Override instance type written to the output vars file
  --ami-name-prefix PREFIX        Override ami_name_prefix written to the output vars file
  --cleanup                       Delete the created temporary security group and exit
  --help                          Show this help text

Examples:
  ./scripts/prepare-packer-build.sh \
    --region eu-north-1 \
    --tfvars examples/generated.prod.tfvars \
    --pkrvars-out packer/backend.auto.pkrvars.hcl

  ./scripts/prepare-packer-build.sh \
    --region eu-north-1 \
    --vpc-id vpc-0123456789abcdef0 \
    --subnet-id subnet-0123456789abcdef0
EOF
}

REGION=""
TFVARS_PATH=""
VPC_ID=""
SUBNET_ID=""
SECURITY_GROUP_ID=""
SECURITY_GROUP_NAME=""
PKRVARS_OUT=""
INSTANCE_TYPE=""
AMI_NAME_PREFIX=""
CLEANUP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --tfvars) TFVARS_PATH="$2"; shift 2 ;;
    --vpc-id) VPC_ID="$2"; shift 2 ;;
    --subnet-id) SUBNET_ID="$2"; shift 2 ;;
    --security-group-id) SECURITY_GROUP_ID="$2"; shift 2 ;;
    --security-group-name) SECURITY_GROUP_NAME="$2"; shift 2 ;;
    --pkrvars-out) PKRVARS_OUT="$2"; shift 2 ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
    --ami-name-prefix) AMI_NAME_PREFIX="$2"; shift 2 ;;
    --cleanup) CLEANUP=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${REGION}" ]]; then
  echo "--region is required." >&2
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required." >&2
  exit 1
fi

if [[ -n "${TFVARS_PATH}" && ! -f "${TFVARS_PATH}" ]]; then
  echo "tfvars file not found: ${TFVARS_PATH}" >&2
  exit 1
fi

parse_tfvars_string() {
  local key="$1"
  local path="$2"
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]+)\"[[:space:]]*$/\\1/p" "${path}" | head -n1
}

parse_tfvars_first_array_item() {
  local key="$1"
  local path="$2"
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\\[(.*)\\][[:space:]]*$/\\1/p" "${path}" \
    | head -n1 \
    | grep -oE '"[^"]+"' \
    | head -n1 \
    | tr -d '"'
}

if [[ -n "${TFVARS_PATH}" ]]; then
  [[ -z "${VPC_ID}" ]] && VPC_ID="$(parse_tfvars_string "backend_vpc_id" "${TFVARS_PATH}")"
  [[ -z "${SUBNET_ID}" ]] && SUBNET_ID="$(parse_tfvars_first_array_item "backend_private_subnet_ids" "${TFVARS_PATH}")"
  [[ -z "${INSTANCE_TYPE}" ]] && INSTANCE_TYPE="$(parse_tfvars_string "backend_instance_type" "${TFVARS_PATH}")"

  if [[ -z "${AMI_NAME_PREFIX}" ]]; then
    PROJECT_NAME="$(parse_tfvars_string "project_name" "${TFVARS_PATH}")"
    ENVIRONMENT_NAME="$(parse_tfvars_string "environment" "${TFVARS_PATH}")"
    if [[ -n "${PROJECT_NAME}" && -n "${ENVIRONMENT_NAME}" ]]; then
      AMI_NAME_PREFIX="${PROJECT_NAME}-${ENVIRONMENT_NAME}-backend"
    fi
  fi
fi

INSTANCE_TYPE="${INSTANCE_TYPE:-g6e.2xlarge}"
AMI_NAME_PREFIX="${AMI_NAME_PREFIX:-llm-backend}"

if [[ -z "${VPC_ID}" ]]; then
  echo "backend VPC ID is required. Pass --vpc-id or --tfvars." >&2
  exit 1
fi

if [[ -z "${SUBNET_ID}" ]]; then
  echo "backend subnet ID is required. Pass --subnet-id or --tfvars with backend_private_subnet_ids." >&2
  exit 1
fi

AWS_ARGS=(--region "${REGION}")

SUBNET_VPC_ID="$(aws "${AWS_ARGS[@]}" ec2 describe-subnets \
  --subnet-ids "${SUBNET_ID}" \
  --query 'Subnets[0].VpcId' \
  --output text)"

if [[ "${SUBNET_VPC_ID}" != "${VPC_ID}" ]]; then
  echo "Subnet ${SUBNET_ID} belongs to ${SUBNET_VPC_ID}, not ${VPC_ID}." >&2
  exit 1
fi

if [[ "${CLEANUP}" == "true" ]]; then
  if [[ -z "${SECURITY_GROUP_ID}" ]]; then
    echo "--cleanup requires --security-group-id." >&2
    exit 1
  fi
  aws "${AWS_ARGS[@]}" ec2 delete-security-group --group-id "${SECURITY_GROUP_ID}"
  echo "Deleted security group ${SECURITY_GROUP_ID}"
  exit 0
fi

if [[ -z "${SECURITY_GROUP_ID}" ]]; then
  SECURITY_GROUP_NAME="${SECURITY_GROUP_NAME:-packer-build-$(date +%Y%m%d%H%M%S)}"
  DESCRIPTION="Temporary security group for Packer AMI builds over Session Manager"

  SECURITY_GROUP_ID="$(aws "${AWS_ARGS[@]}" ec2 create-security-group \
    --group-name "${SECURITY_GROUP_NAME}" \
    --description "${DESCRIPTION}" \
    --vpc-id "${VPC_ID}" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${SECURITY_GROUP_NAME}},{Key=ManagedBy,Value=prepare-packer-build.sh},{Key=Role,Value=packer-build}]" \
    --query 'GroupId' \
    --output text)"
fi

if [[ -n "${PKRVARS_OUT}" ]]; then
  cat >"${PKRVARS_OUT}" <<EOF
aws_region        = "${REGION}"
subnet_id         = "${SUBNET_ID}"
security_group_id = "${SECURITY_GROUP_ID}"
instance_type     = "${INSTANCE_TYPE}"
ssh_username      = "ubuntu"
ami_name_prefix   = "${AMI_NAME_PREFIX}"

# Leave source_ami_id unset to use source_ami_name_pattern.
# Set this explicitly if you want to pin a known AMI.
# source_ami_id = "ami-0123456789abcdef0"

source_ami_name_pattern = "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*"
llama_cpp_image_tag     = "server-cuda"
model_source            = "ebs_snapshot"
copy_model_into_ami     = false

# Enable only when copy_model_into_ami = true.
model_local_path = "model.gguf"
EOF
fi

cat <<EOF
Packer build inputs prepared.

Region:             ${REGION}
Backend VPC:        ${VPC_ID}
Build subnet:       ${SUBNET_ID}
Security group:     ${SECURITY_GROUP_ID}
Instance type:      ${INSTANCE_TYPE}
AMI name prefix:    ${AMI_NAME_PREFIX}
${PKRVARS_OUT:+Packer vars file:   ${PKRVARS_OUT}}

Notes:
- The Packer template uses AWS Session Manager, so this temporary security group does not need inbound TCP/22.
- The subnet should be one of your backend private subnets.
- The subnet still needs outbound access to SSM and package repositories.
- Delete the temporary security group after the build if you do not plan to reuse it:
  ./scripts/prepare-packer-build.sh --region ${REGION} --cleanup --security-group-id ${SECURITY_GROUP_ID}
EOF
