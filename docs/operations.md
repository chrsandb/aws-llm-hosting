# Operations

## Start an ASG Refresh

```bash
./scripts/start-instance-refresh.sh llm-hosting-prod-backend eu-north-1
```

## Rollback

1. Restore the prior AMI, model snapshot, or `llama_cpp_image_tag`.
2. Apply Terraform.
3. Start another instance refresh.
4. Validate `/health` and a short completion request.

## LiteLLM Secrets

Create a master key yourself if you do not want Terraform to generate it:

```bash
aws secretsmanager create-secret \
  --name llm-hosting/prod/litellm-master-key \
  --secret-string "$(openssl rand -hex 32)"
```

## Internal Admin Access

Use the internal admin ALB DNS name from Terraform outputs. Reach it through:

- VPN
- Direct Connect
- peering or transit gateway routes from an internal admin network

## Local Operator Dependencies

On recent Debian or Ubuntu releases:

```bash
./scripts/install-dependencies-debian-ubuntu.sh
```

Installed tools:

- Terraform
- Packer
- AWS CLI v2
- Session Manager plugin
- `jq`, `curl`, `unzip`, `git`, `make`, and APT prerequisites

## Packer Validation

```bash
cp packer/backend.example.pkrvars.hcl packer/backend.auto.pkrvars.hcl
packer init packer/backend-ami.pkr.hcl
packer validate -var-file=packer/backend.auto.pkrvars.hcl packer/backend-ami.pkr.hcl
```
