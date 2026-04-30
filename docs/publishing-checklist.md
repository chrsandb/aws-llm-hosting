# Publishing Checklist

Use this checklist before making the repository public on GitHub.

## Repository Content

- Remove or replace any local absolute filesystem links.
- Confirm example IDs, domains, and ARNs are clearly placeholders.
- Confirm no real secrets, AMI IDs, snapshot IDs, account IDs, or private DNS names are committed.
- Review `.github/workflows/` for any org-specific secrets or assumptions.

## Repository Metadata

- Add a license before publishing.
- Review [README.md](../README.md) as the public landing page.
- Review [CONTRIBUTING.md](../CONTRIBUTING.md) and [SECURITY.md](../SECURITY.md).
- Set the repository description and topics in GitHub.

## Technical Validation

- Run `make fmt`
- Run `make validate`
- Validate the helper scripts you changed
- Re-read [docs/aws-cli-workflow.md](aws-cli-workflow.md) and [docs/operations.md](operations.md) for operator clarity

## Public-Facing Review

- Make sure the README is understandable without internal context.
- Confirm all relative links render correctly on GitHub.
- Confirm cleanup behavior is clearly documented as safe-by-default.
- Confirm the public API contract is clearly stated as `/v1/*`.

## Optional Nice-to-Haves

- Add issue templates
- Add pull request templates
- Add a code owners file
- Add release tags and changelog practices
