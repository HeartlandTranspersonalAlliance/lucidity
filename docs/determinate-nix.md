# Determinate Nix operations

Both bootc roles install Nix as part of the image build. The image first enables
EPEL 10 and installs the distribution-owned `nix`, `nix-daemon`,
`nix-filesystem`, and `nix-system` packages. That gives AlmaLinux ownership of
`/nix`, the build-user identities, and the native package relationship. The
checksum-pinned Determinate Systems installer then migrates that upstream Nix
installation to Determinate Nix during the same image build.

The build also downloads the installer release's compiled
`determinate-nix.pp` and ships its pinned `nix.fc` and `determinate-nix.fc`
sources beside it. The policy contains the upstream Nix file-context rules and
Determinate Nixd additions. It installs that policy explicitly so builds behave
the same on SELinux and non-SELinux container hosts. The image verifies every
checksum and the installed SELinux module name before it can pass
`bootc container lint`.

The completed installation and locked Lucidity closure are stored under
`/usr/lib/lucidity/determinate-nix-seed`, not copied into `/nix` by the Nix
context builder. On the first boot of a new machine,
`lucidity-nix-seed.service` atomically initializes the persistent
`/var/lib/nix` state from that installer-produced seed. `nix.mount` bind-mounts
the state on the EPEL-owned `/nix` path before the image-owned Nix daemon units
start. Existing valid state is preserved across bootc updates and rollbacks;
malformed nonempty state is never overwritten automatically.

## Verify the installation

Run these checks through Session Manager:

```bash
rpm -q nix nix-daemon nix-filesystem nix-system
rpm -qf /nix
systemctl status lucidity-nix-selinux.service lucidity-nix-seed.service \
  nix.mount nix-daemon.service lucidity-nix-profile.service
mountpoint /nix
test "$(stat -c '%d:%i' /nix)" = "$(stat -c '%d:%i' /var/lib/nix)"
test -s /nix/receipt.json
semodule -l | awk '$1 == "nix" { found = 1 } END { exit !found }'
/nix/var/nix/profiles/default/bin/nix --version
getenforce
```

The installation is healthy when the four RPMs are present,
`nix-filesystem` owns `/nix`, the services and mount are active, the receipt
exists, the `nix` SELinux module is loaded, and SELinux remains enforcing. The
hosted role lifecycle gates additionally build the locked flake under
`/usr/share/lucidity/nix-smoke` and verify its persistent store result after a
bootc update and rollback.

Inspect boot failures with:

```bash
journalctl -b \
  -u lucidity-nix-selinux.service \
  -u lucidity-nix-seed.service \
  -u nix.mount \
  -u nix-daemon.service \
  -u lucidity-nix-profile.service
```

Do not manually replace `/var/lib/nix` or `nix.mount`. The provisioning service
intentionally refuses nonempty state that lacks the installer, receipt, store,
or database layout. Restore that state from a recovery point instead. Put
intentional Nix configuration overrides in `/etc/nix/nix.custom.conf`, leaving
the generated `/etc/nix/nix.conf` under Determinate Nix control.

## CI binary cache

GitHub-hosted runners install Determinate Nix with KVM explicitly enabled and
then attach the public `lucidity` Cachix cache. The cache URL and signing key are
declared in `flake.nix`, so the same trust configuration applies to local flake
consumers. Pull-request jobs receive no Cachix credential and run with
`skipPush`; trusted merge-queue, `main`, release, schedule, workflow-call, and
manual jobs fail early if `CACHIX_AUTH_TOKEN` is unavailable.

Cachix stores reusable Nix derivations and test results. It deliberately filters
the large `lucidity-*-bootc-context` outputs, and it never stores raw AMIs,
qcow2 disks, secrets, or mutable guest state. OCI layers use GHCR instead, with
separate `controller`, `worker`, and `ci-tools` scopes. Timing summaries are
observability only and are not test assertions.

## Upgrade

Review an official Determinate installer release, then update its version and
the installer, policy, and both file-context SHA-256 values in
`nix/den/classes/bootc/image.nix`. Rebuild both roles and pass their image
validation before publishing. The next bootc image contains the upgraded seed
for new machines, but the seed service does not replace an existing machine's
valid `/var/lib/nix` state. Upgrade existing machines through a separately
tested Determinate Nix maintenance procedure.

If EPEL changes the upstream Nix package split or its ownership of `/nix`, the
container build fails at the RPM assertions. Reconcile that packaging change
with the installer migration before updating the pinned base image.

## Recovery

`/var/lib/nix` is persistent machine state. Restore it from the same recovery
point as the rest of the root volume, and never attach one writable Nix store to
two running instances. For a new or intentionally reset machine, an empty
`/var/lib/nix` is initialized automatically from the image seed on the next
boot. Resetting a populated store is destructive and must be performed only in
an approved recovery window with a verified backup.
