#!/usr/bin/env bash
set -euo pipefail

python3 -c '
import json
import subprocess
import sys

query = json.load(sys.stdin)
name = query["name"]
region = query["region"]

cmd = [
    "aws",
    "secretsmanager",
    "describe-secret",
    "--region",
    region,
    "--secret-id",
    name,
    "--query",
    "{arn:ARN,deleted:DeletedDate}",
    "--output",
    "json",
]

proc = subprocess.run(cmd, capture_output=True, text=True)
if proc.returncode == 0:
    payload = json.loads(proc.stdout)
    deleted = payload.get("deleted")
    result = {
        "exists": "true",
        "arn": payload.get("arn", ""),
        "scheduled_for_deletion": "true" if deleted else "false",
        "lookup_error": "",
    }
else:
    stderr = (proc.stderr or "").strip()
    if "ResourceNotFoundException" in stderr:
        result = {
            "exists": "false",
            "arn": "",
            "scheduled_for_deletion": "false",
            "lookup_error": "",
        }
    else:
        result = {
            "exists": "false",
            "arn": "",
            "scheduled_for_deletion": "false",
            "lookup_error": stderr,
        }

print(json.dumps(result))
'
