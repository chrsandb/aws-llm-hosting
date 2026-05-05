#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: packer-build-with-progress.sh [options]

Run a Packer AMI build and, once the AMI ID is known, poll AWS for AMI and
snapshot progress so slow image finalization does not look hung.

Options:
  --packer-dir DIR         Packer directory, default: packer
  --packer-vars FILE       Packer vars filename inside --packer-dir
  --template FILE          Packer template filename inside --packer-dir
  --region REGION          AWS region override
  --profile PROFILE        AWS profile override
  --poll-seconds N         Progress poll interval, default: 20
  --help                   Show this help text
EOF
}

PACKER_DIR="packer"
PACKER_VARS="backend.example.pkrvars.hcl"
TEMPLATE_FILE="backend-ami.pkr.hcl"
REGION=""
PROFILE=""
POLL_SECONDS=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    --packer-dir) PACKER_DIR="$2"; shift 2 ;;
    --packer-vars) PACKER_VARS="$2"; shift 2 ;;
    --template) TEMPLATE_FILE="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --poll-seconds) POLL_SECONDS="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

PACKER_VARS_PATH="${PACKER_DIR}/${PACKER_VARS}"
PACKER_TEMPLATE_PATH="${PACKER_DIR}/${TEMPLATE_FILE}"

if [[ ! -f "${PACKER_VARS_PATH}" ]]; then
  echo "Packer vars file not found: ${PACKER_VARS_PATH}" >&2
  exit 1
fi

if [[ ! -f "${PACKER_TEMPLATE_PATH}" ]]; then
  echo "Packer template not found: ${PACKER_TEMPLATE_PATH}" >&2
  exit 1
fi

parse_hcl_string() {
  local key="$1"
  local path="$2"
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]+)\"[[:space:]]*$/\\1/p" "${path}" | head -n1
}

REGION="${REGION:-$(parse_hcl_string "aws_region" "${PACKER_VARS_PATH}")}"
PROFILE="${PROFILE:-${AWS_PROFILE:-}}"

AWS_ARGS=()
[[ -n "${REGION}" ]] && AWS_ARGS+=(--region "${REGION}")
[[ -n "${PROFILE}" ]] && AWS_ARGS+=(--profile "${PROFILE}")

MONITOR_PID=""
AMI_ID=""

log_progress() {
  printf '[ami-progress] %s\n' "$1" >&2
}

monitor_ami_progress() {
  local ami_id="$1"
  local state=""
  local snapshots_json=""
  local status_json=""

  while true; do
    state="$(aws "${AWS_ARGS[@]}" ec2 describe-images \
      --image-ids "${ami_id}" \
      --query 'Images[0].State' \
      --output text 2>/dev/null || true)"

    if [[ -z "${state}" || "${state}" == "None" ]]; then
      log_progress "AMI ${ami_id}: no longer visible"
      return 0
    fi

    snapshots_json="$(aws "${AWS_ARGS[@]}" ec2 describe-images \
      --image-ids "${ami_id}" \
      --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' \
      --output json 2>/dev/null || echo '[]')"

    if [[ "${snapshots_json}" == "[]" ]]; then
      log_progress "AMI ${ami_id}: state=${state}, no snapshots reported yet"
    else
      while IFS= read -r snapshot_id; do
        [[ -z "${snapshot_id}" ]] && continue
        status_json="$(aws "${AWS_ARGS[@]}" ec2 describe-snapshots \
          --snapshot-ids "${snapshot_id}" \
          --query 'Snapshots[0].{State:State,Progress:Progress}' \
          --output json 2>/dev/null || true)"
        if [[ -n "${status_json}" && "${status_json}" != "null" ]]; then
          local snap_state snap_progress
          snap_state="$(jq -r '.State // "unknown"' <<<"${status_json}")"
          snap_progress="$(jq -r '.Progress // "n/a"' <<<"${status_json}")"
          log_progress "AMI ${ami_id}: state=${state}, snapshot ${snapshot_id}: ${snap_state} ${snap_progress}"
        else
          log_progress "AMI ${ami_id}: state=${state}, snapshot ${snapshot_id}: status unavailable"
        fi
      done < <(jq -r '.[]' <<<"${snapshots_json}")
    fi

    if [[ "${state}" == "available" || "${state}" == "failed" || "${state}" == "deregistered" ]]; then
      return 0
    fi

    sleep "${POLL_SECONDS}"
  done
}

start_monitor_if_needed() {
  local line="$1"
  if [[ -n "${MONITOR_PID}" ]]; then
    return
  fi
  if [[ "${line}" =~ AMI:\ (ami-[0-9a-f]+) ]]; then
    AMI_ID="${BASH_REMATCH[1]}"
    log_progress "Detected AMI ${AMI_ID}; polling AWS every ${POLL_SECONDS}s for AMI/snapshot progress"
    monitor_ami_progress "${AMI_ID}" &
    MONITOR_PID="$!"
  fi
}

coproc PACKER_PROC { stdbuf -oL -eL packer build -var-file="${PACKER_VARS_PATH}" "${PACKER_TEMPLATE_PATH}" 2>&1; }

while IFS= read -r line <&"${PACKER_PROC[0]}"; do
  printf '%s\n' "${line}"
  start_monitor_if_needed "${line}"
done

if wait "${PACKER_PROC_PID}"; then
  PACKER_STATUS=0
else
  PACKER_STATUS=$?
fi

if [[ -n "${MONITOR_PID}" ]]; then
  wait "${MONITOR_PID}" || true
fi

if (( PACKER_STATUS != 0 )) && [[ -n "${AMI_ID}" ]]; then
  FINAL_STATE="$(aws "${AWS_ARGS[@]}" ec2 describe-images \
    --image-ids "${AMI_ID}" \
    --query 'Images[0].State' \
    --output text 2>/dev/null || true)"
  if [[ "${FINAL_STATE}" == "available" ]]; then
    log_progress "AMI ${AMI_ID} eventually became available even though Packer returned non-zero"
  fi
fi

exit "${PACKER_STATUS}"
