# AWS OpenTofu bootstrap

The flake-generated `state.config` creates the protected S3 backend required before
production infrastructure is applied. The flake-generated `awsConfig` composes the
Terraform-compatible modules in `tofu/modules` to publish and deploy Lucidity bootc
images:

- a production VPC spanning three Availability Zones by default;
- public and isolated private subnets, with AZ-local NAT Gateways available but disabled by default;
- an Internet Gateway, AZ-local route tables, and VPC DNS support;
- web, controller, application, and database security groups with no public management ingress;
- rejected-traffic VPC Flow Logs delivered to a 30-day CloudWatch Logs group;
- one empty controller-runtime Secrets Manager secret encrypted by a rotating customer-managed KMS key;
- SSM-enabled controller and worker instance profiles, with the controller optionally restricted to that secret;
- immutable controller and worker ECR version tags, one controlled mutable `stable` channel, scan-on-push, and untagged-image cleanup that preserves releases;
- a rotating AMI snapshot KMS key and EBS Direct API permissions for disposable validation and retained releases;
- hardened, versioned EC2 launch templates gated on explicit self-owned controller and worker AMI IDs;
- explicitly gated controller and worker EC2 instances with stable Elastic IPs and API termination protection;
- explicitly gated Cloudflare A records that proxy the controller and worker Elastic IPs;
- explicitly gated daily, crash-consistent AWS Backup recovery points with governance-mode Vault Lock and dedicated backup and restore roles;
- explicitly gated status-check, CPU, and T3a credit alarms delivered through encrypted SNS email;
- an explicitly gated, monitoring-only account-wide annual AWS cost budget with email alerts;
- an explicitly gated account-security baseline with default EBS encryption, public-snapshot blocking, multi-region CloudTrail, AWS Config, GuardDuty, Inspector, Security Hub V2, and a seven-year audit bucket;
- an account-level GitHub Actions OIDC provider, unless an existing provider ARN is supplied;
- a repository-scoped IAM role that only trusts `main` for the immutable owner and repository IDs of `HeartlandTranspersonalAlliance/lucidity`;
- least-privilege permissions to authenticate to ECR and push to these two repositories.

It does not create EC2 instances, AMIs, state storage, or secret values by default. The
GitHub workflow creates retained AMIs only after an explicit manual release dispatch.
Networking, instance management, runtime secrets, launch templates, production
instances, and their backup plan remain explicitly gated in that order.

Cloudflare DNS is gated after the EC2 instances. It manages only the configured
production hostnames and leaves the zone apex, mail, verification, and other existing
records unchanged.

The account cost budget is independent of EC2 deployment and can be enabled during
the foundation apply. It monitors the complete AWS account so unexpected untagged
resources are not hidden. The default 1,100 USD annual limit sends email when actual
spend exceeds 80 percent, forecasted spend exceeds 100 percent, or actual spend
exceeds 100 percent. Credits and refunds do not reduce the monitored amount. It has no
Budget Action and cannot stop resources or change IAM policy.

The initial compute contract is AMD64 with `t3a.small` for the controller and
`t3a.medium` for the worker. ARM64 remains configurable but deferred.

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
private workload. Elastic IPs are created only when `enable_ec2_instances=true`, so
disabled deployment resources do not accrue public IPv4 charges.

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

The controller launch template attaches `controller_instance_profile_name`.
Its SSM-enabled role can describe and read only this secret and decrypt only its
dedicated rotating KMS key through Secrets Manager. The
worker uses `worker_instance_profile_name` and receives no secret permission. Each role can obtain
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
seven required JSON keys. The controller launch template's cloud-init data writes that
root-only file with the seven reference strings before `cloud-final.service` completes;
it contains no resolved value. The worker template has no user data. Never put resolved
values in user data.

The secret, customer-managed KMS key, and enabled security services incur regional
charges. Review current Secrets Manager, KMS, CloudTrail, Config, GuardDuty,
Inspector, Security Hub, and S3 pricing before apply.

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
| `AWS_AMI_AUDIT_ROLE_ARN` | `github_ami_audit_role_arn` |
| `AWS_AMI_SNAPSHOT_KMS_KEY_ARN` | `ami_snapshot_kms_key_arn` |
| `AWS_AMI_TEST_SUBNET_ID` | `ami_test_subnet_id` |
| `AWS_AMI_TEST_CONTROLLER_SECURITY_GROUP_ID` | `ami_test_security_group_ids["controller"]` |
| `AWS_AMI_TEST_WORKER_SECURITY_GROUP_ID` | `ami_test_security_group_ids["worker"]` |
| `AWS_AMI_TEST_CONTROLLER_INSTANCE_PROFILE_NAME` | `ami_test_instance_profile_names["controller"]` |
| `AWS_AMI_TEST_WORKER_INSTANCE_PROFILE_NAME` | `ami_test_instance_profile_names["worker"]` |

