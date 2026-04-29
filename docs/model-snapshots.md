# Model Snapshot Runbook

Use snapshot-backed model volumes for production. This avoids repeated downloads and gives you an immutable model artifact you can roll forward and back.

## Create the Initial Snapshot

1. Launch a temporary GPU or storage helper instance in the backend VPC.
2. Attach a new EBS volume sized for the GGUF file and future headroom.
3. Mount it at `/models`.
4. Copy `UD-Q6_K_XL.gguf` onto the volume.
5. Unmount the volume and create an EBS snapshot.
6. Set `model_source = "ebs_snapshot"` and `model_ebs_snapshot_id = "snap-..."`.

Helper:

```bash
./scripts/create-model-volume.sh \
  --region eu-north-1 \
  --availability-zone eu-north-1a \
  --size-gb 300
```

## Update the Snapshot

1. Create a new volume from the current snapshot.
2. Attach it to a helper instance.
3. Replace or add the new model file.
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
