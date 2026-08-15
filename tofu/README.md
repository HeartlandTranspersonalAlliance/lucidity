# AWS OpenTofu bootstrap

This stack creates the AWS resources needed to publish lucidity bootc OCI images:

- a production VPC spanning three Availability Zones by default;
- public and isolated private subnets, with AZ-local NAT Gateways available but disabled by default;
- an Internet Gateway, AZ-local route tables, and VPC DNS support;
- web, controller, application, and database security groups with no public management ingress;
- VPC Flow Logs delivered to a 90-day CloudWatch Logs group;
- one empty controller-runtime Secrets Manager secret encrypted by a dedicated rotating KMS key;
- SSM-enabled controller and worker instance profiles, with the controller optionally restricted to that secret and KMS key;
- immutable controller and worker ECR version tags, one controlled mutable `stable` channel, scan-on-push, and bounded retention;
- a private, auto-expiring S3 bucket and project-scoped IAM roles for disposable GitHub AMI import validation;
- an account-level GitHub Actions OIDC provider, unless an existing provider ARN is supplied;
- a repository-scoped IAM role that only trusts `main` for the immutable owner and repository IDs of `HeartlandTranspersonalAlliance/lucidity`;
- least-privilege permissions to authenticate to ECR and push to these two repositories.

It does not create EC2 instances, AMIs, state storage, or secret values. Networking,
instance management, and the runtime secret module are implemented but disabled during
the initial image-pipeline bootstrap.

The initial compute contract is AMD64 with `t3a.small` for the controller and
`t3a.large` for the worker. These values are outputs for the future launch-template
milestone and do not create instances yet. ARM64 remains configurable but deferred.

The default `allowed_web_cidrs` value is `0.0.0.0/0` because application HTTP and
HTTPS must be reachable from the internet. There is no administrator SSH security
group and no ingress rule for port 8000. External shell and bootstrap access use
Systems Manager Session Manager over outbound HTTPS. Coolify's controller-to-worker
SSH remains restricted to the private VPC security-group relationship.

The controller can initiate outbound TCP 443. The worker can initiate outbound TCP
443 and 8448; 8448 is retained for Matrix federation with remote servers that do not
delegate federation to 443. The web and database security groups add no egress, and
security groups are stateful, so response traffic for accepted connections does not
need a separate outbound rule.

The initial controller and worker will use public subnets and stable Elastic IPs, so
`enable_nat_gateways` defaults to `false`. The private subnets remain isolated. Enable
NAT only when accepting the fixed hourly and data-processing cost required by a future
private workload. Elastic IPs are created with the EC2 milestone rather than now so
unused addresses do not accrue charges.

## Controlled bootc channel

ECR rejects overwrites for version and commit tags. The exact `stable` tag is excluded
from immutability so a tested digest can be promoted without making every repository
tag mutable. Production hosts may follow `stable`; release records and rollback must
retain the immutable version tag and digest that `stable` referenced.

## Runtime secret boundary

OpenTofu creates the `lucidity/production/controller-runtime` secret container but
deliberately creates no `aws_secretsmanager_secret_version`. Populate its JSON value
through an out-of-band operator workflow after apply. Never put that value in HCL,
tfvars, user data, an AMI, CI logs, or OpenTofu state.

The future controller launch template must attach `controller_instance_profile_name`.
Its SSM-enabled role can describe and read only this secret and can decrypt only
through Secrets Manager in the configured region. The worker uses
`worker_instance_profile_name` and receives no secret permission. Runtime consumers
must use the output pattern:

```text
{{resolve:secretsmanager:lucidity/production/controller-runtime:SecretString:json-key}}
```

Resolve that reference with the approved `asm-exec` flow on the instance. This
repository does not yet contain an approved `asm-exec` package or bootstrap unit, so
runtime consumption remains an explicit blocker for the EC2 milestone.

