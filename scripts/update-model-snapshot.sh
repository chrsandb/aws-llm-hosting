#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  update-model-snapshot.sh --description DESC --region REGION [options]

Download the configured GGUF model from Hugging Face onto an EBS volume and
create an EBS snapshot for Terraform. When --volume-id is omitted, the script
creates a new encrypted gp3 volume, attaches it to the current EC2 helper
instance, auto-detects the device, and updates the tfvars file with the new
snapshot ID.

Options:
  --description DESC              Snapshot description
  --region REGION                 AWS region
  --tfvars FILE                   Read model_repo/model_filename and update model_ebs_snapshot_id
  --volume-id VOL                 Use an existing attached EBS volume instead of auto-creating one
  --size-gb SIZE                  Volume size when auto-creating, default: 100
  --availability-zone AZ          Override volume AZ when auto-creating, default: current instance AZ
  --instance-id ID                Override helper instance ID when auto-attaching, default: current instance
  --attach-device NAME            Requested EC2 device name, default: /dev/sdf
  --device PATH                   Local block device path override if auto-detection is not wanted
  --mount-point PATH              Mount point, default: /mnt/models
  --filesystem TYPE               Filesystem to create if needed, default: ext4
  --model-repo REPO               Hugging Face repo, for example unsloth/Qwen3.6-35B-A3B-GGUF
  --model-filename FILE           Model file inside the repo, for example UD-Q6_K_XL.gguf
  --config FILE                   Shell-style config file. Supports HF_TOKEN and model defaults.
  --hf-token TOKEN                Hugging Face token. Overrides config and env.
  --keep-volume                   Keep an auto-created volume attached after snapshot creation
  --snapshot-only                 Skip download work and only snapshot the target volume
  --help                          Show this help text

Examples:
  ./scripts/update-model-snapshot.sh \
    --description "qwen3.6-35b-a3b initial snapshot" \
    --region eu-north-1 \
    --tfvars examples/generated.prod.tfvars \
    --config ./.hf.env

  ./scripts/update-model-snapshot.sh \
    --description "re-snapshot existing model volume" \
    --region eu-north-1 \
    --volume-id vol-0123456789abcdef0 \
    --device /dev/nvme1n1 \
    --snapshot-only
EOF
}

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  SUDO="sudo"
fi

parse_tfvars_string() {
  local key="$1"
  local path="$2"
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]+)\"[[:space:]]*$/\\1/p" "${path}" | head -n1
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

run_hf() {
  if command -v hf >/dev/null 2>&1; then
    hf "$@"
  elif command -v huggingface-cli >/dev/null 2>&1; then
    huggingface-cli "$@"
  else
    echo "Missing Hugging Face CLI. Install dependencies with ./scripts/install-dependencies-debian-ubuntu.sh" >&2
    exit 1
  fi
}

imds_get() {
  local path="$1"
  local token
  token="$(curl -fsSL -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")"
  curl -fsSL -H "X-aws-ec2-metadata-token: ${token}" "http://169.254.169.254/latest/${path}"
}

wait_for_volume_state() {
  local volume_id="$1"
  local desired_state="$2"
  local state=""
  local attempt=0

  while (( attempt < 60 )); do
    state="$(aws ec2 describe-volumes \
      --region "${REGION}" \
      --volume-ids "${volume_id}" \
      --query 'Volumes[0].State' \
      --output text 2>/dev/null || true)"
    if [[ "${state}" == "${desired_state}" ]]; then
      return 0
    fi
    sleep 5
    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for volume ${volume_id} to reach state ${desired_state} (last state: ${state:-unknown})." >&2
  exit 1
}

wait_for_attachment_state() {
  local volume_id="$1"
  local desired_state="$2"
  local state=""
  local attempt=0

  while (( attempt < 60 )); do
    state="$(aws ec2 describe-volumes \
      --region "${REGION}" \
      --volume-ids "${volume_id}" \
      --query 'Volumes[0].Attachments[0].State' \
      --output text 2>/dev/null || true)"
    if [[ "${state}" == "${desired_state}" ]]; then
      return 0
    fi
    sleep 5
    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for volume ${volume_id} attachment state ${desired_state} (last state: ${state:-unknown})." >&2
  exit 1
}

list_block_devices() {
  lsblk -dnpo NAME,TYPE | awk '$2 == "disk" { print $1 }'
}

detect_new_device() {
  local before_file="$1"
  local after_file="$2"
  comm -13 <(sort "${before_file}") <(sort "${after_file}") | head -n1
}

DESCRIPTION=""
REGION=""
TFVARS=""
VOLUME_ID=""
SIZE_GB="100"
AVAILABILITY_ZONE=""
INSTANCE_ID=""
ATTACH_DEVICE="/dev/sdf"
DEVICE=""
MOUNT_POINT="/mnt/models"
FILESYSTEM="ext4"
MODEL_REPO=""
MODEL_FILENAME=""
CONFIG_FILE=""
HF_TOKEN="${HF_TOKEN:-}"
KEEP_VOLUME="false"
SNAPSHOT_ONLY="false"

