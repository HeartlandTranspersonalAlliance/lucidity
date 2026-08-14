# AWS OpenTofu bootstrap

This stack creates the AWS resources needed to publish lucidity bootc OCI images:

- immutable controller and worker ECR repositories with scan-on-push and bounded retention;
- an account-level GitHub Actions OIDC provider, unless an existing provider ARN is supplied;
- a repository-scoped IAM role that only trusts `main` in `HeartlandTranspersonalAlliance/lucidity`;
- least-privilege permissions to authenticate to ECR and push to these two repositories.

It does not create EC2 instances, networking, AMIs, state storage, or runtime secrets. Those remain separate milestones.

## Validate without AWS credentials

From the repository root:

```bash
nix develop --command make tofu-check
```

The command checks all HCL formatting, initializes providers without a backend, validates the configuration, and runs mocked OpenTofu tests. It does not contact AWS.

## Bootstrap the AWS resources

The first apply must use an operator identity that can create ECR repositories, the IAM role and policy, and, if needed, the account-level GitHub OIDC provider. The publishing role cannot create itself.

```bash
cp tofu/environments/aws/terraform.tfvars.example tofu/environments/aws/terraform.tfvars
tofu -chdir=tofu/environments/aws init
tofu -chdir=tofu/environments/aws plan
tofu -chdir=tofu/environments/aws apply
```

If `token.actions.githubusercontent.com` is already configured in the account, set `github_oidc_provider_arn` to its ARN. IAM permits only one provider for that URL in an account.

The initial local state is intentionally supported for bootstrap, but it is sensitive operational data and must not be committed. Before this stack is shared or automated, migrate it to a protected remote backend with encryption, state locking, access logging, and least-privilege access.

After apply, use `github_publish_role_arn` and the ECR URL outputs to configure the image publishing workflow. No long-lived AWS access keys belong in GitHub Secrets.
