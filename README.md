# AWS LLM Hosting Platform

Production-oriented Infrastructure-as-Code repository for hosting a shared developer LLM platform on AWS with:

- Terraform
- Packer
- LiteLLM Proxy
- ECS Fargate frontend
- Internal backend ALB
- Auto Scaling Group of private GPU instances
- `llama.cpp` CUDA server for `unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q6_K_XL`

The default deployment target is `eu-north-1` and is sized for roughly 10 developers with a baseline of one `g6e.2xlarge` backend instance and configurable scale-out.

## What This Repo Deploys

Architecture summary:

```mermaid
flowchart LR
  Internet[Public Internet] --> DNS[Route53 DNS]
  DNS --> ACM[ACM Public Certificate]
  Internet --> PublicALB[Public ALB 443]
  PublicALB --> LiteLLM[LiteLLM on ECS Fargate]
  Admin[VPN / Admin CIDRs] --> AdminALB[Internal Admin ALB]
  AdminALB --> LiteLLM
  LiteLLM --> Postgres[(RDS PostgreSQL)]
  LiteLLM --> Redis[(Optional Redis)]
  LiteLLM --> BackendALB[Internal Backend ALB]
  BackendALB --> ASG[Private GPU ASG]
  ASG --> Llama[llama.cpp in Docker]
  Llama --> Model[(Model snapshot or baked path)]
```

Supported public API contract:

- Public clients use `https://<domain>/v1/*`
- LiteLLM Admin UI is internal-only or CIDR-restricted
- Anthropic-native ingress is not guaranteed by default

Core assumptions:

- existing VPCs and subnets are supplied as Terraform inputs
- backend EC2 instances stay private-only
- SSM Session Manager is the default access path
- model assets are prepared outside Terraform and then attached or referenced

For deeper design rationale and network assumptions, see [docs/architecture.md](/home/csandberg/projects/aws-llm-hosting/docs/architecture.md).

## Before You Start

Prerequisites:

- AWS account with permissions for Route53, ACM, ECS, EC2, Auto Scaling, ELBv2, IAM, CloudWatch, RDS, Secrets Manager, and SSM
- Existing VPCs and subnet IDs for:
  - frontend public subnets
  - frontend private subnets
  - backend private subnets
- Existing route tables unless `assume_existing_vpc_routing = true`
- Terraform `>= 1.7`
- Packer `>= 1.10`
- AWS CLI v2
- Session Manager plugin for SSM shell access

Install local tooling:

```bash
./scripts/install-dependencies-debian-ubuntu.sh
```

Check AWS access:

```bash
./scripts/aws-preflight.sh --region eu-north-1
```

For detailed AWS discovery, readiness, and tfvars generation steps, see [docs/aws-cli-workflow.md](/home/csandberg/projects/aws-llm-hosting/docs/aws-cli-workflow.md).

## Initial Setup

Follow this sequence top-to-bottom for the first deployment.

### 1. Install local dependencies

Purpose: install Terraform, Packer, AWS CLI v2, Session Manager plugin, and helper tools.

```bash
./scripts/install-dependencies-debian-ubuntu.sh
```

Success signal: the script prints installed versions for Terraform, Packer, AWS CLI, and the Session Manager plugin.

### 2. Run AWS preflight

Purpose: verify the active AWS identity, region, service access, and GPU instance availability.

```bash
./scripts/aws-preflight.sh --region eu-north-1
```

Success signal: the output ends with `Fail : 0`.

At this stage, keep the preflight focused on AWS identity, region, and service access:

```bash
./scripts/aws-preflight.sh --region eu-north-1
```

You can run the deeper domain, hosted zone, and VPC-aware checks later as part of the readiness report flow.

More detail: [docs/aws-cli-workflow.md](/home/csandberg/projects/aws-llm-hosting/docs/aws-cli-workflow.md).

### 3. Inspect VPC inputs

Purpose: confirm subnet roles and route tables for the existing frontend and backend VPCs.

Inspect a VPC:

```bash
./scripts/discover-vpc-details.sh \
  --region eu-north-1 \
  --vpc-id vpc-0123456789abcdef0 | jq
```

Success signal: you understand which subnets and route tables will be used for frontend and backend deployment.

