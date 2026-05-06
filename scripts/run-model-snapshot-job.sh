#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  run-model-snapshot-job.sh --region REGION --tfvars FILE [options]

Launch a temporary helper EC2 instance in the backend private subnet, prepare a
model volume over SSM, create an EBS snapshot from that volume, update the
tfvars file locally, and clean up the helper instance.

Options:
  --region REGION                     AWS region
  --tfvars FILE                       Terraform tfvars file to read and update
  --config FILE                       Optional shell-style config. Supports HF_TOKEN, SNAPSHOT_DESCRIPTION, MODEL_REPO, MODEL_FILENAME, MOUNT_POINT, FILESYSTEM
  --profile PROFILE                   AWS CLI profile
  --helper-ami-id AMI_ID              Helper EC2 AMI, default: ami-00e2c2ccdcd58e2ba
  --helper-instance-type TYPE         Helper EC2 instance type, default: t3.small
  --helper-instance-profile-name NAME Reusable EC2 instance profile, default: llm-model-snapshot-helper
  --size-gb SIZE                      Model volume size in GiB, default: 100
  --filesystem TYPE                   Volume filesystem, default: ext4
  --mount-point PATH                  Remote mount point, default: /mnt/models
  --keep-helper-instance              Leave the helper EC2 instance running
  --keep-security-group               Leave the temporary helper security group in place
  --help                              Show this help text

Example:
  ./scripts/run-model-snapshot-job.sh \
    --region eu-north-1 \
    --tfvars examples/generated.prod.tfvars \
    --config ./.hf.env
EOF
}

parse_tfvars_string() {
  local key="$1"
  local path="$2"
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]+)\"([[:space:]]*#.*)?$/\\1/p" "${path}" | head -n1
}

parse_tfvars_first_array_item() {
  local key="$1"
  local path="$2"
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\\[[[:space:]]*\"([^\"]+)\".*$/\\1/p" "${path}" | head -n1
}

update_tfvars_string() {
  local key="$1"
  local value="$2"
  local path="$3"
  local tmp
  tmp="$(mktemp)"

  if rg -q "^[[:space:]]*${key}[[:space:]]*=" "${path}"; then
    awk -v key="${key}" -v value="${value}" '
      BEGIN { updated = 0 }
      $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
        print key " = \"" value "\""
        updated = 1
        next
      }
      { print }
      END {
        if (updated == 0) {
          print key " = \"" value "\""
        }
      }
    ' "${path}" >"${tmp}"
  else
    cat "${path}" >"${tmp}"
    printf '\n%s = "%s"\n' "${key}" "${value}" >>"${tmp}"
  fi

  mv "${tmp}" "${path}"
}

parse_terraform_variable_default() {
  local key="$1"
  local path="$2"
  awk -v key="${key}" '
    $0 ~ "^[[:space:]]*variable \"" key "\"[[:space:]]*\\{" { in_block = 1; next }
    in_block && $0 ~ "^[[:space:]]*default[[:space:]]*=" {
      if (match($0, /"[^"]+"/)) {
        value = substr($0, RSTART + 1, RLENGTH - 2)
        print value
        exit
      }
    }
    in_block && $0 ~ "^[[:space:]]*}" { in_block = 0 }
  ' "${path}" | head -n1
}

