# Lucidity

Lucidity is a two-node Coolify deployment for AWS. One locked Nix flake owns the
controller and worker definitions, Nix profiles, Home Manager activation,
AlmaLinux bootc build contexts, Nebula mesh, OpenBao service, Terranix-generated
OpenTofu, SecretSpec schema, packages, and tests.

The supported operator interface is `lucidity`:

```console
nix run .#lucidity -- generate
nix run .#lucidity -- check
nix run .#lucidity -- build controller
nix run .#lucidity -- build worker
nix run .#lucidity -- vm test mesh
nix run .#lucidity -- infra plan
nix run .#lucidity -- infra apply SAVED_PLAN
nix run .#lucidity -- release
```

The target remains AMD64 AlmaLinux bootc on EC2 with Docker and Coolify. Nix
supplies application-level host tools; RPM layering is limited to the kernel,
bootc, Docker, SSM Agent, SELinux, networking, and required system libraries.

## Architecture

The Den registry defines two hosts with shared bootc, AWS, security, monitoring,
Nix, Home Manager, SecretSpec, and Nebula classes:

| Role | EC2 | Mesh address | Nebula groups |
|---|---:|---:|---|
| Controller | `t3a.small` | `100.96.0.1` | `server,controller,lighthouse,relay` |
| Worker | `t3a.medium` | `100.96.0.2` | `server,worker` |
| Initial administrator | workstation | `100.96.0.10` | `user,admin` |

The controller is the Nebula lighthouse and relay. Public UDP/4242 reaches it
through DNS-only `mesh.heartlandta.org`. There are no TCP/22 security-group
rules. Ordinary OpenSSH runs over the mesh:

- the administrator can SSH as `admin` to either host and use passwordless sudo;
- the controller can SSH as root to the worker for Coolify management;
- administrator root login and worker-to-controller SSH are denied;
- unspecified inbound overlay traffic is denied.

SSM remains an independent recovery channel when Nebula is unavailable.

## Workstation SSH key with SecretSpec

The workstation key is not committed. Source control contains only the
SecretSpec variable name and the expected SHA-256 fingerprint from the Den user
registry. Store the project key in the local SecretSpec keyring with:

```console
nix run .#lucidity -- secrets set-admin-key
```

The command defaults to `~/.ssh/id_ed25519.pub`, verifies its fingerprint, and
stores `ADMIN_SSH_PUBLIC_KEY` in `keyring://lucidity`. To select another public
key file or provider:

```console
LUCIDITY_OPERATOR_PROVIDER=keyring://lucidity \
  nix run .#lucidity -- secrets set-admin-key ~/.ssh/lucidity.pub
```

`lucidity mesh install` resolves the key through the `ssh` SecretSpec profile
and installs it only on the target host. A public key is not a credential, but
keeping it out of Git avoids publishing a durable workstation identifier.

The local keyring also stores `NEBULA_CA_PASSPHRASE`. GitHub Secrets are for
CI-only values, AWS Secrets Manager plus `asm-exec` is for AWS-hosted runtime
values, and OpenBao is for provider-neutral material and the encrypted Nebula
CA blob. Secret values must never be passed through Nix evaluation or stored in
the Nix store.

`COOLIFY_API_TOKEN` is declared by the dedicated `coolify` SecretSpec profile.
Use the local keyring for workstation-only access, GitHub Secrets for CI-only
automation, or OpenBao when the same token must remain provider-neutral. The
disposable controller/worker VM test does not consume this value: it creates a
one-hour, least-privilege token inside Coolify and discards it with the VM.

## Mesh enrollment and CA custody

Each host generates its own Nebula private key in `/var/lib/nebula`; only the
public key leaves the host for signing. The three-year CA is encrypted before
its key is stored in OpenBao. Host certificates last one year.

```console
# With an SSH/SSM port-forward to controller OpenBao on 127.0.0.1:8200
nix run .#lucidity -- mesh init
nix run .#lucidity -- mesh request worker ./enrollment/worker
nix run .#lucidity -- mesh sign \
  ./enrollment/worker/worker.pub ./enrollment/worker/host.crt \
  worker 100.96.0.2 server,worker
nix run .#lucidity -- mesh install ./enrollment/worker
```

Signing combines the encrypted CA from OpenBao and its SecretSpec-backed
passphrase only inside a private `/dev/shm` directory. It returns only the host
certificate. Daily checks alert at 60, 30, and 7 days before expiry. Revocation
uses the generated Nebula blocklist; rotation supports overlapping CA bundles.

