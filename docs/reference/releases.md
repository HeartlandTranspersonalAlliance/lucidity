# Release process

Lucidity uses Semantic Versioning. `VERSION` stores the unprefixed version, while
Git tags and image release identifiers use `vMAJOR.MINOR.PATCH`.

## Prepare a release

1. Update `VERSION`.
2. Move user-visible entries from `Unreleased` into the dated version section in
   `CHANGELOG.md`.
3. Run the full flake check and merge through the queue.
4. Start the release workflow from `main` with the exact unprefixed target
   version.

Releases are dispatched from `main` with the exact target version. GitHub OIDC
therefore presents the repository's trusted `main`-branch subject to AWS. Pass
the validated merge commit as `source_sha` when resuming after a release-tool
hotfix so artifacts remain bound to the original source.

The `.#release` app requires an exact canonical `X.Y.Z` target. It must match
`VERSION` and the dated changelog section at the selected source commit, be
newer than the latest reachable release tag, and not conflict with an existing
tag or published release. This permits the deliberate clean jump from v0.1.0
directly to v0.3.0 without publishing superseded intermediate releases.

If a release-tool-only failure occurs after immutable image promotion, rerun the
workflow from the corrected `main` with the original full source SHA. Resume is
accepted only when that commit is an ancestor of the dispatched commit, its
version documentation is still consistent, and every intervening path is in the
fixed release-tool and release-documentation allowlist. The tooling commit runs
the workflow while images, AMIs, manifest metadata, tag, and release target stay
bound to the original source commit.

## Immutable artifacts

For each role, one ephemeral runner builds the candidate, verifies its immutable
ECR digest, generates the compressed SPDX SBOM and checksum, and constructs the
raw disk from that same digest-pinned local image. The runner then assumes the
narrow AMI-validation role to create and boot-test the encrypted retained AMI.
Raw multi-gigabyte disks never cross runner boundaries. The installed bootc
origin and the AMI launch gate use the same digest-pinned ECR reference recorded
as `SourceImageDigest`; the version tag is promoted separately and resolves to
that digest. On the guest, bootc private-ECR access uses the Nix-pinned ECR
credential helper with the EC2 instance profile. The only bootc auth file is an
ephemeral empty JSON object required to activate helper lookup; no registry
password or token is stored in the image.

The first-boot gate treats Nix profile activation and ECR-helper preparation as
readiness conditions. It retries while those one-shot services complete, then
checks the helper through the stable Lucidity profile path before asking bootc
to query the private registry. After EC2 reaches `running`, SSM connectivity is
the guest-readiness signal; the gate records EC2 system and instance status as
diagnostic evidence without blocking guest validation on the coarse EC2 status
waiter.

An existing immutable candidate is never overwritten. The local rebuild still
occurs so BuildKit can reuse cached layers for disk construction; the workflow
pulls and pins the verified remote digest before producing the AMI. The final
manifest ties both role images, SBOMs, AMIs, and the source commit together.

SPDX documents use a stable namespace and normalized creation timestamp, and
their gzip assets omit the original filename and timestamp. Retrying a release
therefore reproduces the same SBOM bytes for the same immutable image. For AMIs
created before that normalization, a resume may refresh the `SbomSha256` tag on
the already validated AMI and snapshot only after the release version, source
revision, and source-image digest match. Those identity fields remain immutable
and any conflict stops the release.

GitHub publication occurs only after the two-role inventory and asset set match.
Release automation uses short-lived GitHub OIDC credentials for AWS operations.

## Version policy

- Before v1.0.0, minor releases may make intentional clean breaks when the
  changelog and migration guidance make them explicit.
- After v1.0.0, patch releases contain backward-compatible fixes, minor releases
  add backward-compatible capabilities, and major releases may break supported
  interfaces or deployment contracts.

The repository policy check verifies that `VERSION` is valid SemVer and that the
same version has a dated changelog section.
