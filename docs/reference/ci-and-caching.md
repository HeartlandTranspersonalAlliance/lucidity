# CI and caching

GitHub workflows are runner adapters around flake apps. `nix flake check` is the
required hermetic graph.

The v0.2.1 workflow responsibility map, measurements, and optimization decisions
are recorded in [the GitHub Actions audit](ci-workflow-audit.md). Reproduce its
run metadata with `lucidity ci workflow audit` from the locked Nix environment.

## Nix store cache

The flake declares `https://lucidity.cachix.org` and its pinned public key. Every
workflow that evaluates or runs flake outputs can substitute from it.

Pull requests are read-only. Merge-group, main, scheduled, and trusted manual
runs require `CACHIX_AUTH_TOKEN` before upload. The token is provided only to
the Cachix action and never to a Nix derivation.

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
uploaded or transferred between jobs.

## Trusted lifecycle checks

Pull requests and main pushes run the hermetic graph. Path-selected pull requests
also run the advisory AMI compatibility and integration workflows. The
`Nix prepare` job publishes one versioned JSON plan before evaluating the
hermetic graph. On a merge group, its fail-safe path classifier selects the
controller lifecycle, worker lifecycle, both, or neither. Unknown paths and
classification errors select both. Scheduled and manual validation always plan
both roles.
Downstream job conditions, cache selection, the human-readable job summary, and
the stable `required` gate all consume that same plan. The gate fails unless
prepare succeeds, every planned lifecycle succeeds, and every unplanned
lifecycle reports `skipped`.

Manual validation accepts `lifecycle_cache=isolated`. That mode bypasses the
Lucidity Cachix and role-scoped GHCR caches for both lifecycle jobs, providing a
cold-cache release check. The default `warm` mode restores both caches and is
used for the same-SHA warm comparison.

## Performance reporting

Job summaries report complete same-runner release time and compare the raw AMI
phase with the previous 10m11s split-runner baseline. Timing is diagnostic and
never a required assertion. Cache correctness is substitution of the same store
result and use of the verified image digest, not a wall-clock threshold.