OpenBao listens with TLS only on `127.0.0.1:8200`, stores Raft data under
`/var/lib/openbao`, and uses a dedicated AWS KMS key for auto-unseal. A daily
atomic Raft snapshot runs before node backup retention. See
[operations.md](docs/operations.md) for initialization, snapshots, recovery,
rotation, and re-enrollment.

## Infrastructure

Terranix emits Terraform-compatible JSON for the deployment and remote-state
bootstrap:

```console
nix build .#awsConfig
nix build .#state.config
nix run .#lucidity -- infra plan
```

The CLI uses `.lucidity/backend.aws.s3.tfbackend` when that ignored local file
exists. `LUCIDITY_BACKEND_CONFIG` can select another reviewed backend input.
Without either file, `lucidity infra plan` initializes with no backend and
`lucidity infra apply` fails closed.

The generated policy preserves the established AWS resource addresses and
state-bootstrap moves. It keeps one AZ, one Elastic IP per node, gp3 baseline
volumes, no NAT Gateway or ALB, basic monitoring, rejected-only flow logs, and
seven daily backups. Cloudflare proxies web and Matrix records while the mesh
record remains DNS-only. The account budget is monitoring-only at USD 1,100 per
year. The conservative documented baseline is USD 821.66 per year after the
dedicated KMS key, leaving USD 278.34 before credits and variable usage.

An infrastructure apply also sets the SES v2 account pricing plan to `NONE` and
verifies `PricingAttributes.CurrentPlan`.

## Flake outputs

Useful outputs include:

- `bootc-context-controller` and `bootc-context-worker`;
- `system-profile-controller` and `system-profile-worker`;
- `home-activation-controller` and `home-activation-worker`;
- `host-manifest-controller` and `host-manifest-worker`;
- `awsConfig` and `state.config`;
- `asmExec`, `openbaoKmsPlugin`, and `lucidity`;
- `checks.x86_64-linux.static` for the aggregate hermetic test suite;
- focused unit, policy, infrastructure, formatting, and NixOS VM checks under
  `checks.x86_64-linux`.

Run `nix flake show` for the complete evaluated interface.

## Verification

```console
nix build --no-link .#checks.x86_64-linux.treefmt --print-build-logs
nix build --no-link .#checks.x86_64-linux.static --print-build-logs
nix flake check
nix run .#lucidity -- vm test controller
nix run .#lucidity -- vm test worker
nix build --no-link .#checks.x86_64-linux.mesh-vm --print-build-logs
```

The flake uses treefmt-nix to run deadnix cleanup before Alejandra and to check
shell scripts and Actions workflows. Unit tests, repository policy assertions,
generated configuration checks, and the NixOS mesh test are first-class flake
checks. GitHub Actions builds those outputs directly instead of maintaining a
parallel script-based test runner.

Exact flake revisions live only in `flake.lock`; `flake.nix` names the intended
upstream branch where one is required. This lets the weekly, SHA-pinned
Determinate update action update every locked input instead of silently leaving
commit-pinned input URLs behind. Image workflows authenticate to GHCR through the
Nix-packaged `lucidity` interface, probe the role-scoped remote BuildKit or Podman
cache, and use it as `BUILD_CACHE_FROM` when present. Integration jobs record phase
durations in the job summary and retain failure diagnostics for seven days.

The mesh VM fixture uses an ephemeral CI-only CA and four peers. It proves the
direct and relayed paths, permitted SSH flows, passwordless sudo, and denial of
root/worker/ungrouped flows.

The flake-generated contexts, Terranix JSON, SecretSpec manifests, and `lucidity`
commands are authoritative. Superseded layouts and commands are not compatibility
interfaces.

`lucidity infra apply` requires both a saved plan and
`LUCIDITY_BACKEND_CONFIG`. It refuses every replacement. Plans containing any
deletion additionally require `LUCIDITY_ALLOW_DELETIONS=1` after the operator
has verified the mesh and Cloudflare ingress cutover.

## Source layout

```text
flake.nix                 locked dependency graph and public outputs
nix/modules/              Den hosts, classes, profiles, outputs, and Terranix
nix/lib/                  bootc context and Nebula configuration generators
nix/infra/                generated AWS and state OpenTofu roots
nix/home/                 administrator Home Manager definition
nix/pkgs/                 lucidity, asm-exec, and pinned OpenBao plugin
nix/tests/                NixOS mesh VM fixture
secretspec.toml           provider-neutral secret contract
tests/                    shell-level behavior fixtures invoked by flake checks
docs/operations.md        operating and recovery runbook
```
