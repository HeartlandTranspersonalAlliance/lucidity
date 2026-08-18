# Release process

Lucidity uses Semantic Versioning. `VERSION` stores the unprefixed version, while
Git tags and image release identifiers use `vMAJOR.MINOR.PATCH`.

## Prepare a release

1. Update `VERSION`.
2. Move user-visible entries from `Unreleased` into the dated version section in
   `CHANGELOG.md`.
3. Run the full flake check and merge through the queue.
4. Start the release workflow from `main` with the intended bump.

The `.#release` app selects the version from conventional commits unless an
explicit bump is provided. It refuses releases outside `main`, non-SemVer input,
conflicting tags, and non-resumable existing releases.

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

- Patch: backward-compatible fixes.
- Minor: backward-compatible operator, image, infrastructure, or workflow
  capabilities.
- Major: incompatible changes to supported interfaces or deployment contracts.

The repository policy check verifies that `VERSION` is valid SemVer and that the
same version has a dated changelog section.
