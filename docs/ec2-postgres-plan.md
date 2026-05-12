# EC2 Postgres Implementation Plan

## Goal

- Add `database_mode = "rds" | "ec2_postgres"`.
- Keep `rds` as the default.
- Provide a private EC2-hosted PostgreSQL fallback.
- Preserve the existing LiteLLM secret contract.
- Preserve normal destroy vs full cleanup secret behavior.

## Decisions Locked

- Only `rds` and `ec2_postgres` are in scope.
- `external_postgres` is not part of this change.
- `rds` remains the default.
- Mode selection is manual via tfvars.
- EC2 Postgres uses native package install, not Docker.
- Backups for v1 are EBS-snapshot based.
- The database host is private-only and receives no public IP.
- Access is SSM-first.
- The EC2 Postgres path is single-node and not HA.

## Success Criteria

- [x] `make validate` passes.
- [x] `terraform plan` works for `database_mode = "rds"`.
- [x] `terraform plan` works for `database_mode = "ec2_postgres"`.
- [x] `rds` mode creates only RDS database resources.
- [x] `ec2_postgres` mode creates only EC2-hosted PostgreSQL resources.
- [x] LiteLLM reads one stable Postgres secret shape in both modes.
- [ ] `make destroy` preserves the Postgres secret.
- [ ] `make cleanup` deletes the Postgres secret.
- [x] Docs and examples clearly explain when to choose `ec2_postgres`.

## Implementation Checklist

### Terraform interface

- [x] Add `database_mode` root variable with validation.
- [x] Add `ec2_postgres` input variables at root.
- [x] Thread the new variables through root module wiring into the frontend/database path.
- [x] Update example tfvars to include `database_mode`.

### Database resource split

- [x] Refactor frontend DB logic so RDS resources are conditional on `database_mode == "rds"`.
- [x] Add a new EC2 Postgres implementation path for `database_mode == "ec2_postgres"`.
- [x] Keep the frontend secret contract stable across both modes.
- [x] Ensure the ECS task definition always references the mode-independent secret ARN/local.

### EC2 Postgres infrastructure

- [x] Add a dedicated module or tightly scoped resource set for:
  - private EC2 instance
  - encrypted data EBS volume
  - security group limited to ECS-to-Postgres traffic
  - SSM-capable instance profile
  - cloud-init or bootstrap logic to install and configure PostgreSQL
- [x] Move Postgres data onto the attached EBS volume.
- [x] Ensure PostgreSQL binds only for private VPC use.
- [x] Ensure no public ingress path exists.

### Secrets and lifecycle

- [x] Reuse existing Postgres secret if present and not pending deletion.
- [x] Fail clearly if the secret is scheduled for deletion.
- [x] Preserve secret on `make destroy`.
- [x] Delete secret on `make cleanup`.

### Docs and examples

- [x] Update README quickstart where database mode is selected.
- [x] Update operations and architecture docs.
- [x] Update tfvars examples for both modes.
- [x] Add a short operator note explaining when to choose `ec2_postgres`.

### Validation

- [x] Run `make validate`.
- [x] Run plan for `database_mode = "rds"`.
- [x] Run plan for `database_mode = "ec2_postgres"`.
- [x] Record results in this markdown file.

## Progress Log

- 2026-05-12 00:00 UTC — Completed creation of the live implementation plan file with locked decisions, checklist, and verification sections. This will be updated throughout the change. Current blocker state: none.
- 2026-05-12 20:10 UTC — Completed the Terraform interface changes. Added `database_mode` plus `postgres_ec2_*` root inputs, moved the Postgres password generation to the root module, and threaded the selected mode into the frontend path. Current blocker state: none.
- 2026-05-12 20:10 UTC — Completed the database split and EC2 fallback implementation. RDS resources are now conditional, a new `postgres_ec2` module provisions a private SSM-managed PostgreSQL host with encrypted storage, and the frontend secret contract stays mode-independent. Current blocker state: none.
- 2026-05-12 20:10 UTC — Completed docs and examples updates. README, architecture and operations notes, AWS CLI workflow, tfvars examples, and the tfvars generator now explain the `rds` versus `ec2_postgres` decision. Current blocker state: none.
- 2026-05-12 20:10 UTC — Blocked by a plan-time failure in `modules/litellm_frontend/scripts/lookup-secret.sh`. The external data helper used a heredoc Python wrapper, which consumed stdin before Terraform's JSON query reached the script. Current blocker state: resolved by switching the helper to `python3 -c` with direct `sys.stdin` parsing.
- 2026-05-12 20:10 UTC — Verified live plans for both database modes using temporary AWS-backed tfvars. The `rds` plan included `aws_db_instance` and `aws_db_subnet_group` with no `postgres_ec2` resources; the `ec2_postgres` plan included the new EC2 database resources with no RDS resources. Current blocker state: none.

