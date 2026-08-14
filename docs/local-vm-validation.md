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

The GitHub-hosted lifecycle also validates a registry-backed bootc switch to v1, an update to a visibly different v2 image, and rollback to v1. The same Docker volume marker survives both additional reboots and SELinux remains enforcing.

The test discovered and fixed a systemd ordering cycle in the runtime Coolify-key service. It now runs after `cloud-final.service` as a dependency of `cloud-init.target`. Cloud-init root filesystem resizing is disabled because bootc's grow service owns that operation for composefs-backed deployments.

## Reproduce

```bash
make image-worker
make validate-disk-worker
make vm-init-worker
make vm-start-worker
make vm-validate-worker
make vm-registry-start-worker
make vm-update-rollback-worker
```

Stop or discard the disposable VM with:

```bash
make vm-registry-stop-worker
make vm-stop-worker
make vm-clean-worker
```

## Remaining AWS validation

The local registry is deliberately unauthenticated and permits HTTP only on the disposable QEMU host gateway. It proves bootc lifecycle mechanics, not ECR authentication. The EC2 lifecycle must repeat the test using a published, authenticated ECR reference.

ARM64/Graviton boot behavior and EC2-specific cloud-init, IMDS, ENA, NVMe, and EBS growth also remain untested.
