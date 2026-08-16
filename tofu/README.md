# AWS OpenTofu bootstrap

This stack creates the AWS resources needed to publish lucidity bootc OCI images:

- a production VPC spanning three Availability Zones by default;
- public and isolated private subnets, with AZ-local NAT Gateways available but disabled by default;
- an Internet Gateway, AZ-local route tables, and VPC DNS support;
- web, controller, application, and database security groups with no public management ingress;
- VPC Flow Logs delivered to a 90-day CloudWatch Logs group;
- one empty controller-runtime Secrets Manager secret encrypted by a dedicated rotating KMS key;
- SSM-enabled controller and worker instance profiles, with the controller optionally restricted to that secret and KMS key;
- immutable controller and worker ECR version tags, one controlled mutable `stable` channel, scan-on-push, and untagged-image cleanup that preserves releases;
- a rotating AMI snapshot KMS key and EBS Direct API permissions for disposable validation and retained releases;
- hardened, versioned EC2 launch templates gated on explicit self-owned controller and worker AMI IDs;
- an account-level GitHub Actions OIDC provider, unless an existing provider ARN is supplied;
- a repository-scoped IAM role that only trusts `main` for the immutable owner and repository IDs of `HeartlandTranspersonalAlliance/lucidity`;
- least-privilege permissions to authenticate to ECR and push to these two repositories.

It does not create EC2 instances, AMIs, state storage, or secret values. The GitHub
workflow creates retained AMIs only after an explicit manual release dispatch. Networking,
instance management, runtime secrets, and launch templates remain independently gated.

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
The lifecycle policy expires only untagged manifests. Tagged releases are intentionally
not count-limited because deleting an old `vX.Y.Z` image would break the release manifest
and rollback chain.

## Runtime secret boundary

OpenTofu creates the `lucidity/production/controller-runtime` secret container but
deliberately creates no `aws_secretsmanager_secret_version`. Populate its JSON value
through an out-of-band operator workflow after apply. Never put that value in HCL,
tfvars, user data, an AMI, CI logs, or OpenTofu state.

The future controller launch template must attach `controller_instance_profile_name`.
Its SSM-enabled role can describe and read only this secret and can decrypt only
through Secrets Manager in the configured region. The worker uses
`worker_instance_profile_name` and receives no secret permission. Each role can obtain
an ECR authorization token and pull layers only from its matching private bootc
repository; this supports the ephemeral bootc ECR credential helper without granting
cross-role repository access. Runtime secret consumers must use the output pattern:

```text
{{resolve:secretsmanager:lucidity/production/controller-runtime:SecretString:json-key}}
```

Resolve that reference with the approved `asm-exec` flow on the instance. This
repository now builds the AWS Workload Credentials Provider from checksum-pinned source,
installs a checksum-pinned AWS `asm-exec`, and includes an idempotent controller bootstrap
unit. The bootstrap accepts only dynamic references in
`/etc/coolify-controller/runtime-secrets.env`; see the adjacent `.example` file for the
seven required JSON keys. Wiring that reference-only file into the future EC2 instance
provisioning remains an explicit blocker. Do not put resolved values in user data.

