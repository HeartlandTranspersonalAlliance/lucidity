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

## Immutable artifacts

The release workflow promotes tested controller and worker image digests without
rebuilding them. It verifies role inventories, generates compressed SPDX SBOMs
and checksums, validates retained encrypted AMIs, and assembles one release
manifest tying every artifact to the source commit.

GitHub publication occurs only after the two-role inventory and asset set match.
Release automation uses short-lived GitHub OIDC credentials for AWS operations.

## Version policy

- Patch: backward-compatible fixes.
- Minor: backward-compatible operator, image, infrastructure, or workflow
  capabilities.
- Major: incompatible changes to supported interfaces or deployment contracts.

The repository policy check verifies that `VERSION` is valid SemVer and that the
same version has a dated changelog section.
