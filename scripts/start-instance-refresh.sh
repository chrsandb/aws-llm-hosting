#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <asg-name> <region>"
  exit 1
fi

aws autoscaling start-instance-refresh \
  --auto-scaling-group-name "$1" \
  --region "$2" \
  --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":600}'