slugify() {
  tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

derive_snapshot_description() {
  local repo="$1"
  local filename="$2"
  local repo_part=""
  local file_part=""

  repo_part="$(slugify "${repo##*/}")"
  file_part="$(slugify "${filename%.gguf}")"

  if [[ -n "${repo_part}" && -n "${file_part}" ]]; then
    printf '%s-%s-model-snapshot' "${repo_part}" "${file_part}"
  elif [[ -n "${repo_part}" ]]; then
    printf '%s-model-snapshot' "${repo_part}"
  elif [[ -n "${file_part}" ]]; then
    printf '%s-model-snapshot' "${file_part}"
  else
    printf 'llm-model-snapshot'
  fi
}

b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

wait_for_instance_state() {
  local instance_id="$1"
  local desired_state="$2"
  local state=""
  local attempt=0

  while (( attempt < 60 )); do
    state="$(aws "${AWS_ARGS[@]}" ec2 describe-instances --instance-ids "${instance_id}" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || true)"
    if [[ "${state}" == "${desired_state}" ]]; then
      return 0
    fi
    if (( attempt == 0 || attempt % 6 == 0 )); then
      echo "Helper instance ${instance_id}: waiting for state ${desired_state}, current state ${state:-unknown}..."
    fi
    sleep 5
    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for instance ${instance_id} to reach state ${desired_state}." >&2
  exit 1
}

wait_for_ssm_online() {
  local instance_id="$1"
  local status=""
  local attempt=0

  while (( attempt < 60 )); do
    status="$(aws "${AWS_ARGS[@]}" ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=${instance_id}" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null || true)"
    if [[ "${status}" == "Online" ]]; then
      return 0
    fi
    if (( attempt == 0 || attempt % 6 == 0 )); then
      echo "Helper instance ${instance_id}: waiting for SSM online status, current status ${status:-unknown}..."
    fi
    sleep 10
    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for helper instance ${instance_id} to become SSM-online." >&2
  exit 1
}

wait_for_instance_profile_ready() {
  local instance_profile_name="$1"
  local arn=""
  local attempt=0

  while (( attempt < 30 )); do
    arn="$(aws "${AWS_ARGS[@]}" iam get-instance-profile \
      --instance-profile-name "${instance_profile_name}" \
      --query 'InstanceProfile.Arn' \
      --output text 2>/dev/null || true)"
    if [[ -n "${arn}" && "${arn}" != "None" ]]; then
      printf '%s\n' "${arn}"
      return 0
    fi
    if (( attempt == 0 || attempt % 6 == 0 )); then
      echo "Waiting for instance profile ${instance_profile_name} to propagate..."
    fi
    sleep 5
    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for instance profile ${instance_profile_name} to become readable." >&2
  exit 1
}

wait_for_snapshot_completion() {
  local snapshot_id="$1"
  local state=""
  local progress=""
  local last_message=""

  while true; do
    state="$(aws "${AWS_ARGS[@]}" ec2 describe-snapshots --snapshot-ids "${snapshot_id}" --query 'Snapshots[0].State' --output text 2>/dev/null || true)"
    progress="$(aws "${AWS_ARGS[@]}" ec2 describe-snapshots --snapshot-ids "${snapshot_id}" --query 'Snapshots[0].Progress' --output text 2>/dev/null || true)"
    [[ -z "${state}" || "${state}" == "None" ]] && state="unknown"
    [[ -z "${progress}" || "${progress}" == "None" ]] && progress="n/a"
    if [[ "Snapshot ${snapshot_id}: ${state} ${progress}" != "${last_message}" ]]; then
      last_message="Snapshot ${snapshot_id}: ${state} ${progress}"
      echo "${last_message}"
    fi
    case "${state}" in
      completed) return 0 ;;
      error)
        echo "Snapshot ${snapshot_id} entered error state." >&2
        exit 1
        ;;
    esac
    sleep 20
  done
}

