# Changelog

All notable changes to Lucidity are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-08-20

### Added

- A typed Den host graph for controller and worker composition.
- Nix-owned bootc contexts, host profiles, Home Manager activation, architecture
  output, and feature-scoped checks.
- Disposable controller, worker, integration, update/rollback, and Nebula mesh
  validation paths.
- Terranix-generated, Terraform-compatible OpenTofu roots for AWS resources and
  remote state.
- SecretSpec profiles, OpenBao integration, AWS KMS auto-unseal, and scoped
  runtime-secret initialization.
- Immutable release inventory, SPDX SBOMs, checksums, retained AMI validation,
  and GitHub release publication.
- Provider-neutral restic backups for AWS S3, Backblaze B2, Garage, and
  experimental RustFS destinations, with role-isolated repositories and safe
  staged restores.
- SecretSpec backup profiles that use loopback OpenBao on the controller and
  AWS Secrets Manager with exact IAM grants on the worker.
- Backup-failure notifications, explicit CloudWatch missing-data behavior, and
  a production-readiness gate with 24-hour RPO and 8-hour RTO targets.

### Changed

- Release image promotion, SBOM generation, and retained AMI construction now
  share one ephemeral runner per role. Verified local OCI layers are reused
  without transferring raw multi-gigabyte disks between jobs.
- Release job summaries report observed same-runner and raw AMI durations for
  non-flaky comparisons with the previous split-runner baseline.
- Nix flake apps are now the supported operator and CI interface. Superseded
  Make, standalone Containerfile, role-tree, and environment-root interfaces
  were removed.
- GitHub Actions use the public `lucidity` Cachix cache for Nix store results and
  independent GHCR BuildKit scopes for controller, worker, and CI tooling layers.
- Test inputs use feature-owned Nix file sets so unrelated documentation or role
  changes do not invalidate focused checks.
- KVM setup is owned by the pinned Determinate Nix action, and trusted workflows
  fail clearly when the Cachix write token is unavailable.
- Documentation is organized by concepts, guides, security, operations, and
  reference material.
- Production infrastructure changes use a reviewable saved OpenTofu plan, an
  integrity check, and an independently approved GitHub environment.
- Deployment acceptance verifies that VPC security groups expose no SSH and
  tests controller-to-worker access only through the Nebula address.
- Merge-group lifecycle selection now uses a validated per-target path graph.
  The versioned JSON plan records exact commit ancestry, matched paths, and
  ancestor propagation evidence for each lifecycle target.
- Automatic pull-request, merge-queue, and main validation now runs the locked
  hermetic graph without full bootc switch and rollback guests. Focused
  controller, worker, or dual-role lifecycle qualification remains available
  through an explicit manual workflow dispatch.
- Draft pull requests defer the controller-worker boot smoke until they are
  marked ready for review.
- Sparse bootc artifacts use a 16 GiB virtual filesystem so native Nix and both
  retained bootc deployments fit during release update and rollback validation.

### Security

- Administrative SSH is private to the Nebula mesh, uses the `admin` account
  with passwordless sudo, and denies administrator root login.
- CI uses GitHub OIDC for AWS access. Secret values remain outside Nix
  evaluation, derivations, logs, and repository history.
- Pull requests can read public caches but cannot receive or use cache-writing
  credentials.
- Raw disks, retained AMIs, secrets, mutable runtime state, and large bootc
  contexts are excluded from direct Cachix upload.
- Restic passwords are materialized as private files, never passed through Nix
  derivations or committed configuration.
- AWS S3 access uses the EC2 instance role; other S3-compatible providers use
  role-scoped keys resolved only for the backup process.

### Fixed

- Retained AMI validation compares the installed bootc origin with the promoted
  image's exact ECR digest, and release dispatch runs from the main-branch OIDC
  subject trusted by AWS.
- Private ECR bootc updates resolve short-lived credentials from the EC2
  instance profile through the Nix-pinned ECR credential helper, and AMI
  release validation preserves the selected controller or worker role.
- Connectivity-only controller lifecycle assertions no longer require the
  full-bootstrap environment, key, and service hash arguments.
- Interrupted releases can resume from an exact ancestor after a release-tool-only
  fix without changing the immutable source, image digests, AMI metadata, or tag.
- Infrastructure apply no longer invokes the unsupported SES pricing-plan API
  after a successful OpenTofu apply.
- Lifecycle image validation no longer loses the role image tag through Bash
  dynamic scope.
- VM lifecycle cleanup captures its role explicitly, and privileged guest
  validation follows the supported `admin` plus sudo access path.
- CI publication is serialized per source revision, non-ancestral merge-group
  comparisons fail safe, and isolated lifecycle runs avoid unused cache-token
  and cleanup work.

[Unreleased]: https://github.com/HeartlandTranspersonalAlliance/lucidity/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/HeartlandTranspersonalAlliance/lucidity/compare/v0.1.0...v0.3.0
