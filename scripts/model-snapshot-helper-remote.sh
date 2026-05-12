#!/usr/bin/env bash
set -euo pipefail

decode_b64() {
  printf '%s' "$1" | base64 -d
}

MODEL_REPO="$(decode_b64 "${MODEL_REPO_B64}")"
MODEL_FILENAME="$(decode_b64 "${MODEL_FILENAME_B64}")"
HF_TOKEN="$(decode_b64 "${HF_TOKEN_B64:-}")"
MOUNT_POINT="$(decode_b64 "${MOUNT_POINT_B64:-}")"
FILESYSTEM="$(decode_b64 "${FILESYSTEM_B64:-}")"
MODEL_VOLUME_ID="$(decode_b64 "${MODEL_VOLUME_ID_B64:-}")"

MOUNT_POINT="${MOUNT_POINT:-/mnt/models}"
FILESYSTEM="${FILESYSTEM:-ext4}"
TOOLS_VENV="/opt/aws-llm-hosting-tools"

echo "[helper] Installing model snapshot prerequisites..."
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export APT_LISTCHANGES_FRONTEND=none
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none apt-get update
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none apt-get install -y ca-certificates curl e2fsprogs python3 python3-venv util-linux xfsprogs

if [[ ! -x "${TOOLS_VENV}/bin/hf" ]]; then
  echo "[helper] Installing Hugging Face CLI..."
  sudo rm -rf "${TOOLS_VENV}"
  sudo python3 -m venv "${TOOLS_VENV}"
  sudo "${TOOLS_VENV}/bin/pip" install --upgrade pip >/dev/null
  sudo "${TOOLS_VENV}/bin/pip" install huggingface_hub >/dev/null
fi

HF_BIN="${TOOLS_VENV}/bin/hf"
LSBLK_BIN="$(command -v lsblk || true)"
FINDMNT_BIN="$(command -v findmnt || true)"
BLKID_BIN="$(command -v blkid || true)"
MKFS_EXT4_BIN="$(command -v mkfs.ext4 || true)"
MKFS_XFS_BIN="$(command -v mkfs.xfs || true)"
UDEVADM_BIN="$(command -v udevadm || true)"

for tool in "${LSBLK_BIN}" "${FINDMNT_BIN}" "${BLKID_BIN}" "${MKFS_EXT4_BIN}" "${MKFS_XFS_BIN}" "${UDEVADM_BIN}"; do
  if [[ -z "${tool}" ]]; then
    echo "[helper] Missing required filesystem tool after install." >&2
    exit 1
  fi
done

echo "[helper] Detecting attached model volume..."
if [[ -z "${MODEL_VOLUME_ID}" ]]; then
  echo "[helper] MODEL_VOLUME_ID_B64 was not provided." >&2
  exit 1
fi

DEVICE=""
for _ in $(seq 1 24); do
  while IFS= read -r candidate; do
    [[ -b "${candidate}" ]] || continue
    serial="$("${UDEVADM_BIN}" info --query=property --name "${candidate}" 2>/dev/null | sed -n 's/^ID_SERIAL=//p' | head -n1 || true)"
    if [[ "${serial}" == vol* && "${serial#vol}" == "${MODEL_VOLUME_ID#vol-}" ]]; then
      DEVICE="${candidate}"
      break
    fi
  done < <("${LSBLK_BIN}" -dnpo NAME,TYPE | awk '$2 == "disk" { print $1 }')
  [[ -n "${DEVICE}" ]] && break
  echo "[helper] Waiting for attached model volume ${MODEL_VOLUME_ID} to appear as a local block device..."
  sleep 5
done

if [[ -z "${DEVICE}" || ! -b "${DEVICE}" ]]; then
  echo "[helper] Could not map EBS volume ${MODEL_VOLUME_ID} to a local block device." >&2
  "${LSBLK_BIN}" -dnpo NAME,SIZE,TYPE,MOUNTPOINT >&2 || true
  exit 1
fi

echo "[helper] Using device ${DEVICE}"

EXISTING_FS="$(sudo "${BLKID_BIN}" -o value -s TYPE "${DEVICE}" 2>/dev/null || true)"
if [[ -z "${EXISTING_FS}" ]]; then
  echo "[helper] Creating ${FILESYSTEM} filesystem on ${DEVICE}..."
  case "${FILESYSTEM}" in
    ext4)
      sudo "${MKFS_EXT4_BIN}" -F "${DEVICE}" >/dev/null
      ;;
    xfs)
      sudo "${MKFS_XFS_BIN}" -f "${DEVICE}" >/dev/null
      ;;
    *)
      echo "[helper] Unsupported filesystem: ${FILESYSTEM}" >&2
      exit 1
      ;;
  esac
fi

sudo mkdir -p "${MOUNT_POINT}"
if "${FINDMNT_BIN}" -n "${MOUNT_POINT}" >/dev/null 2>&1; then
  CURRENT_SOURCE="$("${FINDMNT_BIN}" -n -o SOURCE "${MOUNT_POINT}")"
  if [[ "${CURRENT_SOURCE}" != "${DEVICE}" ]]; then
    echo "[helper] Mount point ${MOUNT_POINT} already in use by ${CURRENT_SOURCE}." >&2
    exit 1
  fi
else
  echo "[helper] Mounting ${DEVICE} on ${MOUNT_POINT}..."
  sudo mount "${DEVICE}" "${MOUNT_POINT}"
fi

sudo mkdir -p "${MOUNT_POINT}/$(dirname "${MODEL_FILENAME}")"
sudo chown -R "$(id -u):$(id -g)" "${MOUNT_POINT}"

HF_ARGS=(download "${MODEL_REPO}" "${MODEL_FILENAME}" --repo-type model --local-dir "${MOUNT_POINT}")
if [[ -n "${HF_TOKEN}" ]]; then
  HF_ARGS+=(--token "${HF_TOKEN}")
fi

echo "[helper] Downloading ${MODEL_FILENAME} from ${MODEL_REPO}..."
"${HF_BIN}" "${HF_ARGS[@]}"
sync
sudo sync
echo "[helper] Model payload is ready on ${DEVICE}"
