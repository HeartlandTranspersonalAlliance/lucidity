# Local worker VM validation

Validated on 2026-08-14 on an x86_64 KVM host using the pinned unified image-builder container for QEMU and OVMF.

## Result

The generated AlmaLinux 10.2 worker QCOW2 booted successfully with UEFI. The automated lifecycle harness confirmed:

- NoCloud completed with no errors or recoverable errors;
- independent administrator and Coolify Ed25519 identities authenticated as root;
- Docker Engine 29.7.2 and Docker Compose 5.4.0 were operational;
- `bootc status` reported a booted bootc host;
- SELinux remained enforcing;
- `bootc-fetch-apply-updates.timer` was enabled and scheduled from 11:00 UTC with up to 30 minutes of jitter;
- no failed systemd units remained after first boot or reboot;
- a marker written into a named Docker volume under `/var/lib/docker` survived a real guest reboot.

The test discovered and fixed a systemd ordering cycle in the runtime Coolify-key service. It now runs after `cloud-final.service` as a dependency of `cloud-init.target`. Cloud-init root filesystem resizing is disabled because bootc's grow service owns that operation for composefs-backed deployments.

## Reproduce

```bash
make image-worker
make validate-disk-worker
make vm-init-worker
make vm-start-worker
make vm-validate-worker
```

Stop or discard the disposable VM with:

```bash
make vm-stop-worker
make vm-clean-worker
```

## Not yet proven

This test proves reboot persistence, not a bootc image update or rollback. The local disk tracks a `localhost` registry reference that the guest cannot fetch. The next lifecycle test must publish visibly different v1 and v2 images to a registry reachable by the guest, switch to that reference, apply the update, roll back, and confirm the same Docker volume marker after each reboot.

ARM64/Graviton boot behavior and EC2-specific cloud-init, IMDS, ENA, NVMe, and EBS growth also remain untested.
