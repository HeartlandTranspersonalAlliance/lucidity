# GitHub Actions audit for v0.3.0

This document is the responsibility map and pre-optimization baseline for issue
#52. Workflows remain thin runner adapters. Policy and executable behavior belong
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
records the failed jobs and steps for failed runs, and emits the same JSON and
Markdown for the same GitHub response. It reads only Actions metadata and never
reads repository or runtime secret values.

Preview the exact plan used by GitHub Actions with `lucidity ci workflow plan
EVENT [SCOPE] [CACHE_MODE]`. For example, `lucidity ci workflow plan
workflow_dispatch worker isolated` selects a cold-cache worker qualification.

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
consumed about 52.6 runner minutes even though they ran in parallel. This
baseline motivated removing automatic lifecycle guests from merge groups and
main pushes while retaining explicit role-scoped qualification.

The v0.3.0 merge path now keeps the controller's bootc switch and rollback,
native Nix, SELinux, OpenBao fixture, and persistent-storage evidence while
using the connectivity-only fixture to omit the full Coolify application pull.

Cache hit rate is not exposed in run-list metadata. The Nix and OCI cache setup
steps and existing job summaries remain the evidence source for cold and warm
comparisons. No raw disk artifact is transferred between jobs. Release role
jobs intentionally build and validate the image and AMI on one runner.

## Responsibility map and decisions

| Workflow | Triggers | Jobs | Evidence owned | Expensive work | v0.3.0 decision |
| --- | --- | --- | --- | --- | --- |
| `ami-switch-benchmark.yml` | manual | `benchmark` | A retained worker AMI can switch from CentOS bootc to the immutable worker image and roll back | AMI import, EC2 launch, bootc switch, rollback | Keep advisory and manual. It validates a distinct migration path. |
| `ami.yml` | selected pull-request paths, manual | `ami` | Raw disk construction, AMI compatibility, optional AWS metadata and boot validation | bootc image and raw disk build; optional EBS Direct upload and EC2 launch | Keep. The unused reusable interface was removed; release owns retained AMIs itself. |
| `audit-ami-resources.yml` | daily schedule, manual | `audit` | Disposable AMI validation resources do not leak | AWS metadata inventory and cleanup audit | Keep. A missing `AWS_AMI_AUDIT_ROLE_ARN` intentionally skips the job and must remain visible as configuration debt. |
| `infra.yml` | selected pull-request paths, manual | `plan`, `apply` | OpenTofu formatting, validation, plan review, and protected apply | Provider initialization and remote plan | Keep path-scoped and advisory. A missing plan role or state bucket intentionally skips remote planning. |
| `integration.yml` | non-draft pull request, manual | `classify`, `boot` | The affected role boots healthy, or the pair establishes strict host-key-checked SSH for shared changes | Zero, one, or two bootc builds selected conservatively from the GitHub file list | Keep advisory. Unknown and mixed changes select the pair; infrastructure and documentation changes skip guest work. |
| `notify-ci.yml` | completed CI workflow runs | `notify` | Failed job and step details reach the operator notification endpoint | GitHub API read and one ntfy publish | Keep advisory. The trusted default-branch workflow resolves its token at runtime and never becomes a merge gate. |
| `publish.yml` | selected main pushes, manual | `publish` | Immutable controller and worker candidates exist in ECR at the source SHA | Two bootc image builds and registry pushes | Keep. The unused reusable interface was removed; publication remains separate from release retention. |
| `release.yml` | merged PR #70, manual recovery | `prepare`, `roles`, `inventory`, `release` | Exact release identity, verified images, SBOMs, retained AMIs, manifest, tag, and GitHub release | Two parallel full image/SBOM/AMI jobs | Automatically publish v0.3.0 from PR #70's merge commit. Keep exact-version manual dispatch only for release-tool recovery. Do not split same-runner role work. |
| `update-flake-lock.yml` | weekly schedule, manual | `update` | Dependency updates arrive as reviewable pull requests | Flake update and check | Keep advisory. Its pull request is the audit and rollback boundary. |
| `validate-deployment.yml` | manual | `validate` | A deployed controller and worker match expected runtime, network, and backup contracts | AWS and HTTPS read-only validation | Keep manual until the production milestone provides stable endpoints and role configuration. |
| `validate.yml` | pull request, merge group, main push, manual | `prepare`, `lifecycle-controller`, `lifecycle-worker`, `required` | Versioned Nix-owned CI plan, authoritative flake graph, and explicitly selected switch/rollback qualification | No lifecycle guests for automatic events; one or two role guests only when manually selected | `required` remains stable. Manual dispatch owns role selection and cache mode. Routine automation stays hermetic. |

## Required and advisory gates

The branch ruleset requires only the check named `required`. The `required` job
must always start and must fail unless the Nix prepare job succeeds, every
planned lifecycle job succeeds, and every unplanned lifecycle job is skipped.
It invokes the versioned gate script directly with Bash and the runner's `jq`,
so it does not repeat the Nix and Cachix bootstrap.
Individual lifecycle, integration, AMI,
infrastructure, publishing, audit, deployment, dependency-update, benchmark,
and release jobs are advisory or event-specific. They must not be added as
branch requirements because path filtering can leave a required workflow in a
permanently pending state.

Pull requests run the hermetic graph and any separately path-selected advisory
AMI or integration evidence. Merge groups and main pushes run the hermetic
graph without lifecycle guests. Manual validation selects no lifecycle by
default and can explicitly select the controller, worker, or both. Release
publication consumes previously qualified immutable inputs and performs
release-specific SBOM, AMI, manifest, and boot validation.

