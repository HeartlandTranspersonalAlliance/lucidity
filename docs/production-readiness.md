# Production readiness

Lucidity is designed as a controlled singleton: one controller and one worker.
High availability and an availability percentile objective are out of scope.
Production approval depends on tested recovery, strict change control, and
observable failure rather than automatic failover.

## Release gate

Version 0.3.0 established the release path. Treat the next image release as the
first workload-bearing production candidate. Before publishing it:

1. Merge the complete `nix flake check` graph through the merge queue.
2. Manually run **Validate locked flake** with the smallest lifecycle scope
   covering bootc, persistent-storage, native Nix, SELinux, or recovery changes.
   Use `both` only when role-specific persistence differs or for an explicit
   dual-role release qualification.
3. Publish the immutable controller and worker images, SBOMs, checksums, and
   retained AMIs from the release workflow.
4. Confirm the GitHub repository deletes merged branches automatically.
5. Confirm the `production` environment prevents self-review and requires one
   independent ITSM reviewer.

## Infrastructure gate

Capture a local, read-only AWS inventory before each staged plan:

```console
nix run .#lucidity -- infra audit --json --output .lucidity/production-readiness.json
```

The report reads configuration metadata only, records unavailable APIs instead
of guessing, and never calls a Secrets Manager value API. Keep generated reports
under `.lucidity/`; they contain account metadata and must not be committed.
Review remote-state drift as a saved plan, without applying it:

```console
nix run .#lucidity -- infra refresh-plan .lucidity/production-refresh.tfplan
nix run .#lucidity -- infra show .lucidity/production-refresh.tfplan
```

Pull requests create a redacted OpenTofu plan summary when the planning role
and state bucket variables are configured. Production apply is manual from
`main`. The workflow downloads the exact saved plan, verifies its SHA-256
record, and pauses at the protected `production` environment before assuming
the apply role. The apply job cannot silently re-plan.

Required repository variables are:

- `AWS_INFRA_PLAN_ROLE_ARN`
- `AWS_INFRA_APPLY_ROLE_ARN`
- `AWS_DEPLOYMENT_VALIDATION_ROLE_ARN` for the standalone acceptance workflow
- `AWS_STATE_BUCKET_NAME`
- `PRODUCTION_CONTROLLER_URL`
- `PRODUCTION_WORKER_URL`
- `PRODUCTION_CONTROLLER_AMI_ID`
- `PRODUCTION_WORKER_AMI_ID`
- `PRODUCTION_CONTROLLER_IMAGE_DIGEST`
- `PRODUCTION_WORKER_IMAGE_DIGEST`

The planning role should be read-only except for S3 state locking. The apply
role should be limited to the generated stack and available only to the
protected environment.

## Service acceptance gate

The deployment validator must prove:

- exactly one controller and one worker are running;
- encrypted root volumes, required IMDSv2, and Systems Manager are healthy;
- no attached security group permits TCP/22;
- controller-to-worker root SSH succeeds only at Nebula address `100.96.0.2`;
- Coolify's complete controller service set is running;
- both production HTTPS endpoints pass;
- the deployed AMI and bootc image digests match the approved release inventory
  recorded in protected repository variables.

It does not need to exercise `bootc switch` and rollback on every rebuild. A
direct boot of the changed role, exact image-ref verification, system health,
and role-specific smoke check are the ordinary pull-request gate. Keep lifecycle
switch and rollback for a manually dispatched pre-release qualification when
bootc, persistence, native Nix, SELinux, or recovery behavior changes.

## Observability gate

- Prometheus sees controller and worker node_exporter and Alloy targets, Loki,
  and both public HTTPS probes as up over a 72-hour soak.
- Grafana can query recent systemd and Docker logs from both roles without a
  Docker socket mounted into Alloy.
- Alertmanager sends a reversible firing and resolved alert through self-hosted
  ntfy, and the operator receives the daily heartbeat on another device.
- Loki retains seven days, Alloy reports zero dropped entries, and controller
  storage stays above 20 percent free during the soak.
- The AWS inventory reports self-hosted observability as declared. No
  CloudWatch alarm, AWS Synthetics canary, or monitoring SNS topic is required.

## Workload gate

- A static site, Continuwuity client login, and federation with one remote
  homeserver survive a worker reboot and unchanged Coolify redeploy.
- OOYE is pinned by the flake, runs as an unprivileged native systemd service,
  and bridges a message, edit, reaction, and small attachment both directions.
- OpenBao authenticates the worker by AWS IAM over Nebula TLS; SecretSpec
  materializes the OOYE registration without logging, committing, or placing a
  secret in the Nix store or OpenTofu state.
- Raw Matrix port 8008, OOYE port 6693, Loki, Alloy, and node_exporter are not
  publicly reachable.

## Recovery gate

- Seven AWS Backup daily recovery points exist for both node ARNs.
- Restic uses an independent AWS S3, Backblaze B2, Garage, or experimental
  RustFS destination.
- A complete restore drill meets the 24-hour RPO and 8-hour RTO.
- The second restic recovery key is held offline by a different operator.
- A simulated backup failure reaches the confirmed notification channel.
- An isolated restore recovers Continuwuity login and room state plus OOYE's
  registration and SQLite mapping state.

## Deferred work

After singleton production is stable, prioritize automated release-identity
attestation in deployment validation, application-level capacity metrics, and
scheduled restore testing. High availability and an externally hosted dead-man
receiver are not roadmap commitments.
