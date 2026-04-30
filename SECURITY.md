# Security Policy

## Supported Use

This repository is intended for operators deploying an internal/shared LLM platform on AWS. Treat all generated infrastructure as production-capable and review settings before exposing it to real users.

## Reporting a Vulnerability

If you discover a security issue in this repository or its deployment guidance:

1. Do not open a public GitHub issue with exploit details.
2. Report it privately to the repository maintainers through your normal secure channel.
3. Include:
   - affected files or scripts
   - deployment impact
   - reproduction steps
   - suggested mitigation if known

## Sensitive Areas

Give extra review attention to:

- IAM policies and trust relationships
- Secrets Manager and SSM usage
- public ALB exposure and admin UI restrictions
- cleanup and destroy paths
- SSH enablement
- backend instance bootstrap and container runtime settings
