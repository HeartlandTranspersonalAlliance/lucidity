# CI and caching

GitHub workflows are runner adapters around flake apps. `nix flake check` is the
required hermetic graph.

The v0.3.0 workflow responsibility map, measurements, and optimization decisions
are recorded in [the GitHub Actions audit](ci-workflow-audit.md). Reproduce its
run metadata with `lucidity ci workflow audit` from the locked Nix environment.

## Nix store cache

The flake declares `https://lucidity.cachix.org` and its pinned public key. Every
workflow that evaluates or runs flake outputs can substitute from it.

Pull requests are read-only. Cache-producing steps on merge-group, main,
scheduled, and trusted manual runs require `CACHIX_AUTH_TOKEN` before upload.
The stable aggregate gate only substitutes from the public cache, so it neither
receives nor requires the write token. The token is provided only to the Cachix
action and never to a Nix derivation.

The large controller and worker bootc contexts are excluded from direct upload.
Their reusable dependencies and small check results remain cacheable. Raw AMI
and qcow2 files, secrets, and mutable runtime state are never Cachix outputs.

## OCI layer cache

GHCR is authoritative for OCI layers. Controller, worker, and `ci-tools` use
independent scopes. Pull requests restore scopes; trusted jobs may update them.
The tooling builder honors `BUILD_CACHE_FROM` and `BUILD_CACHE_TO`.

Release jobs preserve the stronger isolation boundary of one ephemeral runner
per role while reusing that runner's verified local OCI layers for raw AMI
construction. Controller and worker remain independent, and raw disks are not
uploaded or transferred between jobs. Normal immutable publication and release
publication share a source-revision-scoped non-cancelling concurrency group.
This prevents both paths from building and pushing the same source revision at
the same time without blocking publication of an unrelated revision.

## Trusted lifecycle checks

Pull requests, merge groups, and main pushes run the hermetic graph. Selected
pull requests also run the separate advisory AMI compatibility and
controller-worker boot-connect workflows. Full bootc switch, update, and
rollback guests are not automatic merge gates.

The **Validate locked flake** manual dispatch accepts `lifecycle_scope=none`,
`controller`, `worker`, or `both`; `none` is the safe default. Choose only an
affected role for role-specific storage or service changes. Choose `worker` as
the representative full lifecycle for shared bootc mechanics. Choose `both`
only when shared persistent-state behavior differs by role or when explicitly
qualifying a release candidate. The controller lifecycle uses the
connectivity-only fixture, so it proves native Nix, SELinux, OpenBao, storage,
and deployment transitions without pulling the full Coolify application.
Full controller bootstrap remains an explicit local qualification test.

The `Nix prepare` job publishes a small versioned plan containing the event,
manual scope, cache mode, and role targets. Downstream job conditions and the
stable `required` gate consume that plan. The gate fails unless preparation
succeeds, each manually planned lifecycle succeeds, and every unplanned
lifecycle reports `skipped`.

Manual validation also accepts `lifecycle_cache=isolated`. That mode bypasses
the Lucidity Cachix and role-scoped GHCR cache for each selected lifecycle job,
providing an explicit cold-cache check. It skips cache cleanup because no cache
login or builder was created. The default `warm` mode restores the selected
role caches.

## Performance reporting

Job summaries report complete same-runner release time and compare the raw AMI
phase with the previous 10m11s split-runner baseline. Timing is diagnostic and
never a required assertion. Cache correctness is substitution of the same store
result and use of the verified image digest, not a wall-clock threshold.
