# Lucidity operations and recovery

## Activation order

Both roles activate Determinate Nix, the locked system profile, Home Manager,
and Nebula in order. The controller then starts OpenBao before its Coolify
bootstrap; the worker starts its role-specific bootstrap after Nebula.

Persistent state includes `/var/lib/nix`, `/var/lib/nebula`, `/var/lib/docker`,
`/var/lib/coolify`, `/data/coolify`, `/var/home/admin`, and `/var/usrlocal`.
Both roles bind `/var/lib/coolify` onto the image-baked `/data/coolify` path so
Coolify can manage an otherwise immutable bootc host. The controller also
preserves `/var/lib/openbao`.

## OpenBao initialization

1. Apply the reviewed generated infrastructure and boot the controller.
2. Use SSM to establish a local forward to `127.0.0.1:8200`.
3. Confirm `openbao.service` uses the dedicated KMS key and is reachable only on
   loopback.
4. Initialize OpenBao, place recovery material in the operator-approved offline
   custody system, and enable a least-privilege KV policy for `secret/nebula/ca`.
5. Supply the snapshot service token with a systemd credential. Never place a
   token in the image, Nix store, environment file, or journal.
6. Run `systemctl start openbao-snapshot.service`, verify a new mode-0600 atomic
   snapshot, and exercise restoration on a disposable SSM-reachable controller.

OpenBao unavailability does not interrupt established Nebula connections. It
pauses issuance and revocation changes until custody is restored.

## Controller restore

1. Reach the replacement through SSM and verify the bootc deployment digest.
2. Restore persistent node backup data, including OpenBao Raft and Coolify state.
3. Confirm KMS auto-unseal and `bao operator raft list-peers` before enabling the
   Coolify bootstrap.
4. Restore `/var/lib/nebula` or re-enroll the controller with the same overlay
   address and groups.
5. Validate administrator SSH, controller-to-worker root SSH, direct traffic,
   and forced relay traffic before changing DNS or Elastic IP association.

## OpenBao snapshot restore

Use an SSM session with a loopback port-forward. Stop application writes, take a
final snapshot if possible, and preserve the failed Raft directory separately.
Restore only a snapshot whose ownership, mode, checksum, and backup lineage have
been verified. After restore, test KV ACLs and confirm neither tokens nor CA
material appear in `journalctl -u openbao`.

## Nebula revocation and rotation

`lucidity mesh revoke FINGERPRINT` adds the exact 64-character Nebula
fingerprint to the root-only blocklist and reloads the peer. Distribute the same
generated list to every peer.

For CA rotation, create a new encrypted CA, deploy a bundle containing old and
new public CA certificates, reissue every peer certificate, and verify all peers
use the new issuer. Remove the old CA only after the overlap window and publish
its remaining certificate fingerprints to the blocklist where required.

## Worker re-enrollment

Generate the replacement key on the worker itself, export only its `.pub` file,
sign it as `100.96.0.2` with groups `server,worker`, and install the returned
certificate beside the existing private key. Include the controller's dedicated
SSH public key during installation so only the worker root account accepts that
management identity. Validate through SSM before restarting Nebula.

## Recovery checks

- SSM reaches both hosts while Nebula is stopped.
- No security group has a TCP/22 rule.
- `admin` is password-locked and has passwordless sudo on both hosts.
- Administrator root SSH and worker-to-controller SSH fail.
- Controller root SSH to `100.96.0.2` succeeds.
- OpenBao listens only on `127.0.0.1:8200` and auto-unseals through KMS.
- Bootc switch and rollback preserve mesh identity, administrator access,
  OpenBao Raft, Docker state, and Coolify data.
