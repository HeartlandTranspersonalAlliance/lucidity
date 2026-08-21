# Advanced customization

Customize the narrowest owner of a behavior, then run its focused check and the
full flake graph.

## Host facts

Edit `nix/den/entities/hosts.nix` for typed controller and worker facts such as
role identity and mesh addressing. Keep shared behavior out of entity records.

## Feature behavior

Edit `nix/den/aspects/common`, `controller`, or `worker` for role-owned files,
services, and tests. Place fixtures beside the aspect that consumes them so
unrelated checks retain their store paths.

## Image composition

Edit `nix/den/classes/bootc` for shared bootc image behavior, system profiles,
cloud-init fixtures, and mesh configuration. Preserve the boundary between RPM
content required by the operating system and application tools supplied by Nix.

## Infrastructure

Edit `tofu/modules/` for reusable Terraform-compatible modules. Edit
`nix/infra/` for Terranix composition and contract tests. Use OpenTofu, review a
saved plan, and never apply a plan containing replacement or deletion without
the documented explicit approval.

## Operator commands

The supported interface lives in `nix/pkgs/lucidity.sh` and is packaged by Nix.
Runtime scripts live in `scripts/` and are installed with Nix-store shebangs.
Do not call repository scripts directly from GitHub workflows.

## Validation loop

```console
nix fmt
nix build .#checks.x86_64-linux.static --no-link --print-build-logs
nix flake check --show-trace --print-build-logs
```

For image or service changes, also run the appropriate controller or worker VM
test. The four-node mesh VM is intentionally outside the default flake checks;
for networking, firewall, or relay changes, run `nix run .#test-mesh`. See
[local VM validation](../local-vm-validation.md) for resource requirements.
