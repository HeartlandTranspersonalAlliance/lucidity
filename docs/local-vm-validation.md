# Local VM validation

Validated on 2026-08-16 on GitHub-hosted x86_64 KVM runners using the pinned unified image-builder container for QEMU and OVMF. The controller and worker results are recorded in [Validate run 31937293809](https://github.com/HeartlandTranspersonalAlliance/lucidity/actions/runs/31937293809).

## Result

The generated AlmaLinux 10.2 worker QCOW2 booted successfully with UEFI. The automated lifecycle harness confirmed:

- NoCloud completed with no errors or recoverable errors;
- independent administrator and Coolify Ed25519 identities authenticated as root;
- Docker Engine 29.7.2 and Docker Compose 5.4.0 were operational;
- `bootc status` reported a booted bootc host;
- SELinux remained enforcing;
- `bootc-fetch-apply-updates.timer` was enabled and scheduled from 11:00 UTC with up to 30 minutes of jitter;
- no failed systemd units remained after first boot;
- both SSH identities, the `/data/coolify` bind mount, a worker-state marker
  under `/var/lib/coolify`, and a marker written into a named Docker volume
  under `/var/lib/docker` survived the registry switch, update, and rollback
  reboots.

The GitHub-hosted lifecycle validates a registry-backed bootc switch to v1, an update to a visibly different v2 image, and rollback to v1. The same Docker volume marker survives all three reboots and SELinux remains enforcing. A separate ordinary reboot is omitted because the registry switch exercises the same persistence boundary.

The same role-aware tooling supports a controller QCOW2 and validates its real
Coolify Compose bootstrap. It records hashes rather than values for the generated
environment and controller private key, checks the complete running service set, and
requires those hashes, persistent markers, the `/data/coolify` bind mount, and the
`container_file_t` label to survive the registry switch, update, and rollback reboots.
It omits a separate ordinary reboot because the registry switch exercises the same
persistence boundary. The full hosted KVM lifecycle passed, including initial bootstrap,
switch to v1, update to v2, and rollback to v1. Coolify's one-time SSH-key import inbox
may be consumed after bootstrap, so the controller preserves a separate canonical
identity and proves that it is neither rotated nor re-imported across those transitions.

The tests discovered and fixed systemd ordering cycles in both role-specific bootstrap
services. They run after `cloud-final.service` as dependencies of `cloud-init.target`,
which lets first-boot provisioning finish without creating a cycle through
`multi-user.target`. Cloud-init root filesystem resizing is disabled because bootc's
grow service owns that operation for composefs-backed deployments.

## Reproduce

Controller:

```bash
make image-controller
make validate-disk-controller
make vm-init-controller
make vm-start-controller
make vm-validate-controller
make vm-registry-start-controller
make vm-update-rollback-controller
```

Worker:

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

Use the corresponding `*-controller` targets for the controller. Controller and worker
defaults use separate VM directories, names, SSH ports, registry names, and registry
ports, so both harnesses can coexist.

## Controller-to-worker integration

The **Validate local Coolify integration** workflow builds both disks on one
GitHub-hosted KVM runner and boots the guests together. It runs on changes to its
harness and can be dispatched manually for an end-to-end production-readiness check.
It exposes only loopback test ports on the runner, enrolls the controller's public
key on the worker, and proves strict host-key-checked SSH from the controller guest
to the worker guest.

The harness uses Coolify's production root-user seeder only inside the disposable
controller. It creates a one-hour API token limited to `read`, `write`, and `deploy`,
registers and validates the worker through the documented Coolify API, and deploys a
digest-pinned BusyBox HTTP service through Coolify. A successful run must retrieve the
expected response through the worker's forwarded application port and find the
Coolify-managed container on the worker. The generated password, API token, VMs, and
application are discarded with the runner and are not stored in GitHub secrets or
artifacts.

With both role disks already built, the equivalent local sequence is:

```bash
make vm-init-controller vm-init-worker
VM_HOST_FORWARD_PORT=8000 VM_GUEST_FORWARD_PORT=8000 make vm-start-controller
VM_HOST_FORWARD_PORT=8081 VM_GUEST_FORWARD_PORT=8080 VM_MEMORY_MB=3072 make vm-start-worker
make vm-validate-controller vm-validate-worker
make vm-integration
make vm-stop-controller vm-stop-worker
```

## Remaining AWS validation

The local registry is deliberately unauthenticated and permits HTTP only on the disposable QEMU host gateway. It proves bootc lifecycle mechanics, not ECR authentication. The EC2 lifecycle must repeat the test using a published, authenticated ECR reference.

ARM64/Graviton boot behavior and EC2-specific cloud-init, IMDS, ENA, NVMe, and EBS growth also remain untested.