The audit role is separately least-privileged to the three EC2 describe operations
used by `.github/workflows/audit-ami-resources.yml`. The daily workflow reports tagged
disposable validation resources older than 12 hours for operator review.

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

### Disposable bootc switch and rollback validation

`Validate bootc switch and rollback delivery` is an opt-in EC2 lifecycle gate for
proving retained AMI delivery from a reusable bootc bootstrap AMI. It builds a management-enabled CentOS
Stream 10 bootc image from a digest-pinned upstream base, converts and registers that
base through the same encrypted EBS Direct path, and launches it as a keyless
`t3a.small`. Before the update, it records the booted source image and writes a marker
into a Docker volume. SSM then configures instance-role ECR authentication, runs
`bootc switch` to the current main commit's immutable AlmaLinux worker image, reboots,
and validates the target plus the marker. It next runs `bootc rollback`, reboots to the
recorded source image, and validates the marker and enforcing SELinux again. The job
reports each stage separately and always terminates the instance, deregisters the
disposable AMI, and deletes its snapshot.

The gate deliberately uses private ECR rather than GHCR so the AMI strategy is
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
to those exact IDs, enable networking, instance management, and runtime secrets, then set
`enable_ec2_launch_templates=true`. OpenTofu verifies both AMIs are self-owned,
available AMD64 UEFI HVM EBS images with ENA and IMDSv2 support.

The templates use the proposal defaults: `t3a.small` with 40 GiB gp3 for the
controller and `t3a.medium` with 80 GiB gp3 for the worker. Root volumes are encrypted
with the AMI snapshot KMS key and retained if an instance is terminated. CPU credits
are standard, EC2 detailed monitoring remains disabled,
IMDSv2 is required with container-compatible hop limit 2, and no key pair, subnet,
or public address is embedded. The controller user data contains only the root-only
Secrets Manager reference file; the worker has none. Consumers must pin the numeric
template version from `ec2_launch_template_latest_versions`; changing a template does
not roll running instances automatically.

The controller bootstrap is implemented and image-validated, the release workflow
creates and boot-validates its retained AMI, and the launch template provisions only
runtime references. After the foundation apply creates the empty secret, initialize
all seven JSON values without exposing them to the repository, shell history, or disk:

```console
nix run .#lucidity -- secrets initialize-controller-runtime
```

The command generates the bundle in tmpfs, uploads it by file, shreds the temporary
file, and refuses to replace an existing `AWSCURRENT` version unless an intentional
coordinated rotation is explicitly requested.

## Production EC2 deployment

After retaining and validating both role AMIs, populate the controller runtime secret
out of band and set the following together in the reviewed production tfvars:

```hcl
enable_network              = true
enable_account_cost_budget  = true
account_annual_cost_limit_usd = 1100
account_cost_budget_notification_email = "operations@example.org"
enable_runtime_secrets      = true
enable_instance_management  = true
enable_ec2_launch_templates = true
enable_ec2_instances        = true
cloudflare_zone_id          = "4616a45d9d8f6dd9a0ff5b5e739bdf6d"
enable_cloudflare_dns       = true
enable_node_backups          = true

controller_ami_id = "ami-CONTROLLER"
worker_ami_id     = "ami-WORKER"
```

OpenTofu launches `coolify-controller` and `coolify-worker-01` from numeric launch
template versions, suppresses auto-assigned public addresses, and associates one
stable Elastic IP with each primary network interface. Both nodes use the first
selected public subnet by default, which avoids cross-AZ controller-to-worker SSH
charges. Change `ec2_node_availability_zone_indices` only after deciding that spreading
these non-redundant nodes across zones provides enough isolation to justify cross-AZ
traffic. There is no key pair or public TCP/22 ingress.

