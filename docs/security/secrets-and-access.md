# Secrets and access

Lucidity separates public configuration, secret references, credentials, and
runtime values.

## Authentication boundaries

- GitHub Actions uses OIDC for AWS access.
- Operators use their AWS SDK credential chain.
- EC2 workloads use scoped instance roles and workload credential providers.
- CI-only values belong in GitHub Secrets.
- AWS-hosted runtime secrets belong in AWS Secrets Manager.
- Provider-neutral or self-hosted values belong in OpenBao.

Secret values must not enter Nix evaluation, derivation environments, the Nix
store, repository history, command output, or CI summaries.

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
refuses to replace an existing current version by default. Host services resolve
Secrets Manager dynamic references at runtime through `asm-exec`; they do not
retrieve plaintext through repository scripts.

## Nebula CA custody

Hosts generate their own private keys. Only public requests leave a host. The CA
key is encrypted before storage in OpenBao, and signing decrypts it only in a
private tmpfs directory. See [operations](../operations.md) for enrollment,
rotation, revocation, snapshots, and recovery.
