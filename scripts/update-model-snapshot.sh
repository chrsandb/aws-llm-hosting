#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  update-model-snapshot.sh --volume-id VOL --description DESC --region REGION [options]

Populate an attached EBS volume with a GGUF model from Hugging Face and create
an EBS snapshot from that volume.

Options:
  --volume-id VOL                 EBS volume ID to snapshot
  --description DESC              Snapshot description
  --region REGION                 AWS region
  --tfvars FILE                   Read model_repo and model_filename from a tfvars file
  --model-repo REPO               Hugging Face repo, for example unsloth/Qwen3.6-35B-A3B-GGUF
  --model-filename FILE           Model file inside the repo, for example UD-Q6_K_XL.gguf
  --device PATH                   Attached block device path, default: /dev/nvme1n1
  --mount-point PATH              Mount point, default: /mnt/models
  --filesystem TYPE               Filesystem to create if needed, default: ext4
  --config FILE                   Shell-style config file. Supports HF_TOKEN and model defaults.
  --hf-token TOKEN                Hugging Face token. Overrides config and env.
  --snapshot-only                 Skip download/mount work and only create the snapshot
  --help                          Show this help text

Examples:
  ./scripts/update-model-snapshot.sh \
    --volume-id vol-0123456789abcdef0 \
    --description "qwen3.6-35b-a3b initial snapshot" \
    --region eu-north-1 \
    --tfvars examples/generated.prod.tfvars \
    --config ./.hf.env

  ./scripts/update-model-snapshot.sh \
    --volume-id vol-0123456789abcdef0 \
    --description "snapshot only" \
    --region eu-north-1 \
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

VOLUME_ID=""
DESCRIPTION=""
REGION=""
TFVARS=""
MODEL_REPO=""
MODEL_FILENAME=""
DEVICE="/dev/nvme1n1"
MOUNT_POINT="/mnt/models"
FILESYSTEM="ext4"
CONFIG_FILE=""
HF_TOKEN="${HF_TOKEN:-}"
SNAPSHOT_ONLY="false"

CLI_MODEL_REPO=""
CLI_MODEL_FILENAME=""
CLI_DEVICE=""
CLI_MOUNT_POINT=""
CLI_FILESYSTEM=""
CLI_HF_TOKEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --volume-id) VOLUME_ID="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --tfvars) TFVARS="$2"; shift 2 ;;
    --model-repo) MODEL_REPO="$2"; CLI_MODEL_REPO="$2"; shift 2 ;;
    --model-filename) MODEL_FILENAME="$2"; CLI_MODEL_FILENAME="$2"; shift 2 ;;
    --device) DEVICE="$2"; CLI_DEVICE="$2"; shift 2 ;;
    --mount-point) MOUNT_POINT="$2"; CLI_MOUNT_POINT="$2"; shift 2 ;;
    --filesystem) FILESYSTEM="$2"; CLI_FILESYSTEM="$2"; shift 2 ;;
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --hf-token) HF_TOKEN="$2"; CLI_HF_TOKEN="$2"; shift 2 ;;
    --snapshot-only) SNAPSHOT_ONLY="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${VOLUME_ID}" || -z "${DESCRIPTION}" || -z "${REGION}" ]]; then
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

if [[ "${SNAPSHOT_ONLY}" != "true" ]]; then
  if [[ -z "${MODEL_REPO}" || -z "${MODEL_FILENAME}" ]]; then
    echo "model_repo and model_filename are required unless --snapshot-only is used." >&2
    exit 1
  fi

  for cmd in aws lsblk sync; do
    command -v "${cmd}" >/dev/null 2>&1 || {
      echo "Missing required command: ${cmd}" >&2
      exit 1
    }
  done

  if [[ ! -b "${DEVICE}" ]]; then
    echo "Device not found or not a block device: ${DEVICE}" >&2
    exit 1
  fi

  MOUNTED_BY_SCRIPT="false"
  cleanup() {
    if [[ "${MOUNTED_BY_SCRIPT}" == "true" ]]; then
      ${SUDO} umount "${MOUNT_POINT}" >/dev/null 2>&1 || true
    fi
  }
  trap cleanup EXIT

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

echo "Created snapshot: ${SNAPSHOT_ID}"