With `enable_cloudflare_dns=true`, OpenTofu also creates proxied A records for
`coolify.heartlandta.org` on the controller address and `apps.heartlandta.org`,
`*.apps.heartlandta.org`, and `matrix.heartlandta.org` on the worker address. The
Cloudflare provider reads `CLOUDFLARE_API_TOKEN` from the process environment. Keep
that token in the GitHub Actions secret of the same name or another runtime secret
store; do not add it to HCL, tfvars, command arguments, or OpenTofu state. The zone ID
is a non-secret identifier and may be configured as a GitHub variable.

Review the complete plan before apply. Direct EC2 API termination protection defaults
to enabled, but OpenTofu can still propose replacement when an immutable instance
argument changes. Root volumes are retained on termination, and the optional AWS
Backup plan creates daily crash-consistent EC2 recovery points with 7-day retention.
Do not approve replacement until a current `COMPLETED` recovery point is verified. A
launch-template update alone does not affect a running instance until its pinned
numeric version is deliberately changed in this deployment.

The flake-built `production.auto.tfvars.json` makes networking, AMI validation,
instance identities, runtime-secret metadata, OpenBao KMS, and the account security
baseline authoritative defaults for every `nix run .#infra -- plan`. It deliberately
does not enable nodes, DNS, backups, or the budget until their AMI IDs,
notification addresses, and service-specific inputs are supplied and reviewed.

AWS Backup stores only incremental changed blocks after the first EBS snapshot. The
plan uses one backup-only service role and a separate restore role; only the latter
can pass the two exact node runtime roles back to EC2. Governance-mode Vault Lock
enforces retention between 7 and 365 days without making the configuration permanently
immutable. Cross-Region copies and cold storage remain off to avoid cost and long
restore times until a stronger failure model requires them. Follow
[`docs/node-recovery.md`](../docs/node-recovery.md) for verification and drills.

Node and application monitoring is part of the locked bootc images rather than AWS
infrastructure. Prometheus and Loki run on the controller, Alloy forwards bounded
logs from both roles over Nebula, Grafana and Alertmanager remain controller-local,
and ntfy is published through the existing Coolify proxy. The deployment creates no
CloudWatch alarms, AWS Synthetics canaries, or monitoring SNS topic.
See [`docs/node-monitoring.md`](../docs/node-monitoring.md) for provisioning and access.

After apply, use `ec2_instance_ids` for Session Manager, `ec2_private_ips.worker` when
registering the worker with Coolify, and `ec2_public_ips` for external DNS. Public IPv4
addresses incur hourly AWS charges even when their instances are stopped; disable the
deployment or release addresses only as part of an intentional teardown.

Configure the non-secret repository variable
`AWS_DEPLOYMENT_VALIDATION_ROLE_ARN` from
`github_deployment_validation_role_arn`, then dispatch **Validate production
deployment** from `main`. The dedicated OIDC role can discover EC2 and EBS metadata,
inspect SSM health, and run only `AWS-RunShellScript` on instances tagged for this
project, environment, and the controller or worker role. The workflow:

1. requires exactly one running AMD64 controller and worker with IMDSv2-only metadata
   and attached encrypted root volumes;
2. waits for both SSM agents and validates cloud-init, Docker, SSH, bootc,
   Determinate Nix persistence and a locked flake build, SELinux, and the
   unattended-update timer;
3. validates the controller storage mount, bootstrap units, complete running Compose
   service set, persistent key material, and relevant SELinux audit state;
4. enrolls only the controller public key on the worker through its idempotent service;
5. obtains the worker public SSH host key through SSM and uses it to prove the
   controller-to-worker private SSH path with strict host-key checking; and
6. probes the optional controller and worker application HTTPS URLs from the hosted
   runner when supplied at dispatch.

Keep `enroll_worker` enabled on the first run and after an intentional controller SSH
identity rotation. Subsequent validation runs may disable enrollment to verify the
existing worker state. A passing run completes the live Milestone 10 infrastructure
and private-management checks; supply Cloudflare-backed HTTPS URLs to include the
public application path.

## ECR candidate publication

Configure these non-secret repository variables from the applied OpenTofu outputs:

