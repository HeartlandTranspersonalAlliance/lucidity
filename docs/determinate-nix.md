# Determinate Nix operations

Both bootc roles install Determinate Nix on first boot through
`determinate-nix-install.service`. The image contains a checksum-pinned installer,
but the installer runs only on the live system because its OSTree planner must create
and start systemd units. It binds `/var/lib/nix` to `/nix` and installs its own SELinux
policy while SELinux remains enforcing. The image maps `/usr/local` to
`/var/usrlocal`, following rpm-ostree's machine-local layout, so the Nixd binary is
writable and persists across image updates and rollbacks.

## Verify the installation

Run these checks through Session Manager:

```bash
systemctl status determinate-nix-install.service nix-daemon.service nix.mount
mountpoint /nix
test "$(stat -c '%d:%i' /nix)" = "$(stat -c '%d:%i' /var/lib/nix)"
/nix/var/nix/profiles/default/bin/nix --version
getenforce
```

The install is complete only when `/nix/receipt.json` exists, the daemon is active,
the two paths identify the same bind-mounted directory, and `getenforce` prints
`Enforcing`. The hosted controller and worker lifecycle gates additionally build the
locked flake under `/usr/share/coolify-aws/nix-smoke` and verify its persistent store
result after bootc update and rollback.

Inspect first-boot failures with:

```bash
journalctl -u determinate-nix-install.service -u nix-daemon.service -b
systemctl status determinate-nix-install.service
```

The image-owned service detects an interrupted receipt and uses the pinned installer
to revert it before retrying. After correcting a transient network or disk-space
failure, retry the service:

```bash
systemctl reset-failed determinate-nix-install.service
systemctl restart determinate-nix-install.service
```

Do not create or edit `nix.mount`; the OSTree planner owns it. Put intentional Nix
configuration overrides in `/etc/nix/nix.custom.conf`, leaving the generated
`/etc/nix/nix.conf` under Determinate Nix control.

## Upgrade

Upgrade the pinned installer in `nix/den/classes/bootc/image.nix` by reviewing an official release,
updating its version, commit, binary digest, and license digest together, then passing
both complete guest lifecycle jobs. Updating the image does not replace an existing
persistent Nix installation. Schedule Determinate Nix package upgrades separately
with `determinate-nixd upgrade`, validate the daemon and a flake build, and record the
result in the maintenance log.

## Uninstall and reinstall

Uninstalling deletes Nix-managed state and is a destructive maintenance operation.
Take and identify a current root-volume recovery point first. Prevent the image from
immediately reinstalling Nix, then use the receipt-owned installer:

```bash
systemctl mask --now determinate-nix-install.service
/nix/nix-installer uninstall --no-confirm
```

Verify that the Nix daemon and mount are gone before closing the maintenance window.
To restore the image's declared state, remove the mask and start the bootstrap again:

```bash
systemctl unmask determinate-nix-install.service
systemctl start determinate-nix-install.service
```

After reinstalling, repeat the verification checks and a flake build. During node
recovery, restore the root volume containing `/var/lib/nix`; do not attach one writable
Nix store to two running instances.
