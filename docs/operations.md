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

## AWS CLI Helpers

Confirm identity:

```bash
./scripts/aws-preflight.sh --region eu-north-1
```

This also checks the AWS-side prerequisites most operators need before Terraform:

- CLI auth and region
- Session Manager plugin presence
- read access to the services used by this repository
- whether `g6e.2xlarge` is available in-region

Inspect a VPC:

```bash
./scripts/discover-vpc-details.sh --region eu-north-1 --vpc-id vpc-0123456789abcdef0 | jq
```

Generate starter tfvars:

```bash
./scripts/generate-existing-vpc-tfvars.sh \
  --region eu-north-1 \
  --frontend-vpc-id vpc-frontend123 \
  --backend-vpc-id vpc-backend123 \
  --project-name llm-hosting \
  --environment prod \
  --domain-name llm.example.com > examples/generated.prod.tfvars
```

Create or rotate the LiteLLM master key:

```bash
./scripts/create-litellm-secret.sh \
  --region eu-north-1 \
  --name llm-hosting/prod/litellm-master-key
```

## Packer Validation

```bash
cp packer/backend.example.pkrvars.hcl packer/backend.auto.pkrvars.hcl
packer init packer/backend-ami.pkr.hcl
packer validate -var-file=packer/backend.auto.pkrvars.hcl packer/backend-ami.pkr.hcl
```