CLI_MODEL_REPO=""
CLI_MODEL_FILENAME=""
CLI_DEVICE=""
CLI_MOUNT_POINT=""
CLI_FILESYSTEM=""
CLI_HF_TOKEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --description) DESCRIPTION="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --tfvars) TFVARS="$2"; shift 2 ;;
    --volume-id) VOLUME_ID="$2"; shift 2 ;;
    --size-gb) SIZE_GB="$2"; shift 2 ;;
    --availability-zone) AVAILABILITY_ZONE="$2"; shift 2 ;;
    --instance-id) INSTANCE_ID="$2"; shift 2 ;;
    --attach-device) ATTACH_DEVICE="$2"; shift 2 ;;
    --device) DEVICE="$2"; CLI_DEVICE="$2"; shift 2 ;;
    --mount-point) MOUNT_POINT="$2"; CLI_MOUNT_POINT="$2"; shift 2 ;;
    --filesystem) FILESYSTEM="$2"; CLI_FILESYSTEM="$2"; shift 2 ;;
    --model-repo) MODEL_REPO="$2"; CLI_MODEL_REPO="$2"; shift 2 ;;
    --model-filename) MODEL_FILENAME="$2"; CLI_MODEL_FILENAME="$2"; shift 2 ;;
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --hf-token) HF_TOKEN="$2"; CLI_HF_TOKEN="$2"; shift 2 ;;
    --keep-volume) KEEP_VOLUME="true"; shift ;;
    --snapshot-only) SNAPSHOT_ONLY="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${DESCRIPTION}" || -z "${REGION}" ]]; then
  usage >&2
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

[[ -n "${CLI_MODEL_REPO}" ]] && MODEL_REPO="${CLI_MODEL_REPO}"
[[ -n "${CLI_MODEL_FILENAME}" ]] && MODEL_FILENAME="${CLI_MODEL_FILENAME}"
[[ -n "${CLI_DEVICE}" ]] && DEVICE="${CLI_DEVICE}"
[[ -n "${CLI_MOUNT_POINT}" ]] && MOUNT_POINT="${CLI_MOUNT_POINT}"
[[ -n "${CLI_FILESYSTEM}" ]] && FILESYSTEM="${CLI_FILESYSTEM}"
[[ -n "${CLI_HF_TOKEN}" ]] && HF_TOKEN="${CLI_HF_TOKEN}"

if [[ -n "${TFVARS}" ]]; then
  if [[ ! -f "${TFVARS}" ]]; then
    echo "tfvars file not found: ${TFVARS}" >&2
    exit 1
  fi
  [[ -z "${MODEL_REPO}" ]] && MODEL_REPO="$(parse_tfvars_string "model_repo" "${TFVARS}")"
  [[ -z "${MODEL_FILENAME}" ]] && MODEL_FILENAME="$(parse_tfvars_string "model_filename" "${TFVARS}")"
fi

if [[ "${SNAPSHOT_ONLY}" != "true" && ( -z "${MODEL_REPO}" || -z "${MODEL_FILENAME}" ) ]]; then
  echo "model_repo and model_filename are required unless --snapshot-only is used." >&2
  exit 1
fi

for cmd in aws curl lsblk sync findmnt blkid rg mktemp; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
done

AUTO_CREATED_VOLUME="false"
ATTACHED_BY_SCRIPT="false"
MOUNTED_BY_SCRIPT="false"
BEFORE_DEVICES_FILE=""
AFTER_DEVICES_FILE=""

cleanup() {
  if [[ "${MOUNTED_BY_SCRIPT}" == "true" ]]; then
    ${SUDO} umount "${MOUNT_POINT}" >/dev/null 2>&1 || true
  fi

  if [[ "${ATTACHED_BY_SCRIPT}" == "true" && "${KEEP_VOLUME}" != "true" && -n "${VOLUME_ID}" ]]; then
    aws ec2 detach-volume --region "${REGION}" --volume-id "${VOLUME_ID}" >/dev/null 2>&1 || true
    wait_for_volume_state "${VOLUME_ID}" "available" || true
  fi

  if [[ "${AUTO_CREATED_VOLUME}" == "true" && "${KEEP_VOLUME}" != "true" && -n "${VOLUME_ID}" ]]; then
    aws ec2 delete-volume --region "${REGION}" --volume-id "${VOLUME_ID}" >/dev/null 2>&1 || true
  fi

  [[ -n "${BEFORE_DEVICES_FILE}" ]] && rm -f "${BEFORE_DEVICES_FILE}"
  [[ -n "${AFTER_DEVICES_FILE}" ]] && rm -f "${AFTER_DEVICES_FILE}"
}
trap cleanup EXIT

