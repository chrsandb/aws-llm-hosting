#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: create-model-volume.sh --region REGION --availability-zone AZ --size-gb SIZE
EOF
}

REGION=""
AZ=""
SIZE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --availability-zone) AZ="$2"; shift 2 ;;
    --size-gb) SIZE="$2"; shift 2 ;;
    *) usage; exit 1 ;;
  esac
done

if [[ -z "${REGION}" || -z "${AZ}" || -z "${SIZE}" ]]; then
  usage
  exit 1
fi

aws ec2 create-volume \
  --region "${REGION}" \
  --availability-zone "${AZ}" \
  --size "${SIZE}" \
  --volume-type gp3 \
  --encrypted
