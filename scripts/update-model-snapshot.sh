#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <volume-id> <description> <region>"
  exit 1
fi

aws ec2 create-snapshot \
  --volume-id "$1" \
  --description "$2" \
  --region "$3"
