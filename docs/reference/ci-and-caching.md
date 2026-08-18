# CI and caching

GitHub workflows are runner adapters around flake apps. `nix flake check` is the
required hermetic graph.

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

## Trusted lifecycle checks

Pull requests run the hermetic graph, AMI compatibility, and integration tests.
Controller and worker bootc switch/rollback jobs run on the trusted merge-group
event, where cache-writing credentials are permitted. The required gate combines
the hermetic result with every lifecycle result applicable to the event.

## Performance reporting

Job summaries compare observed durations with historical baselines. Timing is
diagnostic and never a required assertion. Cache correctness is substitution of
the same store result, not a wall-clock threshold.
