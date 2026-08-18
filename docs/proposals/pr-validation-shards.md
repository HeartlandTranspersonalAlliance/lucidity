# Proposal: digest-pinned PR validation shards

Status: proposed

Depends on: the same-runner immutable image work in PR #46

## Decision

When pull-request validation has at least two compatible profiles that repeat the
same expensive work, group those profiles into a small, fixed set of flake-owned
shards. Pure profiles are exact flake check attributes built together with
`nix build --keep-going`. Mutable container or VM profiles run sequentially as
fresh Nix-wrapped child processes after their shared image is verified and
loaded once.

This is a future optimization, not a reason to weaken the authoritative
`nix flake check` graph or the isolated release path.

## Current state

Pull requests currently have two principal validation paths:

- `validate.yml` evaluates and builds the complete hermetic flake check graph.
- `integration.yml` builds the tooling, controller, and worker images and then
  validates their disks and paired guest behavior on one runner.

The path-scoped AMI workflow provides local compatibility coverage for changes
to disk construction. Trusted lifecycle and release workflows remain outside
the pull-request shard design.

This already avoids some duplicate work. Sharding becomes worthwhile as new
configuration profiles are added and independent jobs would otherwise repeat
the same base-image or role-image transfer.

## Goals

- Reduce repeated upstream image pulls and decompression on fresh PR runners.
- Preserve immutable digest verification for every external image.
- Keep controller and worker cache scopes independent.
- Bound runner disk usage by removing completed profile images, disks, and
  diagnostics after their results are recorded.
- Return useful results for all profiles in a shard, rather than stopping at the
  first failure.
- Keep GitHub Actions as a thin scheduler around flake-owned commands.
- Measure network, disk, cache, and duration improvements without making timing
  a flaky correctness requirement.

## Non-goals

- Replacing or subdividing `nix flake check` as the authoritative graph.
- Combining release controller and worker validation on one runner.
- Uploading raw disks or image archives between runners.
- Granting AWS credentials or cache-write credentials to pull requests.
- Dynamically executing shell fragments supplied by a PR-authored shard plan.
- Pruning shared BuildKit state while later profiles still need it.

## Activation gate

Do not introduce the shard scheduler until measurements show all of the
following:

1. At least two profiles with the same verified base or role image run on
   separate PR runners.
2. Their repeated transfer or expansion is material in either runner minutes,
   network bytes, or peak disk use.
3. Combining them fits comfortably within the runner timeout and disk budget.
4. A shard failure would not hide an independently required security gate.

Until this gate is met, keep the current consolidated integration job.

## Proposed model

### Flake-owned registry

Define an allow-listed profile registry in Nix. Each profile declares data, not
shell code:

- stable profile identifier;
- required role images and digest-pinned base image;
- profile kind: pure flake attribute or mutable wrapped runner;
- exact flake check attribute for pure profiles;
- allow-listed runner identifier for mutable profiles;
- compatible container engine and privilege mode;
- expected disk artifacts and cleanup targets;
- source ownership used for conservative change selection;
- diagnostic paths and timeout class.

Expose the evaluated registry as a deterministic JSON package and provide one
Nix-wrapped validator:

```console
nix run .#pr-validation-plan
nix run .#pr-validation -- SHARD_ID
```

The planner returns only known shard, profile, flake-attribute, and runner
identifiers. The validator checks the complete contract before invoking Nix or
touching container storage. Unknown paths, registry changes, base-image changes,
and planner failures select all profiles. Documentation-only changes may skip
the heavy shards, but never skip the hermetic flake graph.

### Shard keys

Profiles may share a shard only when all expensive and security-relevant inputs
match:

- base image repository and digest;
- architecture;
- Docker or Podman engine;
- rootless or privileged execution mode;
- role-image set;
- credential and trust boundary.

Use at most three PR shards initially. A likely topology after the activation
gate is met is:

| Shard | Retained images | Candidate profiles |
| --- | --- | --- |
| Controller | verified base and controller | image lint, controller disk, controller guest |
| Worker | verified base and worker | image lint, worker disk, worker guest |
| Paired | verified controller and worker | Nebula mesh and Coolify integration |

This topology is illustrative. The measured dependency graph, not profile
names, determines the final grouping. If the paired shard would duplicate more
work than it saves, keep paired validation in the existing integration job.

### Execution lifecycle

For each shard, the flake-owned validator will:

1. Validate the JSON schema, version, identifier uniqueness, exact attribute
   syntax, and allow-listed mutable runners before any execution.
2. Build all pure attributes in one `nix build --no-link --keep-going` child so
   Nix can schedule them and share store dependencies. If the batch fails, rerun
   each attribute only to attribute failures; already realized outputs remain
   store hits.
3. Resolve every external tag needed by mutable profiles to its approved digest
   and reject architecture, digest, or configured attestation mismatches.
4. Pull the digest-pinned base or role image once and retain its local reference.
5. Restore the applicable read-only GHCR cache scope.
6. Execute each mutable profile as a fresh Nix-wrapped child process with an
   explicit environment.