At the pricing reviewed during implementation, one secret plus one customer-managed
KMS key costs about USD 1.40 per month before negligible API request charges. AWS KMS
currently adds monthly charges after the first two automatic rotations, which can
raise that baseline to about USD 2.40 and USD 3.40. Check the current
[Secrets Manager pricing](https://aws.amazon.com/secrets-manager/pricing/) and
[KMS pricing](https://aws.amazon.com/kms/pricing/) before apply.

## AMI compatibility validation

OpenTofu creates a customer-managed KMS key for AMI snapshots and a GitHub OIDC role
trusted only for this repository's `main` branch. The workflow writes raw disk blocks
directly to EBS and has no S3 staging or VM Import path.

The trust subjects include GitHub's immutable numeric owner and repository IDs. This
prevents a renamed or recycled repository name from inheriting AWS access. Confirm
`github_repository_owner_id` and `github_repository_id` with the GitHub API after a
repository transfer before applying any trust-policy update.

Pull requests run `.github/workflows/ami.yml` without AWS credentials to build and
validate the raw AMD64 artifact. After applying the foundation from reviewed `main`,
configure these non-secret GitHub repository variables from the OpenTofu outputs:

| GitHub variable | OpenTofu output |
|---|---|
| `AWS_AMI_IMPORT_ROLE_ARN` | `github_ami_validation_role_arn` |
| `AWS_AMI_SNAPSHOT_KMS_KEY_ARN` | `ami_snapshot_kms_key_arn` |
| `AWS_AMI_TEST_SUBNET_ID` | `ami_test_subnet_id` |
| `AWS_AMI_TEST_CONTROLLER_SECURITY_GROUP_ID` | `ami_test_security_group_ids["controller"]` |
| `AWS_AMI_TEST_WORKER_SECURITY_GROUP_ID` | `ami_test_security_group_ids["worker"]` |
| `AWS_AMI_TEST_CONTROLLER_INSTANCE_PROFILE_NAME` | `ami_test_instance_profile_names["controller"]` |
| `AWS_AMI_TEST_WORKER_INSTANCE_PROFILE_NAME` | `ami_test_instance_profile_names["worker"]` |

Then manually run **Validate AMI compatibility** with `run_aws_validation` enabled.
The workflow resolves pinned `coldsnap 0.10.0` from `flake.lock` and
uploads the raw artifact directly to an encrypted EBS snapshot with 64 concurrent
workers. It registers a disposable AMD64, UEFI, HVM, ENA-enabled, IMDSv2-only AMI,
validates the returned metadata and configured KMS key, then removes the AMI and EBS
snapshot. Merged-main run `31899706447` proved the optimized path on 2026-08-15: the
12 GiB raw disk upload completed in about 33 seconds, the AMI was ready to launch about
48 seconds after upload began, and the entire upload, registration, T3a/SSM guest gate,
and cleanup step took 4 minutes 54 seconds. The earlier VM Import phase alone took
about 14 minutes.

For an ad hoc production candidate, select its `ami_role`, choose
`ami_lifecycle=retained`, and enable both AWS validation and the launch gate. Normal
semantic releases should use **Release bootc appliance**, which supplies the immutable
version, role-specific OCI digests, and SPDX SBOM hashes to parallel retained AMI gates
and publishes both AMI and snapshot IDs in the immutable schema-v2 GitHub release
manifest.
First ensure **Publish bootc images** has published the current `main` controller and
worker candidates as `sha-<full-commit>`. The AMI workflow pulls the selected role's immutable private ECR reference and
uses it as the disk's bootc source, so the installed host tracks a real production
registry rather than the disposable `localhost` reference. It names and tags the AMI
with the same commit SHA, launches a disposable T3a guest through SSM, and marks the
release validated only after every guest assertion passes. On failure it deregisters
the candidate and deletes its snapshot. On success it terminates the test instance but
retains the encrypted snapshot and AMI, and prints the exact AMI ID for explicit
OpenTofu selection. Rerunning the same commit reuses the already validated immutable
release instead of creating a duplicate. Registration proves AWS accepts the disk and
AMI metadata, while the separate disposable T3a gate proves boot and guest behavior.
For the controller role, the SSM gate waits for storage preparation and the controller
bootstrap marker before the retained image can be marked validated.

### Disposable bootc switch benchmark

`Benchmark bootc switch delivery` is an opt-in experiment for comparing retained AMI
delivery with a reusable bootc bootstrap AMI. It builds a management-enabled CentOS
Stream 10 bootc image from a digest-pinned upstream base, converts and registers that
base through the same encrypted EBS Direct path, and launches it as a keyless
`t3a.small`. SSM then configures instance-role ECR authentication, runs `bootc switch`
to the current main commit's immutable AlmaLinux worker image, schedules a reboot, and
repeats the production guest assertions after the new deployment boots. The job reports
switch/pull and reboot/validation durations separately and always terminates the
instance, deregisters the benchmark AMI, and deletes its snapshot.

The experiment deliberately uses private ECR rather than GHCR so the AMI strategy is
the only changed variable and no static registry credential is introduced. The
upstream image-builder `--aws-*` uploader is not used: its documented AMI path requires
an S3 bucket and the VM Import service role. Only dispatch this workflow from `main`
after `Publish bootc images` has published the selected `sha-<full-commit>` worker tag.
By default it selects the workflow revision; the optional `worker_revision` input can
select an earlier, already-published immutable revision for workflow-only retries.
The benchmark base contains SSM Agent and the ECR credential helper because a stock
CentOS bootc base does not provide the repository's keyless management contract.

To repeat that boot gate, temporarily set `enable_network`,
`enable_instance_management`, and `enable_ami_launch_validation` to `true`, keep
`enable_nat_gateways` and `enable_runtime_secrets` false, apply the reviewed plan,
and configure the role-specific `AWS_AMI_TEST_*` variables above. Manually dispatch the
workflow with both `run_aws_validation` and `run_aws_launch` enabled. The workflow launches one
`t3a.small` in standard CPU-credit mode with no key pair, IMDSv2 required, and the
application security group. SSM Run Command verifies AMD64, SELinux enforcing,
bootc, Docker, SSM Agent, and rejection of tokenless metadata access. Cleanup
terminates the instance before deregistering the AMI and deleting its encrypted
snapshot. Keep `enable_ami_launch_validation` disabled outside an intentional gate
run.

### GitHub-hosted runner boundary

The delivery pipeline remains on GitHub-hosted runners. CodeBuild runners are
intentionally excluded. EBS Direct removes the slow legacy import phase without adding a
second runner control plane, GitHub connection, build project, or custom runner image.
Any future speed work should first tune the pinned uploader's bounded concurrency and
measure build, upload, snapshot completion, and boot-gate durations independently.

## Explicit launch-template AMI selection

Launch templates are disabled by default and never discover the newest AMI. After both
roles have retained, boot-validated AMIs, set `controller_ami_id` and `worker_ami_id`
to those exact IDs, enable networking and instance management, then set
`enable_ec2_launch_templates=true`. OpenTofu verifies both AMIs are self-owned,
available AMD64 UEFI HVM EBS images with ENA and IMDSv2 support.

The templates use the proposal defaults: `t3a.small` with 40 GiB gp3 for the
controller and `t3a.large` with 80 GiB gp3 for the worker. Root volumes are encrypted
with the AMI snapshot KMS key, CPU credits are standard, detailed monitoring is on,
IMDSv2 is required with container-compatible hop limit 2, and no key pair, subnet,
public address, or user data is embedded. Consumers must pin the numeric template
version from `ec2_launch_template_latest_versions`; changing a template does not roll
running instances automatically.

The controller bootstrap is implemented and image-validated, and the release workflow
now creates and boot-validates its retained AMI. Reference-only EC2 provisioning is not
complete. Do not
enable these templates or launch production EC2 instances yet. Defining this boundary
now makes AMI selection reviewable without pretending the deployment milestone is
complete.

## ECR candidate publication

Configure these non-secret repository variables from the applied OpenTofu outputs:

| GitHub variable | OpenTofu output |
|---|---|
| `AWS_ECR_PUBLISH_ROLE_ARN` | `github_publish_role_arn` |
| `AWS_ECR_CONTROLLER_REPOSITORY_URL` | `ecr_repository_urls["controller"]` |
| `AWS_ECR_WORKER_REPOSITORY_URL` | `ecr_repository_urls["worker"]` |

`.github/workflows/publish.yml` runs only on `main`, assumes the branch-restricted
publishing role through GitHub OIDC, and publishes validated AMD64 controller and
worker images as immutable `sha-<full-commit>` candidates. It does not consume stored
AWS keys and does not move `stable`; promotion remains a separate post-boot-validation
operation.

The pinned OSBuild native AWS uploader was also evaluated as a lower-maintenance
replacement. It cannot currently assert encrypted import or AMI IMDSv2 support,
or match the cleanup contract, so the explicit workflow remains intentional. See
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
- the EBS Direct snapshot encryption key;
- the GitHub AMI validation role.

It deliberately leaves `enable_network`, `enable_instance_management`, and
`enable_runtime_secrets` false. After the disposable AWS import succeeds and EC2
deployment is ready, set all three to true and apply again. Keep
`enable_nat_gateways` false for the selected direct-public design.

If `token.actions.githubusercontent.com` is already configured in the account, set `github_oidc_provider_arn` to its ARN. IAM permits only one provider for that URL in an account.

The initial local state is intentionally supported for bootstrap, but it is sensitive operational data and must not be committed. Before this stack is shared or automated, migrate it to a protected remote backend with encryption, state locking, access logging, and least-privilege access.

After apply, use `github_publish_role_arn` and the ECR URL outputs to configure the image publishing workflow. No long-lived AWS access keys belong in GitHub Secrets.