## Artifact test tiers

| Change or milestone | Evidence | Execution |
| --- | --- | --- |
| Ordinary image or profile change | Build and validate the role QCOW2, boot it directly, verify the expected bootc image reference and critical services, and prove controller-worker SSH for shared connectivity changes | Path-selected pull-request workflow |
| Bootc, persistent storage, native Nix, SELinux, or recovery change | Switch, update, rollback, and verify persistent role state after each reboot | Explicit manual lifecycle scope for the affected role; select both only when the role-specific state boundaries differ |
| Release candidate | Build raw disks from verified ECR digests, upload them with EBS Direct, launch disposable AMIs, and bind the resulting retained AMIs to the release inventory | Release workflow and protected AWS validation |
| Installer ISO change | Boot the ISO and perform an unattended Kickstart install onto a disposable disk | Out of scope until Lucidity publishes an Anaconda or bootc installer ISO |

This follows the upstream Image Builder distinction between artifact build and
boot tests and installer-specific tests. The OSBuild images suite dynamically
builds and boots applicable image types and caches them by manifest ID, while
Kickstart and Anaconda customizations belong to installer image types. See the
[OSBuild images testing guide](https://osbuild.org/docs/developer-guide/projects/images/test/)
and [Image Builder blueprint reference](https://osbuild.org/docs/user-guide/blueprint-reference/).

## GitHub Action dependency policy

Workflow YAML is an adapter for GitHub platform capabilities. Project tools,
formatters, linters, builds, tests, release logic, and policy checks belong in
the flake so the same commands run locally and in CI. External Actions are
limited to source checkout, trusted Nix bootstrap, cache access, GitHub OIDC,
artifact and attestation I/O, and dependency pull-request automation.

`ci/github-actions-allowlist.json` records every permitted external Action, its
category, and why GitHub-native integration is preferable to a flake command.
The Nix-owned YAML policy rejects unapproved Actions, unused allowlist entries,
and references that are not pinned to a full commit SHA. First-party local
Actions under `.github/actions` remain allowed; they execute trusted code from
the checked-out default branch.

Run the complete local suite with `nix run .#check`. For a fast iteration that
omits KVM lifecycle checks, use
`LUCIDITY_SKIP_VM_CHECKS=1 nix run .#check`.

## Optimization decisions

Accepted for v0.3.0:

- remove unused reusable-workflow interfaces
- add a fail-safe path classifier and shadow it before enforcing it
- eliminate the duplicate main and release-publication lifecycle runs
- retain a single stable aggregate branch gate
- use explicit controller and worker jobs so failures remain attributable

Accepted for the post-release follow-up:

- remove automatic full lifecycle guests from pull requests, merge groups, and
  main pushes
- replace the path classifier and full-history checkout with an explicit manual
  `none`, `controller`, `worker`, or `both` scope that defaults to `none`
- retain the full switch, update, rollback, persistence, native Nix, and SELinux
  harness for focused release and recovery qualification
- serialize normal immutable image publication with release publication and
  avoid unnecessary cache-token and cleanup work

Rejected for this milestone:

- the #47 shard proposal, because the boot-connect check already shares setup
  on one runner and sharding would duplicate image construction
- a composite action or reusable setup workflow, because the repeated YAML is
  small, visible, and more debuggable than a new abstraction layer
- larger or self-hosted runners, because the baseline does not show queue,
  CPU, memory, disk, or I/O evidence sufficient to justify cost or maintenance
- cross-event raw image artifacts, because same-runner digest-verified builds
  preserve a simpler trust boundary and avoid large transfers

The rollback for this optimization is an explicit manual dispatch with
`lifecycle_scope=both`. Automatic events reject lifecycle scope rather than
silently expanding an uncertain change into two expensive jobs.

## Authoritative planner contract

`ci-workflow-prepare` is the sole producer of the workflow plan. Schema version
3 publishes `schema_version`, `event`, `cache_mode`, `lifecycle_scope`, the two
role `run` decisions, and a human-readable reason. It emits only the JSON plan;
the workflow parses that plan directly for role and cache conditions.

Pull requests, merge groups, and main pushes accept only `lifecycle_scope=none`
and are hermetic-only. A manual dispatch can select `none`, `controller`,
`worker`, or `both`. Unsupported events, automatic lifecycle requests, invalid
scopes, and invalid cache modes fail preparation instead of launching expensive
fallback jobs. The manual `lifecycle_cache=isolated` plan bypasses Cachix and
the selected role-scoped OCI caches, including cache cleanup. The gate requires
prepare to succeed, each planned lifecycle to succeed, and each unplanned
lifecycle to be skipped. Publish and release workflows use the same
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
| Dedicated CI app | `scripts/ci-workflow-prepare.sh`, `ci-workflow-gate.sh`, `ci-integration-classify.sh`, `ci-hermetic-check.sh`, and `ci-require-env.sh` | `nix/pkgs/ci-workflow.nix` creates pinned-runtime applications for local and Nix checks. The lightweight prepare, classifier, environment guard, and final gate execute with Bash in GitHub before or without Nix installation. |

## Enforced runner-minute model

The representative baseline consumed 52.6 lifecycle runner minutes per merge
group: 28.7 controller minutes plus 23.9 worker minutes. Automatic validation
now consumes zero lifecycle runner minutes. An explicit controller
qualification consumes the observed 28.7-minute baseline, a worker
qualification consumes 23.9 minutes, and a deliberate dual-role qualification
consumes 52.6 minutes. The jobs still run in parallel when both are selected.
