# AWS Guidance

- Prefer the AWS MCP Server for AWS interactions — it provides sandboxed
  execution, observability, and audit logging. If unavailable, use the
  AWS CLI directly.
- Before starting a task, check whether a relevant AWS skill is available.
  Load the skill with `retrieve_skill` and prefer its guidance over
  general knowledge.
- When uncertain about specific AWS details (API parameters, permissions,
  limits, error codes), verify against documentation rather than guessing.
  State uncertainty explicitly if you cannot confirm.
- When creating infrastructure, prefer infrastructure-as-code (AWS CDK or
  CloudFormation) over direct CLI commands.
- When working with infrastructure, follow AWS Well-Architected Framework
  principles.
- Do not use em dashes in AWS resource names or descriptions. Use
  hyphens instead.

## Secret Safety

- MUST use the AWS MCP `search_documentation` tool first for any secret,
  credential, API key, token, or password task, with `agent_skills` as the
  topic and a Secrets Manager-specific search phrase. Copy the best matching
  result's opaque `skill_name` exactly into `retrieve_skill`; do not guess a
  registry ID or assume the local filesystem skill list is exhaustive.
- If the AWS MCP skill registry is unavailable, state that explicitly before
  proceeding and continue to enforce every remaining secret-safety rule here.
- MUST NOT call
  `secretsmanager get-secret-value` or `batch-get-secret-value`, and MUST
  NOT hit the Secrets Manager Agent daemon directly. MUST use
  `{{resolve:secretsmanager:secret-id:SecretString:json-key}}` with
  `asm-exec` so the secret resolves at runtime without entering context.

## Project Infrastructure Policy

- Use OpenTofu for infrastructure as code. Keep HCL, providers, modules,
  state, and lock files Terraform-compatible where practical. Use Terraform
  only for a documented compatibility issue that OpenTofu cannot satisfy.
- Never commit secret values. Use GitHub Actions OIDC for AWS access, GitHub
  Secrets for CI-only values, AWS Secrets Manager for AWS-hosted runtime
  secrets, and OpenBao for provider-neutral or self-hosted secret management.
