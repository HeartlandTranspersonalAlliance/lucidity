# Changelog

All notable changes to Lucidity are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Documentation is now organized by concepts, guides, security, operations,
  and reference material.
- Production infrastructure changes now use a reviewable saved OpenTofu plan,
  an integrity check, and an independently approved GitHub environment.
- Deployment acceptance verifies that VPC security groups expose no SSH and
  tests controller-to-worker access only through the Nebula address.

### Added

- Provider-neutral restic backups for AWS S3, Backblaze B2, Garage, and
  experimental RustFS destinations, with role-isolated repositories and safe
  staged restores.
- SecretSpec backup profiles that use loopback OpenBao on the controller and
  AWS Secrets Manager with exact IAM grants on the worker.
- Backup-failure notifications, explicit CloudWatch missing-data behavior, and
  a production-readiness gate with 24-hour RPO and 8-hour RTO targets.

### Security

- Restic passwords are materialized as private files, never passed through Nix
  derivations or committed configuration.
- AWS S3 access uses the EC2 instance role; other S3-compatible providers use
  role-scoped keys resolved only for the backup process.

## [0.2.0] - 2026-08-17

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

### Changed

- Nix flake apps are now the supported operator and CI interface. Superseded
  Make, standalone Containerfile, role-tree, and environment-root interfaces
  were removed.
- GitHub Actions use the public `lucidity` Cachix cache for Nix store results and
  independent GHCR BuildKit scopes for controller, worker, and CI tooling layers.
- Test inputs use feature-owned Nix file sets so unrelated documentation or role
  changes do not invalidate focused checks.
- KVM setup is owned by the pinned Determinate Nix action, and trusted workflows
  fail clearly when the Cachix write token is unavailable.

### Security

- Administrative SSH is private to the Nebula mesh, uses the `admin` account
  with passwordless sudo, and denies administrator root login.
- CI uses GitHub OIDC for AWS access. Secret values remain outside Nix
  evaluation, derivations, logs, and repository history.
- Pull requests can read public caches but cannot receive or use cache-writing
  credentials.
- Raw disks, retained AMIs, secrets, mutable runtime state, and large bootc
  contexts are excluded from direct Cachix upload.

### Fixed

- Lifecycle image validation no longer loses the role image tag through Bash
  dynamic scope.
- VM lifecycle cleanup captures its role explicitly, and privileged guest
  validation follows the supported `admin` plus sudo access path.

[Unreleased]: https://github.com/HeartlandTranspersonalAlliance/lucidity/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/HeartlandTranspersonalAlliance/lucidity/compare/v0.1.0...v0.2.0