## Verification Log

- Pass — `terraform -chdir=terraform fmt -recursive`
  Result: Terraform formatting completed successfully after the database-mode changes.
- Pass — `bash -n scripts/destroy-preserve-secrets.sh && bash -n scripts/generate-existing-vpc-tfvars.sh && bash -n terraform/modules/litellm_frontend/scripts/lookup-secret.sh`
  Result: syntax checks passed for the new destroy wrapper, tfvars generator updates, and secret lookup helper.
- Pass — `make validate`
  Result: `terraform validate` and `packer validate` both succeeded in the current repo state.
- Pass — final `make validate`
  Result: reran validation after the secret lookup helper fix and the final docs/example sync; `terraform validate` and `packer validate` both still succeeded.
- Fail — `terraform -chdir=terraform plan -no-color -input=false -var-file=/tmp/aws-llm-rds-H20hAO.tfvars`
  Result: failed in `data.external.existing_postgres_secret` because `lookup-secret.sh` consumed stdin before parsing Terraform's JSON query.
  Follow-up: rewrote the helper to use `python3 -c` and read from `sys.stdin` directly.
- Fail — parallel rerun of the RDS and EC2 plans
  Result: one plan hit a stale local state lock and the other used a malformed temporary tfvars file with `database_mode` defined twice.
  Follow-up: rebuilt the temporary tfvars files cleanly and reran the plans sequentially with `-lock=false`.
- Pass — `terraform -chdir=terraform plan -lock=false -no-color -input=false -var-file=/tmp/aws-llm-rds-JioVxf.tfvars > /tmp/aws-llm-plan-rds.txt`
  Result: plan succeeded. Summary line: `Plan: 80 to add, 0 to change, 0 to destroy.` The plan included `module.litellm_frontend.aws_db_instance.this[0]` and `module.litellm_frontend.aws_db_subnet_group.this[0]`.
- Pass — `terraform -chdir=terraform plan -lock=false -no-color -input=false -var-file=/tmp/aws-llm-ec2-Tp62pn.tfvars > /tmp/aws-llm-plan-ec2.txt`
  Result: plan succeeded. Summary line: `Plan: 82 to add, 0 to change, 0 to destroy.` The plan included `module.postgres_ec2[0].aws_instance.this` and no RDS resources.
- Pass — mode-specific plan assertions
  Commands:
  - `rg 'module\\.postgres_ec2|aws_instance\\.this' /tmp/aws-llm-plan-rds.txt`
  - `rg 'aws_db_instance|aws_db_subnet_group' /tmp/aws-llm-plan-ec2.txt`
  Result: `rds` mode showed no EC2 database resources and `ec2_postgres` mode showed no RDS database resources.

## Open Issues

- `make destroy` and `scripts/cleanup-deployment.sh` were not executed against a live deployment during this implementation pass, so the preserve-versus-delete Postgres secret behavior remains code-verified but not runtime-exercised.
- The `postgres_ec2` cloud-init/bootstrap path has been validated by Terraform plan only; the EC2-hosted PostgreSQL install, data-volume migration, and first-boot SQL initialization have not yet been exercised in a real apply.
- Backup automation remains intentionally deferred for v1. The design assumes EBS-snapshot-based backups rather than automated logical backup orchestration.

## Final Outcome

- Implemented `database_mode = "rds" | "ec2_postgres"` with `rds` as the default.
- Added a new `postgres_ec2` Terraform module for the private fallback database path and refactored the frontend module so both modes publish the same Secrets Manager contract to LiteLLM.
- Updated root variables, module wiring, tfvars examples, the tfvars generator, README, operations notes, the AWS CLI workflow, and architecture documentation to explain the two database modes.
- Verified:
  - `make validate` passes
  - `terraform plan` succeeds for both `rds` and `ec2_postgres`
  - `rds` mode plans only RDS database resources
  - `ec2_postgres` mode plans only EC2-hosted PostgreSQL resources
- Remaining known limitations:
  - destroy/cleanup secret behavior was not exercised against a live stack in this pass
  - the EC2 Postgres bootstrap path is plan-validated but not apply-validated yet
