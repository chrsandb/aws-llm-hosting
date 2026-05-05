# Model Snapshot Runbook

Use snapshot-backed model volumes for production. This avoids repeated downloads and gives you an immutable model artifact you can roll forward and back.

## Create the Initial Snapshot

Important:

- `./scripts/update-model-snapshot.sh` downloads the selected model file onto the mounted volume and then creates an EBS snapshot
- it supports `HF_TOKEN` from the shell environment, `--hf-token`, or a shell-style `--config` file
- when `--volume-id` is omitted, it creates an encrypted `gp3` staging volume, attaches it to the current helper EC2 instance, auto-detects the device, snapshots it, updates your tfvars, and removes the staging volume
- this workflow does not read a Hugging Face token from AWS secrets by default

You can keep the token in a local config file, for example:

```bash
cp examples/huggingface.env.example .hf.env
```

That file can contain:

- `HF_TOKEN`
- optional `MODEL_REPO`
- optional `MODEL_FILENAME`
- optional `MOUNT_POINT`

1. Launch a temporary GPU or storage helper EC2 instance in the backend environment.
2. Create the HF token config file locally on that helper instance if needed.
3. Run `update-model-snapshot.sh`.
4. Let the script create, attach, populate, snapshot, and clean up the staging volume.
5. Confirm that your tfvars file now contains `model_ebs_snapshot_id = "snap-..."`.

For the default `unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q6_K_XL` workflow, `100` GB is a reasonable starting point:

- the model file is roughly 30 GB
- this leaves room for a second version during update or rollback work
- it avoids over-allocating the initial volume

Increase the size if you plan to:

- keep more than two model revisions on the same working volume
- stage multiple GGUF variants at once
- switch to materially larger models

Example:

```bash
./scripts/update-model-snapshot.sh \
  --description "qwen3.6-35b-a3b initial snapshot" \
  --region eu-north-1 \
  --tfvars examples/generated.prod.tfvars \
  --config ./.hf.env
```

Optional advanced/manual path:

- if you want to manage the volume lifecycle yourself, you can still use `./scripts/create-model-volume.sh`
- in that case, pass `--volume-id` to `update-model-snapshot.sh`
- `--device` is only a manual override when auto-detection is not wanted or not possible

## Update the Snapshot

1. Launch a helper EC2 instance in the backend environment.
2. Update your local HF config or CLI flags if the model repo or filename changed.
3. Re-run `update-model-snapshot.sh`.
4. Confirm it prints a new snapshot ID and updates your tfvars file.
5. Apply Terraform and refresh the backend ASG.

## Switching to a New Model

Update the following together:

- `model_repo`
- `model_filename`
- `model_alias`
- `model_path`
- `model_ebs_snapshot_id`

Then roll the ASG.
