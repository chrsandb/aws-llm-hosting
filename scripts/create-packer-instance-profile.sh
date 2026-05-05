#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: create-packer-instance-profile.sh --region REGION [options]

Create or validate an EC2 instance profile for Packer builds that connect over
AWS Systems Manager. This is useful in AWS accounts where temporary Packer role
creation or iam:PassRole is tightly controlled.

Options:
  --region REGION                 AWS region, for example eu-north-1
  --profile PROFILE               AWS CLI profile
  --name NAME                     Base name for the role and instance profile
  --role-name NAME                Override IAM role name
  --instance-profile-name NAME    Override instance profile name
  --managed-policy-arn ARN        Extra managed policy to attach; repeatable
  --help                          Show this help text

Example:
  ./scripts/create-packer-instance-profile.sh \
    --region eu-north-1 \
    --name llm-packer-builder
EOF
}

REGION=""
PROFILE=""
BASE_NAME=""
ROLE_NAME=""
INSTANCE_PROFILE_NAME=""
MANAGED_POLICY_ARNS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --name) BASE_NAME="$2"; shift 2 ;;
    --role-name) ROLE_NAME="$2"; shift 2 ;;
    --instance-profile-name) INSTANCE_PROFILE_NAME="$2"; shift 2 ;;
    --managed-policy-arn) MANAGED_POLICY_ARNS+=("$2"); shift 2 ;;
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

if [[ -z "${BASE_NAME}" && -z "${ROLE_NAME}" && -z "${INSTANCE_PROFILE_NAME}" ]]; then
  echo "Pass --name or both --role-name and --instance-profile-name." >&2
  exit 1
fi

ROLE_NAME="${ROLE_NAME:-${BASE_NAME}}"
INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME:-${BASE_NAME}}"

AWS_ARGS=(--region "${REGION}")
if [[ -n "${PROFILE}" ]]; then
  AWS_ARGS+=(--profile "${PROFILE}")
fi

TRUST_POLICY="$(mktemp)"
INLINE_POLICY="$(mktemp)"
trap 'rm -f "${TRUST_POLICY}" "${INLINE_POLICY}"' EXIT

cat >"${TRUST_POLICY}" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

cat >"${INLINE_POLICY}" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:UpdateInstanceInformation",
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
        "ec2messages:AcknowledgeMessage",
        "ec2messages:DeleteMessage",
        "ec2messages:FailMessage",
        "ec2messages:GetEndpoint",
        "ec2messages:GetMessages",
        "ec2messages:SendReply"
      ],
      "Resource": "*"
    }
  ]
}
EOF

if aws "${AWS_ARGS[@]}" iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "Role already exists: ${ROLE_NAME}"
else
  aws "${AWS_ARGS[@]}" iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "file://${TRUST_POLICY}" \
    >/dev/null
  echo "Created role: ${ROLE_NAME}"
fi

aws "${AWS_ARGS[@]}" iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "${ROLE_NAME}-ssm-core" \
  --policy-document "file://${INLINE_POLICY}" \
  >/dev/null

if aws "${AWS_ARGS[@]}" iam get-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" >/dev/null 2>&1; then
  echo "Instance profile already exists: ${INSTANCE_PROFILE_NAME}"
else
  aws "${AWS_ARGS[@]}" iam create-instance-profile \
    --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
    >/dev/null
  echo "Created instance profile: ${INSTANCE_PROFILE_NAME}"
fi

CURRENT_ROLES="$(aws "${AWS_ARGS[@]}" iam get-instance-profile \
  --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
  --query 'InstanceProfile.Roles[].RoleName' \
  --output text)"

if ! grep -qw "${ROLE_NAME}" <<<"${CURRENT_ROLES:-}"; then
  aws "${AWS_ARGS[@]}" iam add-role-to-instance-profile \
    --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
    --role-name "${ROLE_NAME}" \
    >/dev/null
  echo "Attached role ${ROLE_NAME} to instance profile ${INSTANCE_PROFILE_NAME}"
fi

aws "${AWS_ARGS[@]}" iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
  >/dev/null 2>&1 || true

for arn in "${MANAGED_POLICY_ARNS[@]}"; do
  aws "${AWS_ARGS[@]}" iam attach-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-arn "${arn}" \
    >/dev/null
done

cat <<EOF
Packer instance profile ready.

Role name:             ${ROLE_NAME}
Instance profile name: ${INSTANCE_PROFILE_NAME}

Use this in packer/backend.auto.pkrvars.hcl:

packer_instance_profile_name = "${INSTANCE_PROFILE_NAME}"

Notes:
- This avoids temporary Packer role and instance profile creation.
- Your caller still needs permission to pass this instance profile during RunInstances.
- IAM propagation can take a short time. If Packer immediately says the profile is not found, wait 30-60 seconds and retry.
EOF