More detail: [docs/aws-cli-workflow.md](/home/csandberg/projects/aws-llm-hosting/docs/aws-cli-workflow.md).

### 4. Register the domain and set up the hosted zone

Purpose: make sure Terraform can request an ACM certificate and create DNS validation records.

Manual steps:

1. Register the domain in Route53 Domains or another registrar.
2. If `create_route53_zone = true`, Terraform will create the public hosted zone.
3. If the domain is registered outside AWS, update the registrar name servers after the hosted zone exists.

Success signal: the domain exists, and either:

- you know the target `route53_zone_id`, or
- you plan to set `create_route53_zone = true`

### 5. Generate a readiness report

Purpose: create a shareable Markdown summary of AWS access, DNS readiness, and VPC shape.

```bash
./scripts/aws-readiness-report.sh \
  --region eu-north-1 \
  --domain-name llm.example.com \
  --route53-zone-id Z1234567890EXAMPLE \
  --frontend-vpc-id vpc-frontend123 \
  --backend-vpc-id vpc-backend123 \
  --output docs/readiness-report.md
```

Success signal: the script writes `docs/readiness-report.md`.

### 6. Generate a starter tfvars file

Purpose: create a deployment config that includes your existing VPC inputs and known DNS values.

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

Success signal: `examples/generated.prod.tfvars` exists and contains your VPC, subnet, route table, and domain inputs.

More detail: [docs/aws-cli-workflow.md](/home/csandberg/projects/aws-llm-hosting/docs/aws-cli-workflow.md).

### 7. Create the LiteLLM master key if Terraform will not generate it

Purpose: prepare the admin/master key outside Terraform when you want explicit secret ownership.

```bash
./scripts/create-litellm-secret.sh \
  --region eu-north-1 \
  --name llm-hosting/prod/litellm-master-key
```

If you do this, set these in your `tfvars`:

- `create_litellm_master_key_secret = false`
- `existing_litellm_master_key_secret_arn = "arn:..."`

Success signal: the secret exists in Secrets Manager.

More detail: [docs/aws-cli-workflow.md](/home/csandberg/projects/aws-llm-hosting/docs/aws-cli-workflow.md).

### 8. Build the backend AMI

Purpose: create the GPU-ready backend image with Docker, NVIDIA runtime, systemd units, and CloudWatch agent installed.

Start from the example variables file:

```bash
cp packer/backend.example.pkrvars.hcl packer/backend.auto.pkrvars.hcl
make packer-init
packer validate -var-file=packer/backend.auto.pkrvars.hcl packer/backend-ami.pkr.hcl
make packer-build
```

Success signal: Packer outputs a new AMI ID and writes `packer/manifest.json`.

### 9. Create the model snapshot

Purpose: prepare the model volume snapshot used by backend instances in production.

Create the initial volume:

```bash
./scripts/create-model-volume.sh \
  --region eu-north-1 \
  --availability-zone eu-north-1a \
  --size-gb 300
```

Then copy `UD-Q6_K_XL.gguf` onto the mounted volume and create a snapshot:

```bash
./scripts/update-model-snapshot.sh \
  vol-0123456789abcdef0 \
  "qwen3.6-35b-a3b initial snapshot" \
  eu-north-1
```

Success signal: you have a usable `snap-...` value for `model_ebs_snapshot_id`.

More detail: [docs/model-snapshots.md](/home/csandberg/projects/aws-llm-hosting/docs/model-snapshots.md).

### 10. Fill in the deployment tfvars file

Purpose: combine discovered network inputs, image artifacts, DNS, and secrets into one deployment config.

Edit:

- `examples/generated.prod.tfvars`

Fill in at least:

- `backend_ami_id`
- `model_ebs_snapshot_id`
- `route53_zone_id` or `create_route53_zone = true`
- `admin_allowed_cidrs`
- any environment-specific overrides

Success signal: the file contains no placeholder AMI or snapshot IDs.

### 11. Run Terraform

Purpose: create the managed infrastructure for the deployment.

```bash
make init
make plan TFVARS=examples/generated.prod.tfvars
make apply TFVARS=examples/generated.prod.tfvars
```

Success signal: Terraform completes successfully and prints outputs, including the public API endpoint and internal ALB names.

### 12. Wait for the platform to become healthy

Purpose: confirm ACM, ECS, and the backend ASG all stabilize before testing clients.