| GitHub variable | OpenTofu output |
|---|---|
| `AWS_ECR_PUBLISH_ROLE_ARN` | `github_publish_role_arn` |
| `AWS_ECR_CONTROLLER_REPOSITORY_URL` | `ecr_repository_urls["controller"]` |
| `AWS_ECR_WORKER_REPOSITORY_URL` | `ecr_repository_urls["worker"]` |
| `AWS_DEPLOYMENT_VALIDATION_ROLE_ARN` | `github_deployment_validation_role_arn` |

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

```console
nix flake check --show-trace --print-build-logs
```

The command checks all HCL formatting, initializes providers without a backend,
validates both roots, and runs their mocked OpenTofu tests. It does not contact AWS.

## Bootstrap protected remote state

The state bootstrap creates two deletion-resistant S3 buckets in AWS's
account-regional namespace: one for versioned OpenTofu state and native lock objects,
and one for the state bucket's server access logs. Both use S3-managed encryption,
block SSE-C, require TLS through bucket policy, enable ABAC, and retain version history.
The audit bucket is the lower-cost logging choice: it uses S3 storage instead of
CloudWatch ingestion and expires logs after 365 days by default. It is intentionally
not configured to log its own access, which avoids recursive logging.

Apply this small bootstrap with local state first. The flake app selects both the
generated root and pinned OpenTofu binary:

```console
nix run .#state -- plan -out=bootstrap.tfplan
nix run .#state -- show bootstrap.tfplan
nix run .#state -- apply .lucidity/tofu/state/bootstrap.tfplan
nix run .#state -- output
```

The bucket names include the account ID and region and use the account-regional
namespace. Copy the backend example to the ignored `.lucidity` location, replace the
placeholder account ID with the `state_bucket_name` output, and migrate the bootstrap
state into the bucket it created:

```console
cp tofu/examples/backend.state.s3.tfbackend.example .lucidity/backend.state.s3.tfbackend
nix run .#state -- migrate .lucidity/backend.state.s3.tfbackend
```

Keep the bootstrap's local state until migration succeeds, verify the remote object and
one recoverable version exist, then store or remove the local copy according to the
operator's secure-state procedure. Do not commit it. The output
`backend_access_policy_json` is a least-privilege policy document for authorized
operator roles; attach it through the account's identity-management process rather
than creating long-lived access keys.

Next copy the reviewed state backend identifiers for the main stack before its first
production apply:

```console
cp .lucidity/backend.state.s3.tfbackend .lucidity/backend.aws.s3.tfbackend
# Change the key from bootstrap.tfstate to terraform.tfstate.
nix run .#infra -- plan
```

Both backend files enable OpenTofu's native S3 conditional-write lock with
`use_lockfile=true`; no DynamoDB table is required. State and lock tags drive separate
lifecycle rules. Noncurrent state keeps at least 100 newer versions for at least one
year, while stale lock versions expire sooner.

## Bootstrap the AWS resources

The first apply must use an operator identity that can create VPC, EC2 networking,
CloudWatch Logs, Secrets Manager, KMS, ECR, and IAM resources and, if needed, the account-level GitHub OIDC
provider. The publishing role cannot create itself.

```console
nix run .#infra -- plan -out=foundation.tfplan
nix run .#infra -- show foundation.tfplan
nix run .#infra -- apply .lucidity/tofu/aws/foundation.tfplan
```

The flake-owned production defaults create the image pipeline plus the security,
network, instance-management, OpenBao KMS, and empty runtime-secret foundations:

- ECR repositories and GitHub publishing identity;
- the EBS Direct snapshot encryption key;
- the GitHub AMI validation role.

It deliberately leaves launch templates, production nodes, DNS, backups, and the
budget disabled, so image-bundled monitoring is not yet active. After the disposable AWS import succeeds, initialize the
runtime secret with `nix run .#lucidity -- secrets initialize-controller-runtime`,
select the exact retained AMI IDs in a reviewed operator variable file, then enable
launch templates and instances. Keep `enable_nat_gateways` false for the selected
direct-public design.

If `token.actions.githubusercontent.com` is already configured in the account, set `github_oidc_provider_arn` to its ARN. IAM permits only one provider for that URL in an account.

The production stack requires the protected partial S3 backend. Backend configuration
contains identifiers only; credentials come from the operator's short-lived AWS
session. Never put credentials in HCL, tfvars, or backend configuration.

After apply, use `github_publish_role_arn` and the ECR URL outputs to configure the image publishing workflow. No long-lived AWS access keys belong in GitHub Secrets.