7. Validate each derived image's role label, architecture, and `bootc` lint
   result independently.
8. Capture the profile status and bounded diagnostics even when validation
   fails.
9. Run the profile's allow-listed cleanup wrapper, then continue with the next
   profile. Remove only its image tags, raw or qcow2 disks, guests, archives,
   and temporary diagnostics.
10. Retain shared image layers and the verified base until the last profile.
11. Emit a machine-readable result plus a human-readable job summary, then fail
    the shard if any profile failed.

Avoid broad `docker system prune` or BuildKit pruning between profiles. Removing
named derived images and artifacts is sufficient; shared layers remain
reference-counted for later profiles. Perform final cache logout and builder
cleanup under `if: always()`.

### GitHub workflow

Use one lightweight planning job followed by a fixed matrix of selected shard
identifiers. Set `fail-fast: false` so one failed shard does not cancel the
others. A final required job must reject any failed, canceled, or unexpectedly
skipped selected shard.

Pull requests remain read-only for Cachix and GHCR. The workflow must not expose
OIDC-based AWS roles, `CACHIX_AUTH_TOKEN`, or mutable registry operations. The
release workflow continues using one isolated runner per role and is not a
consumer of the PR shard scheduler.

## Security and immutability invariants

- External images are selected by digest; tags are diagnostic metadata only.
- A locally cached image is inspected again before each profile consumes it.
- Controller, worker, and tooling outputs keep distinct cache scopes.
- Profile definitions cannot contain evaluated shell snippets, arbitrary flake
  installables, or arbitrary GitHub expressions.
- Pure profiles are restricted to exact `checks.<system>.<name>` attributes and
  use the immutable Nix store for dependency sharing.
- Mutable profiles dispatch only to runners embedded by the Nix package.
- Pull-request code receives no secret values and no cache-write authority.
- Raw disks, secrets, mutable runtime state, and guest diagnostics are not cache
  inputs.
- Cleanup never deletes an artifact outside the shard's named workspace and
  container resources.
- Release, retained AMI, and production deployment trust boundaries remain
  separate.

## Failure and cancellation behavior

The shard command records an exit status for every selected profile and exits
nonzero only after cleanup and summary generation. A failed pure batch is
diagnosed with fresh per-attribute Nix processes. Each mutable profile and its
cleanup run in fresh child processes, and later profiles still run after a
failure. Profile failure diagnostics must be size-bounded and uploaded only on
failure. GitHub cancellation still terminates the job promptly; an `always()`
cleanup step removes guests, local tags, registry authentication, and the named
BuildKit builder.

If a runner is lost, only that shard reruns. No shard depends on a raw disk or
mutable image exported by another runner.

## Measurement

Add diagnostic summaries before changing required checks:

- number and compressed bytes of upstream pulls;
- time spent pulling, building, booting, and cleaning each profile;
- peak filesystem and container-storage use;
- GHCR and Cachix hit state;
- total runner minutes and time to first failure.

Compare the same commit before and after sharding on fresh runners. Timing and
cache-hit percentages remain observability signals, not pass/fail assertions.

## Implementation phases

1. Instrument the current jobs and establish at least ten representative PR-run
   baselines.
2. Add the typed Nix profile registry, pure JSON plan package, Nix-wrapped hybrid
   validator, and unit tests without changing required jobs.
3. Run one candidate shard in non-required shadow mode and compare results with
   the existing validators.
4. Enable two or three fixed shards with the required aggregate job after result
   parity is demonstrated.
5. Remove superseded duplicate jobs and tune grouping only after another ten PR
   runs.

Each phase is independently reversible.

## Acceptance criteria

- Unit tests prove deterministic ordering, strict contract validation,
  conservative all-profile fallback, and rejection of unknown profile,
  attribute, and runner identifiers before mutable storage is touched.
- Pure-profile tests prove one successful batch build and per-attribute
  diagnosis only after a batch failure.
- Mutable-profile tests prove fresh child execution, failure continuation, and
  cleanup after both successful and failed profiles.
- Mock-container tests prove one base pull per shard and named per-profile
  cleanup without pruning retained shared layers.
- Every existing validation failure fixture produces the same failing required
  status before and after migration.
- A base-image digest change selects every dependent profile.
- A controller-only change does not select unrelated worker-only profiles, while
  shared image, tooling, and policy changes select both.
- Documentation-only changes preserve relevant Nix store paths and do not start
  heavy shards.
- Pull-request jobs have no AWS role assumption or cache-writing credential.
- A canceled or failed profile cannot produce a successful aggregate result.
- Fresh-runner measurements demonstrate a material reduction in repeated pulls
  or runner minutes before duplicate jobs are removed.

## Rollback

Keep the existing workflow entry points until shadow-mode parity and measurement
gates pass. Rollback consists of making the current independent jobs required
again and disabling the shard matrix. Because shards exchange no mutable
artifacts, rollback requires no cache, registry, or infrastructure migration.
