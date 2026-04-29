# Architecture Notes

## Chosen Frontend

LiteLLM runs on ECS Fargate in private subnets behind:

- a public ALB that only forwards API paths
- a separate internal ALB that exposes the admin UI for internal operators

This keeps the user-facing API managed and patchable without adding EC2 management overhead to the proxy tier.

## Chosen Backend

`llama.cpp` runs on private GPU EC2 instances in an Auto Scaling Group. Instances receive traffic only from an internal backend ALB. The model is expected to be present from an attached snapshot-backed EBS volume or a preloaded AMI.

## Network Assumptions

- Existing VPCs and subnets are supplied to Terraform.
- Routing between frontend and backend private networks already exists or is handled outside this repository.
- Security groups enforce application boundaries; no backend public IPs are created.
