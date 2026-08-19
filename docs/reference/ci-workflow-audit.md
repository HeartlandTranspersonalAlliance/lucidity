# GitHub Actions audit for v0.2.1

This document is the responsibility map and pre-optimization baseline for issue
#50. Workflows remain thin runner adapters. Policy and executable behavior belong
to flake-owned programs, and the packaged `ci-hermetic-check` app evaluates the
authoritative `nix flake check` graph.

## Reproducing the run baseline

Run the audit from the locked development environment:

```console
nix develop -c nix run .#ci -- workflow audit \
  HeartlandTranspersonalAlliance/lucidity --limit 100 \
  --json ci-baseline.json --markdown ci-baseline.md
```

The command does not include a generation timestamp, sorts runs and aggregates,
and emits the same JSON and Markdown for the same GitHub response. It reads only
Actions metadata and never reads repository or runtime secret values.

The baseline below sampled 100 runs ending at run
[32216354157](https://github.com/HeartlandTranspersonalAlliance/lucidity/actions/runs/32216354157)
on 2026-08-19. GitHub reported zero queue seconds for almost all runs in this
window. The one material queue was a manually dispatched release that waited
3,223 seconds. Runtime values are workflow elapsed time, so parallel job runner
minutes are called out separately where they matter.

| Workflow and event | Samples | Success / failure / cancelled / skipped | Median runtime | p95 runtime |
| --- | ---: | --- | ---: | ---: |
| Audit disposable AMI resources, schedule | 1 | 0 / 0 / 0 / 1 | 1s | 1s |
| Plan and apply production infrastructure, pull request | 12 | 0 / 0 / 0 / 12 | 1s | 11s |
| Publish bootc images, push | 7 | 7 / 0 / 0 / 0 | 466s | 527s |
| Release bootc appliance, dispatch | 7 | 0 / 5 / 2 / 0 | 1,122s | 7,243s |
| Validate AMI compatibility, pull request | 9 | 7 / 1 / 1 / 0 | 643s | 800s |
| Validate local Coolify integration, pull request | 18 | 11 / 1 / 6 / 0 | 1,574s | 1,796s |
| Validate locked flake, merge group | 16 | 8 / 5 / 3 / 0 | 1,696s | 3,014s |
| Validate locked flake, pull request | 22 | 21 / 0 / 1 / 0 | 109s | 126s |
| Validate locked flake, main push | 8 | 8 / 0 / 0 / 0 | 1,689s | 1,797s |

A representative successful merge group is run
[32212513671](https://github.com/HeartlandTranspersonalAlliance/lucidity/actions/runs/32212513671).
Its hermetic job used 95 seconds, the worker lifecycle used 1,435 seconds, and
the controller lifecycle used 1,720 seconds. The two lifecycle jobs therefore
consumed about 52.6 runner minutes even though they ran in parallel. The same
full lifecycle is repeated after the merge on `main`. Removing that duplicate
main lifecycle and selecting only affected roles in the merge queue are the
largest safe opportunities.

Cache hit rate is not exposed in run-list metadata. The Nix and OCI cache setup
steps and existing job summaries remain the evidence source for cold and warm
comparisons. No raw disk artifact is transferred between jobs. Release role
jobs intentionally build and validate the image and AMI on one runner.

## Responsibility map and decisions

| Workflow | Triggers | Jobs | Evidence owned | Expensive work | v0.2.1 decision |
| --- | --- | --- | --- | --- | --- |
| `ami-switch-benchmark.yml` | manual | `benchmark` | A retained worker AMI can switch from CentOS bootc to the immutable worker image and roll back | AMI import, EC2 launch, bootc switch, rollback | Keep advisory and manual. It validates a distinct migration path. |
| `ami.yml` | selected pull-request paths, manual, unused reusable interface | `ami` | Raw disk construction, AMI compatibility, optional AWS metadata and boot validation | bootc image and raw disk build; optional EBS Direct upload and EC2 launch | Keep. Remove the unused reusable interface. Release owns retained AMIs itself. |
| `audit-ami-resources.yml` | daily schedule, manual | `audit` | Disposable AMI validation resources do not leak | AWS metadata inventory and cleanup audit | Keep. A missing `AWS_AMI_AUDIT_ROLE_ARN` intentionally skips the job and must remain visible as configuration debt. |
| `infra.yml` | selected pull-request paths, manual | `plan`, `apply` | OpenTofu formatting, validation, plan review, and protected apply | Provider initialization and remote plan | Keep path-scoped and advisory. A missing plan role or state bucket intentionally skips remote planning. |
| `integration.yml` | selected pull-request paths, manual | `controller-worker` | Controller and worker boot together and complete the Coolify integration contract | Two bootc builds and two concurrent VMs | Keep as distinct pull-request evidence. Do not shard because setup is already consolidated on one runner. |
| `publish.yml` | selected main pushes, manual, unused reusable interface | `publish` | Immutable controller and worker candidates exist in ECR at the source SHA | Two bootc image builds and registry pushes | Keep. Remove the unused reusable interface. Publication remains separate from release retention. |
| `release.yml` | manual | `prepare`, `roles`, `inventory`, `release` | Exact release identity, verified images, SBOMs, retained AMIs, manifest, tag, and GitHub release | Two parallel full image/SBOM/AMI jobs | Keep and replace the ambiguous bump input with an exact version. Do not split same-runner role work. |
| `update-flake-lock.yml` | weekly schedule, manual | `update` | Dependency updates arrive as reviewable pull requests | Flake update and check | Keep advisory. Its pull request is the audit and rollback boundary. |
| `validate-deployment.yml` | manual | `validate` | A deployed controller and worker match expected runtime, network, and backup contracts | AWS and HTTPS read-only validation | Keep manual until the production milestone provides stable endpoints and role configuration. |
| `validate.yml` | pull request, merge group, main push, weekly schedule, manual | `prepare`, `lifecycle-controller`, `lifecycle-worker`, `required` | Versioned Nix-owned CI plan, authoritative flake graph, and applicable controller and worker switch/rollback lifecycle | Up to two full bootc lifecycle jobs | `required` remains stable. The prepare plan is the single source for role selection, cache mode, summaries, and final gating. |

## Required and advisory gates

The branch ruleset requires only the check named `required`. The `required` job
must always start and must fail unless the Nix prepare job succeeds, every
planned lifecycle job succeeds, and every unplanned lifecycle job is skipped.
Individual lifecycle, integration, AMI,
infrastructure, publishing, audit, deployment, dependency-update, benchmark,
and release jobs are advisory or event-specific. They must not be added as
branch requirements because path filtering can leave a required workflow in a
permanently pending state.

Pull requests run the hermetic graph and any separately path-selected advisory
AMI or integration evidence. Merge groups run the hermetic graph and trusted
lifecycle evidence. Main pushes publish immutable candidates and run the
hermetic graph only after path-aware gating is enabled. Scheduled and manual
validation run both lifecycle roles. Release publication consumes previously
verified immutable inputs and performs release-specific SBOM, AMI, manifest,
and boot validation.

## Optimization decisions

Accepted for v0.2.1:

- remove unused reusable-workflow interfaces
- add a fail-safe path classifier and shadow it before enforcing it
- eliminate the duplicate main and release-publication lifecycle runs
- retain a single stable aggregate branch gate
- use explicit controller and worker jobs so failures remain attributable

Accepted for the post-release follow-up:

- parse the versioned JSON plan directly in lifecycle and cache conditions,
  leaving scalar outputs as compatibility projections only
- use full Git history only for merge-group classification and shallow checkout
  for hermetic-only events
- fail safe to both roles when the supplied merge-group base is not an ancestor
  of the head
- serialize normal immutable image publication with release publication and
  avoid unnecessary cache-token and cleanup work

Rejected for this milestone:

- the #47 shard proposal, because integration already shares setup on one runner
  and sharding would duplicate expensive initialization
- a composite action or reusable setup workflow, because the repeated YAML is
  small, visible, and more debuggable than a new abstraction layer
- larger or self-hosted runners, because the baseline does not show queue,
  CPU, memory, disk, or I/O evidence sufficient to justify cost or maintenance
- cross-event raw image artifacts, because same-runner digest-verified builds
  preserve a simpler trust boundary and avoid large transfers

The rollback for gating changes is to select both roles for every merge group.
The classifier itself also fails safe to both roles for unknown paths, invalid
or non-ancestral SHAs, rename ambiguity, mixed role changes, or diff errors.

## Authoritative planner contract

`ci/lifecycle-targets.json` is the versioned path-policy graph. Each node owns an
ordered path delta and declares its immediate ancestors. A direct controller or
worker delta selects only that lifecycle target. A common-node delta propagates
through the graph to both lifecycle descendants. Ignored paths are evaluated
before node deltas, and the explicit match order lets narrow role paths override
the broader common path rules. The planner validates node names, references,
uniqueness, and graph acyclicity before classification.

`ci-workflow-prepare` is the sole producer of the workflow plan. Schema version
2 publishes `schema_version`, the path-graph schema version, `event`,
`cache_mode`, the exact base/head comparison and relationship, per-target `run`,
`matched_paths`, and `via` evidence under `targets`, plus `fallback`, `reason`,
and the sorted unique `changed_paths`. It also emits scalar compatibility
outputs for external adapters, but the repository workflow parses the JSON plan
directly for job and cache conditions so those projections cannot become a
second policy source.

Pull requests and main pushes are hermetic-only. Merge groups use path
classification. Scheduled and manual runs select both roles, and unknown events
fail safe to both roles. Unknown paths, invalid or non-ancestral commit SHAs,
malformed diffs, and diff errors also set `fallback` and select both roles. The
manual `lifecycle_cache=isolated` plan bypasses both Cachix and the role-scoped
OCI caches, including cache cleanup. Lifecycle conditions, cache mode, the
prepare summary, and `required` all consume the published plan. The gate
requires prepare to succeed, each planned lifecycle to succeed, and each
unplanned lifecycle to be skipped. Publish and release workflows use the same
source-revision-scoped, non-cancelling concurrency group so immutable-image
critical sections for the same source do not overlap while unrelated revisions
remain independent.

## Shell ownership audit

Tracked shell files are source assets, not ambient repository executables. Their
source mode is `0644`; Nix installs executable programs with `0755` inside store
outputs or invokes test fixtures explicitly with Bash.

| Ownership | Source files | Caller and installed behavior |
| --- | --- | --- |
| Image payload | `nix/den/aspects/common/files/backup.sh`, controller and worker `files/bootstrap-*.sh` | Image construction reads their contents and installs the payload commands in the bootc image. |
| Derivation test fixture | Controller and worker `tests/bootstrap.sh`; every `tests/*.sh` | Flake checks copy, patch, and invoke these fixtures explicitly; they are not public commands. |
| General Lucidity command | `nix/pkgs/lucidity.sh`; non-CI helpers under `scripts/` for disk, VM, validation, AWS audit, and text-style behavior | `nix/pkgs/lucidity.nix` packages the public `lucidity` interface and installs helper commands under its store-owned `libexec` tree. |
| Dedicated CI app | `scripts/ci-workflow-prepare.sh`, `ci-workflow-gate.sh`, `ci-hermetic-check.sh`, and `ci-require-env.sh` | `nix/pkgs/ci-workflow.nix` creates four pinned-runtime shell applications. GitHub Actions invokes only their public flake apps. |

## Enforced runner-minute model

The representative baseline consumed 52.6 lifecycle runner minutes per merge
group: 28.7 controller minutes plus 23.9 worker minutes. With enforcement, a
controller-only change consumes 28.7 minutes, a 45.4% reduction; a worker-only
change consumes 23.9 minutes, a 54.6% reduction; and a documentation or
infrastructure-only change consumes no lifecycle runner minutes. Shared,
unknown, mixed-target, and failed classifications intentionally retain the full
52.6-minute fail-safe path. The duplicate 52.6-minute lifecycle run after every
main merge is eliminated independently of path classification.
