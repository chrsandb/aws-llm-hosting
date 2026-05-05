# Model Snapshot Runbook

Use snapshot-backed model volumes for production. This avoids repeated downloads and gives you an immutable model artifact you can roll forward and back.

## Create the Initial Snapshot

Important:

- `./scripts/create-model-volume.sh` only creates an encrypted EBS volume
- `./scripts/update-model-snapshot.sh` downloads the selected model file onto the mounted volume and then creates an EBS snapshot
- it supports `HF_TOKEN` from the shell environment, `--hf-token`, or a shell-style `--config` file
- the helper instance must already have the target EBS volume attached locally
- this workflow does not read a Hugging Face token from AWS secrets by default

You can keep the token in a local config file, for example:

```bash
cp examples/huggingface.env.example .hf.env
```

That file can contain:

- `HF_TOKEN`
- optional `MODEL_REPO`
- optional `MODEL_FILENAME`
- optional `DEVICE`
- optional `MOUNT_POINT`

1. Launch a temporary GPU or storage helper instance in the backend VPC.
2. Attach a new EBS volume sized for the GGUF file and future headroom.
3. Note the attached device path on that helper instance, for example `/dev/nvme1n1`.
4. Run the snapshot helper to format, mount, download, and snapshot the model volume.
5. Set `model_source = "ebs_snapshot"` and `model_ebs_snapshot_id = "snap-..."`.

Helper:

```bash
./scripts/create-model-volume.sh \
  --region eu-north-1 \
  --availability-zone eu-north-1a \
  --size-gb 100
```

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
  --volume-id vol-0123456789abcdef0 \
  --description "qwen3.6-35b-a3b initial snapshot" \
  --region eu-north-1 \
  --tfvars examples/generated.prod.tfvars \
  --config ./.hf.env \
  --device /dev/nvme1n1
```

## Update the Snapshot

1. Create a new volume from the current snapshot.
2. Attach it to a helper instance.
3. Re-run `update-model-snapshot.sh` against that volume with the new model settings.
4. Create a new snapshot.
5. Update Terraform with the new snapshot ID.
6. Apply Terraform and refresh the backend ASG.

## Switching to a New Model

Update the following together:

- `model_repo`
- `model_filename`
- `model_alias`
- `model_path`
- `model_ebs_snapshot_id`

Then roll the ASG.