if [[ -z "${VOLUME_ID}" ]]; then
  INSTANCE_ID="${INSTANCE_ID:-$(imds_get meta-data/instance-id)}"
  AVAILABILITY_ZONE="${AVAILABILITY_ZONE:-$(imds_get meta-data/placement/availability-zone)}"

  if [[ -z "${INSTANCE_ID}" || -z "${AVAILABILITY_ZONE}" ]]; then
    echo "Unable to determine current helper instance metadata. Pass --instance-id and --availability-zone explicitly or use --volume-id." >&2
    exit 1
  fi

  echo "Creating encrypted gp3 model volume (${SIZE_GB} GiB) in ${AVAILABILITY_ZONE}..."
  VOLUME_ID="$(aws ec2 create-volume \
    --region "${REGION}" \
    --availability-zone "${AVAILABILITY_ZONE}" \
    --size "${SIZE_GB}" \
    --volume-type gp3 \
    --encrypted \
    --query 'VolumeId' \
    --output text)"
  AUTO_CREATED_VOLUME="true"

  wait_for_volume_state "${VOLUME_ID}" "available"

  BEFORE_DEVICES_FILE="$(mktemp)"
  AFTER_DEVICES_FILE="$(mktemp)"
  list_block_devices | sort >"${BEFORE_DEVICES_FILE}"

  echo "Attaching volume ${VOLUME_ID} to helper instance ${INSTANCE_ID} as ${ATTACH_DEVICE}..."
  aws ec2 attach-volume \
    --region "${REGION}" \
    --volume-id "${VOLUME_ID}" \
    --instance-id "${INSTANCE_ID}" \
    --device "${ATTACH_DEVICE}" >/dev/null
  ATTACHED_BY_SCRIPT="true"
  wait_for_attachment_state "${VOLUME_ID}" "attached"

  if [[ -z "${DEVICE}" ]]; then
    for _ in $(seq 1 24); do
      list_block_devices | sort >"${AFTER_DEVICES_FILE}"
      DEVICE="$(detect_new_device "${BEFORE_DEVICES_FILE}" "${AFTER_DEVICES_FILE}")"
      [[ -n "${DEVICE}" ]] && break
      sleep 5
    done
  fi
fi

if [[ -z "${DEVICE}" ]]; then
  echo "Could not auto-detect the attached device. Pass --device explicitly." >&2
  exit 1
fi

if [[ ! -b "${DEVICE}" ]]; then
  echo "Device not found or not a block device: ${DEVICE}" >&2
  exit 1
fi

if [[ "${SNAPSHOT_ONLY}" != "true" ]]; then
  ${SUDO} mkdir -p "${MOUNT_POINT}"

  EXISTING_FS="$(${SUDO} blkid -o value -s TYPE "${DEVICE}" 2>/dev/null || true)"
  if [[ -z "${EXISTING_FS}" ]]; then
    case "${FILESYSTEM}" in
      ext4)
        ${SUDO} mkfs.ext4 -F "${DEVICE}" >/dev/null
        ;;
      xfs)
        ${SUDO} mkfs.xfs -f "${DEVICE}" >/dev/null
        ;;
      *)
        echo "Unsupported filesystem: ${FILESYSTEM}" >&2
        exit 1
        ;;
    esac
  fi

  if findmnt -n "${MOUNT_POINT}" >/dev/null 2>&1; then
    CURRENT_SOURCE="$(findmnt -n -o SOURCE "${MOUNT_POINT}")"
    if [[ "${CURRENT_SOURCE}" != "${DEVICE}" ]]; then
      echo "Mount point ${MOUNT_POINT} is already in use by ${CURRENT_SOURCE}." >&2
      exit 1
    fi
  else
    ${SUDO} mount "${DEVICE}" "${MOUNT_POINT}"
    MOUNTED_BY_SCRIPT="true"
  fi

  ${SUDO} mkdir -p "${MOUNT_POINT}/$(dirname "${MODEL_FILENAME}")"
  ${SUDO} chown -R "$(id -u):$(id -g)" "${MOUNT_POINT}"

  HF_ARGS=(download "${MODEL_REPO}" "${MODEL_FILENAME}" --repo-type model --local-dir "${MOUNT_POINT}")
  if [[ -n "${HF_TOKEN}" ]]; then
    HF_ARGS+=(--token "${HF_TOKEN}")
  fi

  echo "Downloading ${MODEL_FILENAME} from ${MODEL_REPO}..."
  run_hf "${HF_ARGS[@]}"
  sync
  ${SUDO} sync
fi

SNAPSHOT_ID="$(aws ec2 create-snapshot \
  --volume-id "${VOLUME_ID}" \
  --description "${DESCRIPTION}" \
  --region "${REGION}" \
  --query 'SnapshotId' \
  --output text)"

if [[ -n "${TFVARS}" ]]; then
  update_tfvars_string "model_ebs_snapshot_id" "${SNAPSHOT_ID}" "${TFVARS}"
fi

echo "Volume:   ${VOLUME_ID}"
echo "Device:   ${DEVICE}"
echo "Snapshot: ${SNAPSHOT_ID}"
if [[ -n "${TFVARS}" ]]; then
  echo "Updated ${TFVARS} with model_ebs_snapshot_id = \"${SNAPSHOT_ID}\""
fi
if [[ "${AUTO_CREATED_VOLUME}" == "true" && "${KEEP_VOLUME}" != "true" ]]; then
  echo "The auto-created staging volume will be detached and deleted during cleanup."
fi
