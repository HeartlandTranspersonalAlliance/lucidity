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

For v0.2.1, PR #66 is the one-time release gate. A successful merge of that PR
into `main` starts the release workflow automatically with exact target
`0.2.1` and the merge commit as the immutable source. The manual dispatch
interface remains available only for an intentional release-tool recovery.

The `.#release` app requires an exact canonical `X.Y.Z` target. It must match
`VERSION` and the dated changelog section at the selected source commit, be
newer than the latest reachable release tag, and not conflict with an existing
tag or published release. This permits deliberate clean jumps such as v0.1.0
directly to v0.2.1 without synthesizing an unwanted v0.2.0 release.

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
Raw multi-gigabyte disks never cross runner boundaries.

An existing immutable candidate is never overwritten. The local rebuild still
occurs so BuildKit can reuse cached layers for disk construction; the workflow
pulls and pins the verified remote digest before producing the AMI. The final
manifest ties both role images, SBOMs, AMIs, and the source commit together.

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
