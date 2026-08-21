# Troubleshooting

Start with the smallest reproducible flake output, then return to the full graph.

## Show the evaluated interface

```console
nix flake show
nix run .#lucidity -- --help
```

## A flake check failed

Run the failing attribute with logs, for example:

```console
nix build .#checks.x86_64-linux.runtime-tools --no-link --print-build-logs
```

After fixing it, run `nix flake check --show-trace --print-build-logs`. Focused
checks are diagnostic aids; the full graph remains authoritative.

## The public cache is ignored

Nix may warn that `https://lucidity.cachix.org` or its public key is untrusted
when the local daemon does not permit user-specified substituters. Add the cache
and key to trusted daemon configuration, or expect local builds. CI configures
the cache through the pinned Cachix action.

## KVM or VM startup fails

Confirm `/dev/kvm` is available to the current user, virtualization is enabled,
and the host is x86_64 Linux. Check container logs with the engine reported by
the failing flake app. The CI runner enables KVM through the Determinate action.

## VM SSH fails

Use the generated `admin` identity with the `admin` account and `sudo -n` for
privileged commands. Direct administrator root login is intentionally denied.
The controller-generated Coolify identity is the separate root identity allowed
only on the worker.

## OpenTofu cannot initialize

Verify `.lucidity/backend.aws.s3.tfbackend` or
`LUCIDITY_BACKEND_CONFIG` points to a reviewed backend configuration. Planning
without a backend is allowed; applying without an explicit backend fails closed.

## Secret resolution fails

Run `nix run .#lucidity -- secrets check PROFILE PROVIDER`. Verify the profile,
provider, and its normal authentication session. For OpenBao, verify `BAO_ADDR`,
`BAO_CACERT`, and the short-lived authentication method without printing the
token. For AWS, verify the region and OIDC or local SDK authentication. Never
print a value to diagnose it. See
[secrets and access](../security/secrets-and-access.md).

## GitHub merge queue fails

Inspect the merge-group run, not only the pull-request checks. Lifecycle jobs run
only for trusted events. Fix the cause on the PR branch, wait for its ordinary
checks, then enqueue the exact head commit again.
