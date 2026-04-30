# Operations

This runbook owns post-deploy operations. Use it after the platform has already been created.

## Roll Backend Instances

Start an ASG refresh:

```bash
./scripts/start-instance-refresh.sh llm-hosting-prod-backend eu-north-1
```

You can also roll instances by changing launch template inputs and re-running Terraform.

## Rollback

1. Restore the prior AMI, model snapshot, or `llama_cpp_image_tag`.
2. Apply Terraform.
3. Start another instance refresh.
4. Validate `/health` and a short completion request.

## Cleanup

Use the safe cleanup wrapper instead of a raw destroy when you want to remove the deployment:

```bash
./scripts/cleanup-deployment.sh --tfvars examples/generated.prod.tfvars
```

Key safeguards:

- only destroys Terraform-managed resources in state
- does not remove pre-existing VPCs, subnets, route tables, or hosted zones
- refuses cleanup if Terraform state contains managed network resources, unless you pass `--allow-network-destroy`

To also remove image artifacts created outside Terraform:

```bash
./scripts/cleanup-deployment.sh \
  --tfvars examples/generated.prod.tfvars \
  --delete-ami-id ami-0123456789abcdef0 \
  --delete-snapshot-id snap-0123456789abcdef0 \
  --force
```

## Upgrade llama.cpp

1. Update `llama_cpp_image` or `llama_cpp_image_tag` in your `tfvars`.
2. Run:

```bash
make plan TFVARS=examples/generated.prod.tfvars
make apply TFVARS=examples/generated.prod.tfvars
```

3. Refresh the backend ASG if required:

```bash
./scripts/start-instance-refresh.sh llm-hosting-prod-backend eu-north-1
```

4. Validate backend health and a small public `/v1` request.

## Change llama.cpp Settings

Adjust `llama_cpp_settings` in your deployment `tfvars`, then apply Terraform.

Important runtime settings include:

- `ctx_size`
- `n_parallel`
- `n_gpu_layers`
- `temp`
- `top_p`
- `top_k`
- `min_p`
- `think_budget`
- `jinja`

Recommended operational rule:

- keep `n_parallel = 1` unless you have validated higher concurrency for your workload

## LiteLLM Secrets

Create a master key yourself if you do not want Terraform to generate it:

```bash
aws secretsmanager create-secret \
  --name llm-hosting/prod/litellm-master-key \
  --secret-string "$(openssl rand -hex 32)"
```

To rotate using the helper:

```bash
./scripts/create-litellm-secret.sh \
  --region eu-north-1 \
  --name llm-hosting/prod/litellm-master-key
```

## Internal Admin Access

Use the internal admin ALB DNS name from Terraform outputs. Reach it through:

- VPN
- Direct Connect
- peering or transit gateway routes from an internal admin network

## Access Methods

Preferred access method:

```bash
aws ssm start-session --target i-0123456789abcdef0
```

Optional SSH remains disabled by default. Enable it only when required by setting:

- `enable_ssh_access = true`
- `ssh_key_name`
- `ssh_allowed_cidrs`

## Packer Validation

```bash
cp packer/backend.example.pkrvars.hcl packer/backend.auto.pkrvars.hcl
packer init packer/backend-ami.pkr.hcl
packer validate -var-file=packer/backend.auto.pkrvars.hcl packer/backend-ami.pkr.hcl
```
