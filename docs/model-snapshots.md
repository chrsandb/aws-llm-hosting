# Model Snapshot Runbook

Use snapshot-backed model volumes for production. This avoids repeated downloads and gives you an immutable model artifact you can roll forward and back.

## Create the Initial Snapshot

Important:

- `./scripts/run-model-snapshot-job.sh` is the primary Step 9 workflow
- it launches a temporary helper EC2 instance, prepares the model volume over SSM, creates the EBS snapshot locally, updates your tfvars file, and then terminates the helper instance
- it supports `HF_TOKEN` from the shell environment, `--hf-token`, or a shell-style `--config` file
- the default workflow does not require you to log into a helper instance yourself
- `./scripts/update-model-snapshot.sh` remains available as the advanced/manual path when you want to run inside EC2 directly

You can keep the token in a local config file, for example:

```bash
cp examples/huggingface.env.example .hf.env
```

That file can contain:

- `HF_TOKEN`
- optional `SNAPSHOT_DESCRIPTION`
- optional `MODEL_REPO`
- optional `MODEL_FILENAME`
- optional `MOUNT_POINT`

1. Create the HF token config file locally if needed.
2. Run `run-model-snapshot-job.sh` from your workstation.
3. Let it launch a temporary helper EC2 instance in the backend private subnet.
4. Let it prepare the model volume over SSM, create the snapshot, update your tfvars file, and terminate the helper.
5. Confirm that your tfvars file now contains `model_ebs_snapshot_id = "snap-..."`.

For the default `unsloth/Qwen3.6-35B-A3B-GGUF:Q8_0` workflow, `100` GB is a reasonable starting point:

- the model file is roughly 35 to 40 GB
- this leaves room for a second version during update or rollback work
- it avoids over-allocating the initial volume

Increase the size if you plan to:

- keep more than two model revisions on the same working volume
- stage multiple GGUF variants at once
- switch to materially larger models

Example:

```bash
./scripts/run-model-snapshot-job.sh \
  --region eu-north-1 \
  --tfvars examples/generated.prod.tfvars \
  --config ./.hf.env
```

By default, the script derives a snapshot description from the configured model repo and filename. Set `SNAPSHOT_DESCRIPTION` only when you want a custom label.

Optional advanced/manual path:

- if you want to manage the volume lifecycle yourself, you can still use `./scripts/update-model-snapshot.sh` directly from inside an EC2 helper instance
- you can also still use `./scripts/create-model-volume.sh` plus `--volume-id` when you explicitly want full manual control
- `--device` is only a manual override when auto-detection is not wanted or not possible

## Update the Snapshot

1. Update your local HF config or CLI flags if the model repo or filename changed.
2. Re-run `run-model-snapshot-job.sh`.
3. Confirm it prints a new snapshot ID and updates your tfvars file.
4. Apply Terraform and refresh the backend ASG.

## Switching to a New Model

Update the following together:

- `model_repo`
- `model_filename`
- `model_alias`
- `model_path`
- `model_ebs_snapshot_id`

Then roll the ASG.
