# AGENTS.md

## Purpose

This repository provisions an AWS-hosted LLM platform with:

- Terraform for infrastructure
- Packer for the backend GPU AMI
- Docker and systemd for `llama.cpp`
- LiteLLM Proxy as the API frontend
- Private GPU inference instances behind an internal load balancer

## Working Agreements

- Keep infrastructure changes modular and environment-agnostic.
- Prefer existing VPCs and subnets; do not introduce new networking by default.
- Keep backend instances private-only and reachable via SSM first.
- Store secrets in AWS Secrets Manager or SSM Parameter Store only.
- Route frontend traffic through LiteLLM; do not bypass the internal backend load balancer.
- Treat model assets as durable infrastructure artifacts:
  - preferred source is an EBS snapshot or baked AMI path
  - boot-time Hugging Face downloads are for dev/test only

## Repository Layout

- `terraform/`: root stack plus reusable modules
- `packer/`: backend AMI definition
- `docker/`: runtime assets and templates
- `scripts/`: operator workflows such as snapshot creation and upgrades
- `docs/`: operational runbooks and architecture notes
- `examples/`: example `tfvars`

## Change Tracking

- Run `make fmt` and `make validate` before committing infrastructure changes.
- When modifying Terraform variables or outputs, update `README.md` and `examples/`.
- When modifying AMI bootstrap behavior, update both `packer/` and the runbook docs.