stream_ssm_command() {
  local command_id="$1"
  local instance_id="$2"
  local last_status=""
  local last_output=""
  local output=""
  local status=""
  local stderr=""

  while true; do
    status="$(aws "${AWS_ARGS[@]}" ssm get-command-invocation --command-id "${command_id}" --instance-id "${instance_id}" --query 'Status' --output text 2>/dev/null || true)"
    if [[ -n "${status}" && "${status}" != "${last_status}" ]]; then
      echo "SSM command ${command_id}: ${status}"
      last_status="${status}"
    fi

    output="$(aws "${AWS_ARGS[@]}" ssm get-command-invocation --command-id "${command_id}" --instance-id "${instance_id}" --query 'StandardOutputContent' --output text 2>/dev/null || true)"
    if [[ -n "${output}" && "${output}" != "${last_output}" ]]; then
      if [[ -n "${last_output}" && "${output}" == "${last_output}"* ]]; then
        printf '%s' "${output#${last_output}}"
      else
        printf '%s\n' "${output}"
      fi
      last_output="${output}"
    fi

    case "${status}" in
      Success)
        return 0
        ;;
      Failed|Cancelled|TimedOut|Cancelling)
        stderr="$(aws "${AWS_ARGS[@]}" ssm get-command-invocation --command-id "${command_id}" --instance-id "${instance_id}" --query 'StandardErrorContent' --output text 2>/dev/null || true)"
        [[ -n "${stderr}" ]] && printf '%s\n' "${stderr}" >&2
        echo "Remote model preparation failed with status ${status}." >&2
        exit 1
        ;;
    esac

    sleep 10
  done
}

REGION=""
PROFILE=""
TFVARS=""
CONFIG_FILE=""
HELPER_AMI_ID="ami-00e2c2ccdcd58e2ba"
HELPER_INSTANCE_TYPE="t3.small"
HELPER_INSTANCE_PROFILE_NAME="llm-model-snapshot-helper"
SIZE_GB="100"
FILESYSTEM="ext4"
MOUNT_POINT="/mnt/models"
KEEP_HELPER_INSTANCE="false"
KEEP_SECURITY_GROUP="false"

MODEL_REPO=""
MODEL_FILENAME=""
HF_TOKEN="${HF_TOKEN:-}"
SNAPSHOT_DESCRIPTION="${SNAPSHOT_DESCRIPTION:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --tfvars) TFVARS="$2"; shift 2 ;;
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --helper-ami-id) HELPER_AMI_ID="$2"; shift 2 ;;
    --helper-instance-type) HELPER_INSTANCE_TYPE="$2"; shift 2 ;;
    --helper-instance-profile-name) HELPER_INSTANCE_PROFILE_NAME="$2"; shift 2 ;;
    --size-gb) SIZE_GB="$2"; shift 2 ;;
    --filesystem) FILESYSTEM="$2"; shift 2 ;;
    --mount-point) MOUNT_POINT="$2"; shift 2 ;;
    --keep-helper-instance) KEEP_HELPER_INSTANCE="true"; shift ;;
    --keep-security-group) KEEP_SECURITY_GROUP="true"; shift ;;
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

if [[ -n "${CONFIG_FILE}" ]]; then
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Config file not found: ${CONFIG_FILE}" >&2
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
  set +a
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_VARIABLES_FILE="${SCRIPT_DIR}/../terraform/variables.tf"
REMOTE_SCRIPT="${SCRIPT_DIR}/model-snapshot-helper-remote.sh"

AWS_ARGS=(--region "${REGION}")
if [[ -n "${PROFILE}" ]]; then
  AWS_ARGS+=(--profile "${PROFILE}")
fi

for cmd in aws jq rg mktemp base64; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
done

BACKEND_VPC_ID="$(parse_tfvars_string "backend_vpc_id" "${TFVARS}")"
BACKEND_SUBNET_ID="$(parse_tfvars_first_array_item "backend_private_subnet_ids" "${TFVARS}")"
MODEL_REPO="${MODEL_REPO:-$(parse_tfvars_string "model_repo" "${TFVARS}")}"
MODEL_FILENAME="${MODEL_FILENAME:-$(parse_tfvars_string "model_filename" "${TFVARS}")}"

if [[ -z "${MODEL_REPO}" ]]; then
  MODEL_REPO="$(parse_terraform_variable_default "model_repo" "${TERRAFORM_VARIABLES_FILE}")"
fi
if [[ -z "${MODEL_FILENAME}" ]]; then
  MODEL_FILENAME="$(parse_terraform_variable_default "model_filename" "${TERRAFORM_VARIABLES_FILE}")"
fi

if [[ -z "${BACKEND_VPC_ID}" || -z "${BACKEND_SUBNET_ID}" ]]; then
  echo "backend_vpc_id and at least one backend_private_subnet_ids entry are required in ${TFVARS}." >&2
  exit 1