Wait for:

- ACM validation to complete
- ECS service tasks to become healthy
- backend ASG instances to pass the internal ALB `/health` check

Optional backend check:

```bash
./scripts/check-backend-health.sh internal-backend-alb-123.eu-north-1.elb.amazonaws.com
```

Success signal: the backend health endpoint returns HTTP 200 and the ECS service stays stable.

### 13. Test the public endpoint

Purpose: confirm the public LiteLLM API is reachable.

```bash
curl https://your-domain.example/v1/models
```

Success signal: you get a valid JSON response from the public `/v1` endpoint.

Use OpenAI-compatible clients against the public endpoint by default.

## Common Tasks After Deployment

Use this as the quick index for later tasks.

| Task | Primary entrypoint | Details |
|---|---|---|
| Check environment readiness | `./scripts/aws-readiness-report.sh` | [docs/aws-cli-workflow.md](/home/csandberg/projects/aws-llm-hosting/docs/aws-cli-workflow.md) |
| Create deployment tfvars from existing VPCs | `./scripts/generate-existing-vpc-tfvars.sh` | [docs/aws-cli-workflow.md](/home/csandberg/projects/aws-llm-hosting/docs/aws-cli-workflow.md) |
| Build or update model snapshot | `create-model-volume.sh`, `update-model-snapshot.sh` | [docs/model-snapshots.md](/home/csandberg/projects/aws-llm-hosting/docs/model-snapshots.md) |
| Access the internal admin UI | internal admin ALB output | [docs/operations.md](/home/csandberg/projects/aws-llm-hosting/docs/operations.md) |
| Add or rotate LiteLLM keys/secrets | `create-litellm-secret.sh` or admin UI | [docs/operations.md](/home/csandberg/projects/aws-llm-hosting/docs/operations.md) |
| Change llama.cpp settings | edit `llama_cpp_settings` and apply | [docs/operations.md](/home/csandberg/projects/aws-llm-hosting/docs/operations.md) |
| Switch models | snapshot/model variable update | [docs/model-snapshots.md](/home/csandberg/projects/aws-llm-hosting/docs/model-snapshots.md) |
| Refresh or roll backend instances | `./scripts/start-instance-refresh.sh` | [docs/operations.md](/home/csandberg/projects/aws-llm-hosting/docs/operations.md) |
| Upgrade llama.cpp | update image tag and apply | [docs/operations.md](/home/csandberg/projects/aws-llm-hosting/docs/operations.md) |
| Roll back | restore previous values and refresh | [docs/operations.md](/home/csandberg/projects/aws-llm-hosting/docs/operations.md) |
| Clean up safely | `make cleanup` or `cleanup-deployment.sh` | [docs/operations.md](/home/csandberg/projects/aws-llm-hosting/docs/operations.md) |
| Use SSM or optionally SSH | `aws ssm start-session` | [docs/operations.md](/home/csandberg/projects/aws-llm-hosting/docs/operations.md) |
| Validate and format | `make fmt`, `make validate` | [docs/operations.md](/home/csandberg/projects/aws-llm-hosting/docs/operations.md) |

## Troubleshooting

Keep these checks in mind during first deployment:

- `aws-preflight.sh` shows failures:
  - fix AWS auth, region config, or missing service permissions first
- ACM validation does not complete:
  - verify the public hosted zone is authoritative for the domain
- ECS service does not stabilize:
  - inspect LiteLLM CloudWatch logs and verify DB/secret access
- Backend targets stay unhealthy:
  - check `/var/log/cloud-init-output.log`, `journalctl -u llama-server`, and the model path
- Public `/v1/models` does not respond:
  - confirm DNS points at the public ALB and backend health is green
- Packer or Terraform validation fails:
  - rerun `make validate` and fix the first reported error

For deeper runbooks:

- [docs/aws-cli-workflow.md](/home/csandberg/projects/aws-llm-hosting/docs/aws-cli-workflow.md)
- [docs/model-snapshots.md](/home/csandberg/projects/aws-llm-hosting/docs/model-snapshots.md)
- [docs/operations.md](/home/csandberg/projects/aws-llm-hosting/docs/operations.md)
- [docs/architecture.md](/home/csandberg/projects/aws-llm-hosting/docs/architecture.md)