At the pricing reviewed during implementation, one secret plus one customer-managed
KMS key costs about USD 1.40 per month before negligible API request charges. AWS KMS
currently adds monthly charges after the first two automatic rotations, which can
raise that baseline to about USD 2.40 and USD 3.40. Check the current
[Secrets Manager pricing](https://aws.amazon.com/secrets-manager/pricing/) and
[KMS pricing](https://aws.amazon.com/kms/pricing/) before apply.

## AMI compatibility validation

OpenTofu creates an empty private S3 import bucket, the project-scoped VM Import Export
service role, and a GitHub OIDC role trusted only for this repository's `main` branch.
Objects under `validation/` expire after one day if workflow cleanup fails.

The trust subjects include GitHub's immutable numeric owner and repository IDs. This
prevents a renamed or recycled repository name from inheriting AWS access. Confirm
`github_repository_owner_id` and `github_repository_id` with the GitHub API after a
repository transfer before applying any trust-policy update.

Pull requests run `.github/workflows/ami.yml` without AWS credentials to build and
validate the raw AMD64 artifact. After applying the foundation from reviewed `main`,
configure these non-secret GitHub repository variables from the OpenTofu outputs:

| GitHub variable | OpenTofu output |
|---|---|
| `AWS_AMI_IMPORT_BUCKET` | `ami_import_bucket_name` |
| `AWS_AMI_IMPORT_ROLE_ARN` | `github_ami_validation_role_arn` |
| `AWS_VMIMPORT_ROLE_NAME` | `vmimport_role_name` |
| `AWS_AMI_TEST_SUBNET_ID` | `ami_test_subnet_id` |
| `AWS_AMI_TEST_SECURITY_GROUP_ID` | `ami_test_security_group_id` |
| `AWS_AMI_TEST_INSTANCE_PROFILE_NAME` | `ami_test_instance_profile_name` |

Then manually run **Validate AMI compatibility** with `run_aws_import` enabled. The
workflow uploads the raw artifact and imports it as an encrypted EBS snapshot. It then
registers a disposable AMD64, UEFI, HVM, ENA-enabled, IMDSv2-only AMI, validates the
returned metadata, and removes the AMI, EBS snapshot, and S3 object. Snapshot import is
used because AWS VM Import/Export does not list AlmaLinux in its OS matrix and
`import-image` rejects the AlmaLinux 10 bootc disk during OS detection. A successful
registration proves AWS accepts the disk and AMI metadata; a later disposable T3a
launch must still prove boot and guest behavior.

GitHub Actions run `31859796836` on merged `main` completed this registration test
on 2026-08-14. AWS completed the snapshot import, the workflow validated the
temporary AMI, and an independent AWS MCP audit confirmed that no validation AMI,
snapshot, or S3 object remained. The next gate is a disposable `t3a` launch with
SSM-only management access and no inbound TCP/22.

For that boot gate, temporarily set `enable_network`,
`enable_instance_management`, and `enable_ami_launch_validation` to `true`, keep
`enable_nat_gateways` and `enable_runtime_secrets` false, apply the reviewed plan,
and configure the three `AWS_AMI_TEST_*` variables above. Manually dispatch the
workflow with both `run_aws_import` and `run_aws_launch` enabled. It launches one
`t3a.small` in standard CPU-credit mode with no key pair, IMDSv2 required, and the
application security group. SSM Run Command verifies AMD64, SELinux enforcing,
bootc, Docker, SSM Agent, and rejection of tokenless metadata access. Cleanup
terminates the instance before deregistering the AMI and deleting its encrypted
snapshot. Disable `enable_ami_launch_validation` after the gate passes.

The pinned OSBuild native AWS uploader was also evaluated as a lower-maintenance
replacement. It cannot currently assert encrypted import or AMI IMDSv2 support,
select this stack's VM Import role, or match the cleanup contract, so the explicit
workflow remains intentional. See
[`docs/upstream-aws-uploader-evaluation.md`](../docs/upstream-aws-uploader-evaluation.md).

## Shell and bootstrap access

Both bootc images include and enable SSM Agent. After a launch template attaches the
corresponding instance profile and the node reports `Online` in Systems Manager, open
an AWS CLI shell without any inbound management port:

```bash
aws ssm start-session --region us-east-2 --target i-INSTANCE_ID
```

For the temporary Coolify bootstrap UI, forward local port 8000 through the SSM data
channel instead of opening it in the security group:

```bash
aws ssm start-session \
  --region us-east-2 \
  --target i-CONTROLLER_INSTANCE_ID \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8000"],"localPortNumber":["8000"]}'
```

Then open `http://127.0.0.1:8000`. Direct Session Manager shells can be logged. SSH
and port-forwarded sessions are encrypted tunnels, but their payload is not available
to Session Manager logging. CloudTrail still records the session API calls.

## Validate without AWS credentials

From the repository root:

```bash
nix develop --command make tofu-check
```

The command checks all HCL formatting, initializes providers without a backend, validates the configuration, and runs mocked OpenTofu tests. It does not contact AWS.

## Bootstrap the AWS resources

The first apply must use an operator identity that can create VPC, EC2 networking,
CloudWatch Logs, Secrets Manager, KMS, ECR, and IAM resources and, if needed, the account-level GitHub OIDC
provider. The publishing role cannot create itself.

```bash
cp tofu/environments/aws/terraform.tfvars.example tofu/environments/aws/terraform.tfvars
tofu -chdir=tofu/environments/aws init
tofu -chdir=tofu/environments/aws plan
tofu -chdir=tofu/environments/aws apply
```

With the example variables, the initial apply creates only the low-idle-cost image
pipeline foundation:

- ECR repositories and GitHub publishing identity;
- the private AMI import bucket;
- VM Import Export and GitHub AMI validation roles.

It deliberately leaves `enable_network`, `enable_instance_management`, and
`enable_runtime_secrets` false. After the disposable AWS import succeeds and EC2
deployment is ready, set all three to true and apply again. Keep
`enable_nat_gateways` false for the selected direct-public design.

If `token.actions.githubusercontent.com` is already configured in the account, set `github_oidc_provider_arn` to its ARN. IAM permits only one provider for that URL in an account.

The initial local state is intentionally supported for bootstrap, but it is sensitive operational data and must not be committed. Before this stack is shared or automated, migrate it to a protected remote backend with encryption, state locking, access logging, and least-privilege access.

After apply, use `github_publish_role_arn` and the ECR URL outputs to configure the image publishing workflow. No long-lived AWS access keys belong in GitHub Secrets.
