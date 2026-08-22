# Isolated test launch

The checked-in [`deployments/test.json`](../../deployments/test.json) is the
non-secret contract for the temporary full-stack environment. It fixes the
region, release, DNS namespace, Matrix identity, Continuwuity digest, feature
set, state key, and September 5 review date. Only synthetic data and invited
test accounts are permitted.

## Bootstrap boundary

The test state bucket is separate from production. Bootstrap it once with a
short-lived assumed operator role, save the plan, review it locally, and apply
only that file:

```bash
export LUCIDITY_ENVIRONMENT=test
nix run .#state -- plan -input=false -var environment=test -out=test-state.tfplan
nix run .#state -- show test-state.tfplan
nix run .#state -- apply test-state.tfplan -input=false
```

Copy the resulting bucket name into the protected `test` GitHub environment as
`AWS_TEST_STATE_BUCKET_NAME`. The first foundation plan must also receive the
existing GitHub OIDC provider ARN, both shared ECR repository coordinates, and
the shared AMI snapshot KMS ARN. These are references only. A test plan that
tries to manage shared release resources, the account security baseline, the
account budget, or a production-tagged resource is invalid.

Review and apply the first `foundation` plan locally with the same short-lived
operator role. This creates the test plan, apply, and validation OIDC roles.
Record their output ARNs as `AWS_TEST_INFRA_PLAN_ROLE_ARN`,
`AWS_TEST_INFRA_APPLY_ROLE_ARN`, and
`AWS_TEST_DEPLOYMENT_VALIDATION_ROLE_ARN` in the protected `test` environment.
Subsequent stages run through `.github/workflows/infra.yml`.

## Saved-plan stages

- `foundation` creates the test network, KMS keys, empty secret containers,
  OpenBao resources, node roles, backup resources, and GitHub roles.
- `compute` adds exactly one controller and one worker from the two AMIs in the
  checksum-verified v0.4.0 release manifest.
- `edge` adds only test DNS, public web ingress, and backups after private
  bootstrap passes.
- `quarantine` removes public DNS and HTTP/HTTPS ingress while preserving the
  instances, SSM, and test state for diagnosis.

The workflow uploads the exact binary plan, its SHA-256 checksum, the verified
release manifest, derived non-secret variables, and a redacted action summary.
The protected apply job downloads and applies that same plan. The Cloudflare
token exists only as a secret of the selected GitHub environment.

## Secret and private bootstrap

OpenTofu creates empty encrypted secret containers and never creates secret
versions. Generate synthetic values through SecretSpec. AWS-hosted runtime
values are represented on the nodes only by Secrets Manager dynamic references
and resolved by `asm-exec` at process start. Do not read AWS secret values with
the AWS CLI, place values in OpenTofu variables, or paste them into SSM
commands.

OpenBao starts with only its TLS loopback listener. Use an SSM port-forward to
initialize it without exposing port 8200:

```bash
aws ssm start-session --target CONTROLLER_INSTANCE_ID \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8200"],"localPortNumber":["8200"]}' \
  --region us-east-2
```

Run `lucidity mesh init` on the controller through the tunnel. It creates the
encrypted CA key only in tmpfs and stores it through OpenBao. Run
`lucidity mesh request` separately on each host so each private key stays on
that host. Export only each `.pub` file for `lucidity mesh sign`, return the
signed certificate and public CA, and install them on the originating host.
After Nebula is active on the controller, run
`/usr/libexec/lucidity/enable-openbao-overlay`. Then run
`/usr/libexec/lucidity/register-openbao-aws-auth WORKER_ROLE_ARN` with a
short-lived OpenBao operator token. The helper checksum-registers the packaged
AWS auth plugin and binds `lucidity-worker` to that exact immutable IAM role.

Before edge, prove that the worker can read only
`secret/lucidity/test/worker-ooye` and is denied on an unrelated path.

## Matrix bootstrap

Store the one-time registration token and synthetic administrator password at
`secret/lucidity/test/matrix-bootstrap`. Resolve them from the
`test-matrix-bootstrap` SecretSpec profile as private files with a short-lived,
path-scoped operator token. Do not use the worker IAM-auth token: that token
must remain restricted to `secret/lucidity/test/worker-ooye`. Place the scoped
operator token in tmpfs as a mode `0600` file and pass only its path through
`BAO_TOKEN_PATH` when invoking
`/usr/libexec/lucidity/register-matrix-bootstrap-admin USERNAME` on the worker.
The helper temporarily enables token-gated registration, registers through the
Matrix client API, restarts Continuwuity with registration disabled, and deletes
the bootstrap metadata from OpenBao. Never use Continuwuity's server-side
`--execute users create-user` command because its generated password is written
to container logs.

The approved image is
`docker.io/jadedblueeyes/continuwuity@sha256:55397612f3e78150f8bfce2413c6912b3046e05cd30c895644fd5df4eb4f96db`
for Linux AMD64. The digest was resolved from the project's documented Docker
Hub mirror for v26.7.3.

## Acceptance and evidence

Do not expose test DNS until deployment validation confirms the exact AMIs and
bootc digests, encrypted roots, IMDSv2, SSM, Nebula-only SSH, closed raw service
ports, and OpenBao denial behavior. After edge, test Matrix login and
federation, OOYE message/edit/reaction/attachment flows, Prometheus targets,
Grafana logs, Alloy drops, an ntfy firing/resolved alert, a Restic backup/check,
and a staged synthetic restore. Reboot the worker and repeat the login, static
site, and bridge smoke tests.

Record only release identity, plan checksum, validation results, and UTC test
timestamps in issue 52. Keep the issue open. Review the environment on
September 5; extension or teardown requires another reviewed saved plan.
