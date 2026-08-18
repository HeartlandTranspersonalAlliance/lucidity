# Changelog

All notable changes to Lucidity are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Documentation is now organized by concepts, guides, security, operations,
  and reference material.

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
