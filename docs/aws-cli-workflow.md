# AWS CLI Workflow

This runbook covers the AWS CLI steps that operators usually need before Terraform can work smoothly.

## 1. Confirm AWS Access

```bash
./scripts/aws-preflight.sh --region eu-north-1
```

Optional:

- add `--profile your-profile`
- set `AWS_PROFILE=your-profile`

## 2. Discover Existing VPC Inputs

Inspect a single VPC:

```bash
./scripts/discover-vpc-details.sh \
  --region eu-north-1 \
  --vpc-id vpc-0123456789abcdef0 | jq
```

This returns:

- VPC CIDR and tags
- subnet IDs and inferred public/private classification
- associated route table IDs

## 3. Generate a Starter tfvars File

```bash
./scripts/generate-existing-vpc-tfvars.sh \
  --region eu-north-1 \
  --frontend-vpc-id vpc-frontend123 \
  --backend-vpc-id vpc-backend123 \
  --project-name llm-hosting \
  --environment prod \
  --domain-name llm.example.com \
  --route53-zone-id Z1234567890EXAMPLE > examples/generated.prod.tfvars
```

Review the generated file and then fill in:

- `backend_ami_id`
- `model_ebs_snapshot_id`
- admin CIDRs
- any overrides for frontend count or llama settings

## 4. Create or Rotate the LiteLLM Master Key

```bash
./scripts/create-litellm-secret.sh \
  --region eu-north-1 \
  --name llm-hosting/prod/litellm-master-key
```

If you use this script, set:

- `create_litellm_master_key_secret = false`
- `existing_litellm_master_key_secret_arn = "arn:..."`

## 5. Model Snapshot Preparation

Create the initial EBS volume:

```bash
./scripts/create-model-volume.sh \
  --region eu-north-1 \
  --availability-zone eu-north-1a \
  --size-gb 300
```

Then copy the GGUF file onto the mounted volume and snapshot it with:

```bash
./scripts/update-model-snapshot.sh vol-0123456789abcdef0 "qwen3.6-35b-a3b initial snapshot" eu-north-1
```

## 6. Run Terraform

```bash
make init
make plan TFVARS=../examples/generated.prod.tfvars
make apply TFVARS=../examples/generated.prod.tfvars
```

## 7. Post-Deploy Checks

Check backend health:

```bash
./scripts/check-backend-health.sh internal-backend-alb-123.eu-north-1.elb.amazonaws.com
```

Roll the ASG when needed:

```bash
./scripts/start-instance-refresh.sh llm-hosting-prod-backend eu-north-1
```
