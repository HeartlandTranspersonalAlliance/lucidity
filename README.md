# Lucidity

Lucidity deploys a secure two-node Coolify environment on AWS. A locked Nix
flake defines the controller, worker, bootc images, OpenTofu infrastructure,
tests, and operator commands.

Current version: **0.2.0**

## Prerequisites

- Nix with flakes enabled
- An x86_64 Linux host for image and VM tests
- Docker or Podman for bootc image work
- KVM for full local VM validation

AWS credentials are only needed for infrastructure and deployment commands.
Use GitHub Actions OIDC in CI. Never put credentials or secret values in Nix
files, flake arguments, or the Nix store.

## Quick start

```console
git clone git@github.com:HeartlandTranspersonalAlliance/lucidity.git
cd lucidity
nix flake show
nix run .#lucidity -- check
```

The last command runs the authoritative `nix flake check` graph.

## Common commands

| Goal | Command |
|---|---|
| Show all outputs | `nix flake show` |
| Validate the repository | `nix run .#lucidity -- check` |
| Build the controller image | `nix run .#lucidity -- build controller` |
| Build the worker image | `nix run .#lucidity -- build worker` |
| Test the private mesh | `nix run .#lucidity -- vm test mesh` |
| Generate configuration | `nix run .#lucidity -- generate` |
| Plan AWS infrastructure | `nix run .#lucidity -- infra plan` |
| Back up application data | `sudo lucidity backup run` |
| Plan remote state | `nix run .#state -- plan` |
| Show the evaluated architecture | `nix run .#architecture` |

Use `nix run .#lucidity -- --help` for the complete command interface.

## What gets deployed

| Role | Default EC2 type | Private mesh address | Purpose |
|---|---:|---:|---|
| Controller | `t3a.small` | `100.96.0.1` | Coolify control plane, Nebula lighthouse, OpenBao |
| Worker | `t3a.medium` | `100.96.0.2` | Application workloads |

SSH administration uses the private Nebula mesh. The administrator logs in as
`admin` and uses passwordless sudo. Public TCP/22 access and administrator root
login are denied. AWS Systems Manager remains the recovery channel.

## Before deploying

1. Read the [operations runbook](docs/operations.md).
2. Configure the workstation public key with
   `nix run .#lucidity -- secrets set-admin-key`.
3. Review the generated OpenTofu plan before applying it.
4. Run the local VM and mesh validations appropriate to the change.

Infrastructure apply requires a saved plan and an explicit backend
configuration. Changes that delete resources require a separate opt-in.

## Documentation

Start with the [documentation index](docs/README.md).

- [Architecture and design philosophy](docs/concepts/architecture.md)
- [Advanced customization](docs/guides/advanced-customization.md)
- [Troubleshooting](docs/guides/troubleshooting.md)
- [Backup and restore](docs/guides/backup-and-restore.md)
- [Production readiness](docs/production-readiness.md)
- [Secrets and access](docs/security/secrets-and-access.md)
- [CI and caching](docs/reference/ci-and-caching.md)
- [Release process](docs/reference/releases.md)
- [Changelog](CHANGELOG.md)

## Repository map

```text
nix/den/       typed hosts, aspects, classes, and output policies
nix/flake/     apps, checks, formatting, and project composition
nix/infra/     Terranix-generated AWS and state configurations
nix/pkgs/      packaged operator and CI tools
tofu/modules/  reusable Terraform-compatible OpenTofu modules
docs/          concepts, guides, security, operations, and references
```

The Nix flake is authoritative. GitHub workflows are thin adapters for events,
permissions, short-lived credentials, and artifact transport.
