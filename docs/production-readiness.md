# Production readiness roadmap

Lucidity is designed as a controlled singleton: one controller and one worker.
High availability is intentionally deferred. Production approval therefore
depends on tested recovery, strict change control, and observable failure
rather than automatic failover.

## Release gate

Version 0.2.1 is the first production-candidate release. Before publishing it:

1. Merge the complete `nix flake check` graph through the merge queue.
2. Publish the immutable controller and worker images, SBOMs, checksums, and
   retained AMIs from the release workflow.
3. Confirm the GitHub repository deletes merged branches automatically.
4. Confirm the `production` environment prevents self-review and requires one
   independent ITSM reviewer.

## Infrastructure gate

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

## Recovery gate

- Seven AWS Backup daily recovery points exist for both node ARNs.
- Restic uses an independent AWS S3, Backblaze B2, Garage, or experimental
  RustFS destination.
- A complete restore drill meets the 24-hour RPO and 8-hour RTO.
- The second restic recovery key is held offline by a different operator.
- A simulated backup failure reaches the confirmed notification channel.

## Deferred work

After singleton production is stable, prioritize automated release-identity
attestation in deployment validation, application-level capacity metrics,
scheduled restore testing, and then an explicit high-availability design. HA
must not be represented as complete until Coolify state, OpenBao quorum,
workload storage, routing, and failure-domain behavior are all tested together.
