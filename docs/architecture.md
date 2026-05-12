# Architecture Notes

## Chosen Frontend

LiteLLM runs on ECS Fargate in private subnets behind:

- a public ALB that only forwards API paths
- a separate internal ALB that exposes the admin UI for internal operators

This keeps the user-facing API managed and patchable without adding EC2 management overhead to the proxy tier.

## Metadata Database

The LiteLLM metadata database has two supported deployment modes:

- `rds`: the default managed PostgreSQL path
- `ec2_postgres`: a private single-node PostgreSQL EC2 fallback for accounts where managed RDS creation is blocked

Both modes keep the same Secrets Manager contract for LiteLLM so the frontend reads one stable database URL regardless of implementation.

The `ec2_postgres` mode is intentionally conservative:

- private subnet only
- no public IP
- SSM-first access
- native package install on Ubuntu
- encrypted EBS-backed data volume
- single-node fallback, not HA

## Chosen Backend

`llama.cpp` runs on private GPU EC2 instances in an Auto Scaling Group. Instances receive traffic only from an internal backend ALB. The model is expected to be present from an attached snapshot-backed EBS volume or a preloaded AMI.

## Network Assumptions

- Existing VPCs and subnets are supplied to Terraform.
- Routing between frontend and backend private networks already exists or is handled outside this repository.
- Security groups enforce application boundaries; no backend public IPs are created.
