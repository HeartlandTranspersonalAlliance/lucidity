# Secrets and access

Lucidity separates public configuration, secret references, credentials, and
runtime values.

## Authentication boundaries

- GitHub Actions uses OIDC for AWS access.
- Operators use SecretSpec with OpenBao as the normal production provider.
- EC2 workloads use scoped instance roles and workload credential providers.
- CI-only values enter jobs from GitHub Secrets; AWS access uses OIDC.
- AWS-hosted runtime secrets belong in AWS Secrets Manager.
- Provider-neutral or self-hosted production values belong in OpenBao. The
  worker's recovery credentials remain in AWS Secrets Manager so controller or
  OpenBao loss cannot make recovery credentials unavailable.

Secret values must not enter Nix evaluation, derivation environments, the Nix
store, repository history, command output, or CI summaries.

## SecretSpec providers

The checked-in `secretspec.toml` contains names, requirements, scopes, and
provider addresses, never values or provider credentials. Production operator,
monitoring, controller backup, and Coolify values resolve from OpenBao. CI reads
only its declared values from the runner environment. Worker recovery values
resolve independently from AWS Secrets Manager.

For local work, select a provider without changing the contract:

```console
export LUCIDITY_OPERATOR_PROVIDER=local-keyring
nix run .#lucidity -- secrets check operator

export LUCIDITY_OPERATOR_PROVIDER=local-dotenv
nix run .#lucidity -- secrets check operator
```

`local-dotenv` reads the repository's `.env`. That file and every `.env.*`
variant are ignored and must remain local; only the value-free `.env.example`
may be committed. The `onepassword-lucidity` and `bitwarden-lucidity` aliases
select a `Lucidity` vault or collection. A different local vault can be used by
passing a provider URI explicitly. Authentication remains in the provider's
normal local session and is not declared in this repository.

The `operator` profile routes production values to `openbao-production` while
the OpenBao alias reads its own short-lived provider credential directly from
`local-keyring`; the credential is not exported to child processes. Initialize
that relationship with `secretspec config provider login openbao-production`.
Use the `openbao-cli` scope only when the `bao` CLI itself needs `BAO_TOKEN`.
`LUCIDITY_OPERATOR_PROVIDER` deliberately overrides the whole profile for local
use. Administrator-key bootstrap defaults to `local-keyring` because the key is
needed before the first controller can provide OpenBao. Override that boundary
with `LUCIDITY_BOOTSTRAP_PROVIDER` when necessary.

Use scopes to give a command only the values it consumes:

```console
nix run .#lucidity -- secrets run backup-controller-s3 --scope backup-s3 -- restic snapshots
```

SecretSpec removes manifest-declared values outside the selected scope from the
child environment. Scopes minimize delivery; provider authorization still has
to enforce the security boundary.

## Administrator access

Store the workstation public key through the operator SecretSpec profile:

```console
nix run .#lucidity -- secrets set-admin-key
```

The command verifies the configured fingerprint before storing the public key.
Hosts install it for the `admin` account. Administration travels over Nebula and
uses passwordless sudo. Public TCP/22 and administrator root login are denied.

## Runtime secret initialization

After the foundation creates the controller secret container, initialize its
values with:

```console
nix run .#lucidity -- secrets initialize-controller-runtime
```

The command generates values in tmpfs, uploads them without printing them, and
refuses to replace an existing current version by default. It then asks
SecretSpec for a value-free, non-interactive check of the `controller-runtime`
scope. Host services resolve Secrets Manager dynamic references at runtime
through `asm-exec`; they do not retrieve plaintext through repository scripts.

## Nebula CA custody

Hosts generate their own private keys. Only public requests leave a host. The CA
key is encrypted before storage in OpenBao, and signing decrypts it only in a
private tmpfs directory. See [operations](../operations.md) for enrollment,
rotation, revocation, snapshots, and recovery.
