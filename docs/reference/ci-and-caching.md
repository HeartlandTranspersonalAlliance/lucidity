# CI and caching

GitHub workflows are runner adapters around flake apps. `nix flake check` is the
required hermetic graph.

The v0.2.1 workflow responsibility map, measurements, and optimization decisions
are recorded in [the GitHub Actions audit](ci-workflow-audit.md). Reproduce its
run metadata with `lucidity ci workflow audit` from the locked Nix environment.

## Nix store cache

The flake declares `https://lucidity.cachix.org` and its pinned public key. Every
workflow that evaluates or runs flake outputs can substitute from it.

Pull requests are read-only. Merge-group, main, release, scheduled, reusable,
and trusted manual runs require `CACHIX_AUTH_TOKEN` before upload. The token is
provided only to the Cachix action and never to a Nix derivation.

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

Pull requests run the hermetic graph, AMI compatibility, and integration tests.
Controller and worker bootc switch/rollback jobs run on the trusted merge-group
event, where cache-writing credentials are permitted. The required gate combines
the hermetic result with every lifecycle result applicable to the event.

## Performance reporting

Job summaries report complete same-runner release time and compare the raw AMI
phase with the previous 10m11s split-runner baseline. Timing is diagnostic and
never a required assertion. Cache correctness is substitution of the same store
result and use of the verified image digest, not a wall-clock threshold.