fi

if [[ -z "${MODEL_REPO}" || -z "${MODEL_FILENAME}" ]]; then
  echo "model_repo and model_filename could not be resolved from ${TFVARS} or terraform defaults." >&2
  exit 1
fi

if [[ -z "${SNAPSHOT_DESCRIPTION}" ]]; then
  SNAPSHOT_DESCRIPTION="$(derive_snapshot_description "${MODEL_REPO}" "${MODEL_FILENAME}")"
fi

INSTANCE_ID=""
HELPER_SG_ID=""
MODEL_VOLUME_ID=""
TEMP_CREATED_PROFILE="false"
CREATE_PROFILE_ARGS=()
HELPER_INSTANCE_PROFILE_ARN=""

cleanup() {
  if [[ "${KEEP_HELPER_INSTANCE}" != "true" && -n "${INSTANCE_ID}" ]]; then
    aws "${AWS_ARGS[@]}" ec2 terminate-instances --instance-ids "${INSTANCE_ID}" >/dev/null 2>&1 || true
    wait_for_instance_state "${INSTANCE_ID}" "terminated" || true
  fi

  if [[ "${KEEP_HELPER_INSTANCE}" != "true" && "${KEEP_SECURITY_GROUP}" != "true" && -n "${HELPER_SG_ID}" ]]; then
    aws "${AWS_ARGS[@]}" ec2 delete-security-group --group-id "${HELPER_SG_ID}" >/dev/null 2>&1 || true
  fi

  [[ -n "${PARAMS_FILE:-}" ]] && rm -f "${PARAMS_FILE}"
  [[ -n "${REMOTE_SCRIPT_WRAPPED:-}" ]] && rm -f "${REMOTE_SCRIPT_WRAPPED}"
}
trap cleanup EXIT

if [[ -n "${PROFILE}" ]]; then
  CREATE_PROFILE_ARGS+=(--profile "${PROFILE}")
fi

if ! aws "${AWS_ARGS[@]}" iam get-instance-profile --instance-profile-name "${HELPER_INSTANCE_PROFILE_NAME}" >/dev/null 2>&1; then
  "${SCRIPT_DIR}/create-packer-instance-profile.sh" \
    --region "${REGION}" \
    "${CREATE_PROFILE_ARGS[@]}" \
    --name "${HELPER_INSTANCE_PROFILE_NAME}" >/dev/null
  TEMP_CREATED_PROFILE="true"
fi

HELPER_INSTANCE_PROFILE_ARN="$(wait_for_instance_profile_ready "${HELPER_INSTANCE_PROFILE_NAME}")"

HELPER_SG_NAME="model-snapshot-helper-$(date +%Y%m%d%H%M%S)"
HELPER_SG_ID="$(aws "${AWS_ARGS[@]}" ec2 create-security-group \
  --group-name "${HELPER_SG_NAME}" \
  --description "Temporary security group for model snapshot helper" \
  --vpc-id "${BACKEND_VPC_ID}" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${HELPER_SG_NAME}},{Key=ManagedBy,Value=run-model-snapshot-job.sh},{Key=Role,Value=model-snapshot-helper}]" \
  --query 'GroupId' \
  --output text)"

echo "Launching temporary helper instance in ${BACKEND_SUBNET_ID}..."
INSTANCE_ID="$(aws "${AWS_ARGS[@]}" ec2 run-instances \
  --image-id "${HELPER_AMI_ID}" \
  --instance-type "${HELPER_INSTANCE_TYPE}" \
  --subnet-id "${BACKEND_SUBNET_ID}" \
  --security-group-ids "${HELPER_SG_ID}" \
  --iam-instance-profile "Arn=${HELPER_INSTANCE_PROFILE_ARN}" \
  --metadata-options 'HttpEndpoint=enabled,HttpTokens=required,HttpPutResponseHopLimit=2' \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sdf\",\"Ebs\":{\"VolumeSize\":${SIZE_GB},\"VolumeType\":\"gp3\",\"Encrypted\":true,\"DeleteOnTermination\":true}}]" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=model-snapshot-helper},{Key=ManagedBy,Value=run-model-snapshot-job.sh},{Key=Role,Value=model-snapshot-helper}]" \
  --query 'Instances[0].InstanceId' \
  --output text)"

