# Architecture and design philosophy

Lucidity treats the evaluated Nix graph as the source of truth for host images,
infrastructure, tests, operator tools, and CI entrypoints.

## System shape

The controller runs the Coolify control plane, Nebula lighthouse and relay,
OpenBao, Prometheus, Loki, Grafana, Alertmanager, blackbox exporter, and ntfy.
The worker runs application workloads, including the optional native OOYE bridge.
Grafana Alloy forwards bounded logs from both roles to controller Loki. Both are
AMD64 AlmaLinux bootc
systems on EC2 with Docker, AWS Systems Manager, SELinux enforcing mode, a Nix
system profile, and an administrator Home Manager profile.

The Den registry stores typed host facts. Aspects own feature files and tests.
Classes compose reusable bootc and Terranix behavior. Policies route entities to
flake outputs. Run `nix run .#architecture` to render the evaluated aspect graph.

## Design principles

### One authoritative graph

`nix flake check` is the hermetic contract. Focused checks help with diagnosis,
but do not create a second definition of correctness. GitHub workflows invoke
flake apps instead of duplicating build policy in YAML.

### Small, explicit mutable boundary

Nix owns deterministic configuration and tools. AWS credentials, secret values,
VM disks, AMIs, registry state, and runtime data remain outside derivations. CI
uses short-lived credentials and disposable infrastructure whenever practical.

### Least privilege and recoverability

Nebula carries ordinary administration and controller-to-worker traffic. Public
SSH is absent. The admin account uses sudo, while root access is limited to the
controller identity on the worker. Systems Manager provides an independent
recovery path.

### Test the deployment model

Default checks validate generated files, policies, and only the changed role's
boot/connectivity when that is sufficient.
The four-node NixOS mesh test validates detailed network rules only when run
explicitly for networking, firewall, or relay changes. Disposable bootc VMs can
validate first boot, persistent storage, upgrades, rollback, services, Docker,
Nix, and SELinux when a change needs that depth. AMI validation uses disposable
EC2 resources before an image can be retained.

### Optimize substitution, not correctness

Cachix substitutes reusable Nix store results. GHCR stores OCI layer caches.
Cache misses may make a run slower, but cannot change the authoritative graph or
the required checks.
