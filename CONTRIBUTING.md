# Contributing

Thanks for contributing to this repository.

## Before You Open a PR

1. Read the setup flow in [README.md](README.md).
2. Use the scripts in [docs/aws-cli-workflow.md](docs/aws-cli-workflow.md) if you need to inspect AWS inputs.
3. Keep changes aligned with [AGENTS.md](AGENTS.md).

## Local Checks

Run these before opening a pull request:

```bash
make fmt
make validate
```

If you touch Packer inputs or backend image logic, also run:

```bash
make packer-init
packer validate -var-file=packer/backend.example.pkrvars.hcl packer/backend-ami.pkr.hcl
```

## Documentation Expectations

- Update `README.md` when the operator flow changes.
- Update the owning doc in `docs/` when a runbook changes.
- Prefer linking to deep runbooks instead of duplicating long procedures in multiple places.

## Infrastructure Safety

- Do not change cleanup behavior to remove pre-existing VPCs, subnets, route tables, or hosted zones by default.
- Keep backend instances private-only unless a change explicitly requires otherwise.
- Keep secrets out of plaintext files and use AWS Secrets Manager or SSM Parameter Store.

## Pull Request Notes

When relevant, include:

- what changed
- why the change was needed
- validation you ran
- any operator-visible documentation updates
