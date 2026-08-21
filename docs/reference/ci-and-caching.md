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

Pull requests and main pushes run the hermetic graph. Path-selected pull requests
also run the advisory AMI compatibility and integration workflows. The
`Nix prepare` job publishes one versioned JSON plan before evaluating the
hermetic graph. Its checked-in `ci/lifecycle-targets.json` graph assigns ordered
path deltas to the controller, worker, and their common ancestor. On a merge
group, the fail-safe classifier records the exact ancestor comparison and
selects the controller lifecycle, worker lifecycle, both, or neither. A
common-node change propagates to both descendants. Unknown paths and
classification errors select both. Scheduled and manual validation always plan
both roles. The controller job uses the connectivity-only cloud-init fixture for
boot, switch, update, rollback, native Nix, SELinux, and storage evidence without
pulling the full Coolify application stack. Full controller bootstrap remains an
explicit local qualification test.
Downstream job conditions, cache selection, the human-readable job summary, and
the stable `required` gate all consume that same plan. GitHub job conditions
parse the JSON plan directly rather than depending on parallel scalar outputs.
The gate fails unless prepare succeeds, every planned lifecycle succeeds, and
every unplanned lifecycle reports `skipped`.

Manual validation accepts `lifecycle_cache=isolated`. That mode bypasses the
Lucidity Cachix and role-scoped GHCR caches for both lifecycle jobs, providing a
cold-cache release check. It also skips cache cleanup because no cache login or
builder was created. The default `warm` mode restores both caches and is used
for the same-SHA warm comparison.

## Performance reporting

Job summaries report complete same-runner release time and compare the raw AMI
phase with the previous 10m11s split-runner baseline. Timing is diagnostic and
never a required assertion. Cache correctness is substitution of the same store
result and use of the verified image digest, not a wall-clock threshold.