wait_for_instance_state "${INSTANCE_ID}" "running"
wait_for_ssm_online "${INSTANCE_ID}"

MODEL_VOLUME_ID="$(aws "${AWS_ARGS[@]}" ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==`/dev/sdf`].Ebs.VolumeId | [0]' \
  --output text)"

if [[ -z "${MODEL_VOLUME_ID}" || "${MODEL_VOLUME_ID}" == "None" ]]; then
  echo "Could not determine helper model volume ID." >&2
  exit 1
fi

PARAMS_FILE="$(mktemp)"
REMOTE_SCRIPT_WRAPPED="$(mktemp)"
cat >"${REMOTE_SCRIPT_WRAPPED}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export MODEL_REPO_B64="$(b64 "${MODEL_REPO}")"
export MODEL_FILENAME_B64="$(b64 "${MODEL_FILENAME}")"
export HF_TOKEN_B64="$(b64 "${HF_TOKEN:-}")"
export MOUNT_POINT_B64="$(b64 "${MOUNT_POINT}")"
export FILESYSTEM_B64="$(b64 "${FILESYSTEM}")"
EOF
tail -n +2 "${REMOTE_SCRIPT}" >>"${REMOTE_SCRIPT_WRAPPED}"
REMOTE_SCRIPT_B64="$(base64 -w 0 "${REMOTE_SCRIPT_WRAPPED}")"

jq -n \
  --arg remote_script_b64 "${REMOTE_SCRIPT_B64}" \
  '{
    commands: [
      "python3 -c '\''import base64, pathlib; pathlib.Path(\"/tmp/model-snapshot-helper-remote.sh\").write_bytes(base64.b64decode(\"" + $remote_script_b64 + "\"))'\''",
      "chmod +x /tmp/model-snapshot-helper-remote.sh",
      "/usr/bin/env bash /tmp/model-snapshot-helper-remote.sh"
    ]
  }' >"${PARAMS_FILE}"

echo "Preparing the model volume over SSM..."
COMMAND_ID="$(aws "${AWS_ARGS[@]}" ssm send-command \
  --instance-ids "${INSTANCE_ID}" \
  --document-name AWS-RunShellScript \
  --parameters "file://${PARAMS_FILE}" \
  --comment "Prepare model volume for snapshot" \
  --query 'Command.CommandId' \
  --output text)"

stream_ssm_command "${COMMAND_ID}" "${INSTANCE_ID}"

echo "Creating snapshot from ${MODEL_VOLUME_ID}..."
SNAPSHOT_ID="$(aws "${AWS_ARGS[@]}" ec2 create-snapshot \
  --volume-id "${MODEL_VOLUME_ID}" \
  --description "${SNAPSHOT_DESCRIPTION}" \
  --query 'SnapshotId' \
  --output text)"

echo "Created snapshot request ${SNAPSHOT_ID}; polling AWS for progress..."
wait_for_snapshot_completion "${SNAPSHOT_ID}"

update_tfvars_string "model_ebs_snapshot_id" "${SNAPSHOT_ID}" "${TFVARS}"

echo "Helper instance: ${INSTANCE_ID}"
echo "Model volume:    ${MODEL_VOLUME_ID}"
echo "Snapshot:        ${SNAPSHOT_ID}"
echo "Updated ${TFVARS} with model_ebs_snapshot_id = \"${SNAPSHOT_ID}\""
if [[ "${TEMP_CREATED_PROFILE}" == "true" ]]; then
  echo "Created helper instance profile ${HELPER_INSTANCE_PROFILE_NAME} for reuse."
fi
