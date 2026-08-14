# Coolify bootc appliance for AWS

This repository builds an image-mode Linux appliance for a small Coolify deployment on EC2. The first implemented milestone is the worker: an AlmaLinux 10 bootc host with Docker Engine, Compose, SSH, cloud-init, SELinux policy, and persistent Docker storage.

> [!WARNING]
> AlmaLinux's bootc images are experimental upstream. Running Coolify on a custom bootc appliance is also not an officially documented Coolify deployment model. Treat the current repository as development work until boot, update, rollback, persistence, and Coolify integration have been exercised on real EC2 instances.

## Architecture and ownership

The eventual deployment has two independently sized roles:

```text
Internet ──80/443──> controller (Coolify management plane)
                         │
                         └──private VPC SSH──> worker (application Docker workloads)
                                                   ▲
Internet ───────────────────────80/443──────────────┘
```

Application traffic goes directly to the worker that hosts the application. It does not pass through the controller.

Responsibility is deliberately split:

| Concern | Owner | Persistent location |
|---|---|---|
| Kernel, Docker, SSH, systemd, host utilities | bootc image built from Git | bootc deployments |
| Docker images, volumes, and application data | Docker/Coolify | `/var/lib/docker` |
| Coolify database, configuration, and generated keys | Coolify controller (planned) | `/data/coolify` backed by persistent host storage |
| Credentials and private keys | Runtime/AWS secret mechanisms | Never the Git repository or OS image |

Coolify itself will remain containerized and retain its own update lifecycle. An OS build must not contain live Coolify state or make a Coolify application upgrade necessary.

## Current status

Implemented:

- shared AlmaLinux 10 bootc base using Docker's official RHEL repository;
- worker image target for both arm64 and amd64 base manifests;
- Docker data root fixed explicitly at `/var/lib/docker`;
- key-only root SSH suitable for Coolify remote management;
- idempotent runtime installation of a Coolify public key;
- cloud-init and lightweight repository/image checks;
- pinned unified image-builder workflow for local QCOW2 and AWS disk artifacts;
- containerized KVM/QEMU lifecycle validation with disposable NoCloud credentials;
- bootc-native unattended OS updates scheduled from 11:00 UTC daily;
- pull-request validation that builds and runs `bootc container lint`.

The upstream base currently makes `bootc` and `rpm-ostree` depend on Podman, so Podman remains installed. It is a bootc host dependency/tool, not the production application runtime; Coolify workloads use Docker Engine.

Next milestones are bootc update/rollback testing through a reachable registry, the persistent controller bootstrap, Terraform/ECR/OIDC, and EC2 AMI registration. No untested AWS deployment code is presented as complete.

## Why bootc

bootc treats a container image as the source for the host operating system. Host package and configuration changes are made in `Containerfile`, built as an OCI image, staged atomically on a machine, and activated at reboot. A previous deployment remains available for rollback.

The immutable boundary matters:

```text
OS software and configuration  -> image
Application and Coolify state  -> persistent filesystem
Coolify workloads              -> Docker
Secrets                         -> runtime/AWS mechanisms
```

Do not use runtime `dnf install` as normal configuration management. Add required host software to the image and rebuild it.

## Repository layout

```text
Containerfile                 shared and role-specific image stages
roles/common/                 Docker, SSH, systemd, and filesystem policy
roles/worker/                 worker-only systemd configuration
scripts/build.sh              local image build
scripts/bootstrap-worker.sh   idempotent public-key provisioning
scripts/validate-image.sh     bootc and package validation
scripts/build-disk.sh         privileged qcow2/AMI artifact generation
image/                        pinned upstream image-builder configuration
ci/                           pinned, sudo-free hosted CI tooling
tests/                        lightweight behavior and policy assertions
.github/workflows/            pull-request validation
AGENTS.md                     AWS Agent Toolkit project guidance
proposal.md                   full implementation plan and milestones
```

## Remote-first validation

GitHub Actions is the primary build and test environment. Every pull request and push to `main` runs:

1. ShellCheck, static behavior tests, and actionlint;
2. an amd64 worker OCI build plus `bootc container lint`;
3. a privileged QCOW2 conversion inside the pinned CI tooling container;
4. QCOW2 consistency checks;
5. a UEFI guest boot, cloud-init and SSH checks, and Docker-volume persistence across reboot.

The workflow installs nothing onto the hosted runner and does not use host `sudo`. If `/dev/kvm` is available it uses KVM; otherwise it falls back to QEMU TCG. GitHub documents nested virtualization on hosted runners as experimental, so the TCG path is the portable fallback. Build artifacts stay within the ephemeral job and are not uploaded, avoiding persistent storage cost and accidental publication of disposable SSH identities.

Local commands remain available for development and diagnosis, but a successful local run is not a substitute for the required GitHub checks.

## Build and validate locally

Requirements are a running Podman or Docker daemon, Bash, Make, jq, OpenSSH tools, and ShellCheck.

```bash
make lint
make test
make build-worker
make validate
```

The default image name is `localhost/coolify-bootc-worker:dev`. Override the engine, architecture, base, or image name without editing the build script:

```bash
CONTAINER_ENGINE=docker \
ARCH=arm64 \
BASE_IMAGE=quay.io/almalinuxorg/almalinux-bootc:10 \
IMAGE_NAME=example/coolify-bootc-worker:test \
./scripts/build.sh worker
```

The `:10` base tag was verified as a multi-architecture index when this milestone was implemented. Because it is mutable, release builds should record and promote tested digests; production hosts must not blindly follow it or a `latest` application tag.

## Build a bootable disk artifact

The current upstream path is the unified osbuild `image-builder`; standalone `bootc-image-builder` is deprecated for new integrations. The builder runs privileged through `run0`, consumes the worker from local Podman storage, and is pinned by digest in `image/image-builder.env`.

Build a local VM disk first:

```bash
make image-worker
make validate-disk-worker
```

After VM boot and persistence testing succeeds, generate an AWS-format disk artifact:

```bash
make ami-worker
```

Artifacts are placed under `image-output/` and ignored by Git. An `.ami` artifact is not an EC2 AMI: it still requires controlled S3 upload and EC2 VM Import/Export registration. This command does neither and receives no AWS credentials. See [image/README.md](image/README.md) for the boundary.

## Boot and test the worker locally

The pinned image-builder container also supplies QEMU and OVMF, so the host only needs Podman, KVM access, `qemu-img`, `xorriso`, and OpenSSH. The VM uses an overlay over the generated worker QCOW2 and a NoCloud seed containing two disposable public keys.

```bash
make vm-init-worker
make vm-start-worker
make vm-validate-worker
```

Validation checks cloud-init, separate administrator and Coolify SSH authentication, Docker, Compose, bootc, enforcing SELinux, the unattended-update timer, and a Docker volume marker across a real guest reboot. The VM remains running on `127.0.0.1:2222` afterward for inspection:

```bash
ssh -p 2222 -i image-output/vm/admin root@127.0.0.1
make vm-stop-worker
make vm-clean-worker
```

`vm-clean-worker` deletes only generated files under `image-output/vm/`. Exact results and current limitations are recorded in [docs/local-vm-validation.md](docs/local-vm-validation.md).

## Worker SSH provisioning

Coolify requires root SSH access to a remote Docker host. Password authentication is disabled. The selected first-boot mechanism is cloud-init user data containing only Coolify's **public** key. The image's oneshot service validates and appends it without replacing existing administrator keys.

```yaml
#cloud-config
write_files:
  - path: /etc/coolify-worker/authorized_keys
    owner: root:root
    permissions: '0600'
    content: |
      ssh-ed25519 REPLACE_WITH_COOLIFY_PUBLIC_KEY coolify
```

The service runs after `cloud-final.service`. Reboots are safe: existing keys are retained and exact duplicates are not added. Never put a private key in user data, Git, an AMI, or Terraform configuration. EC2 user data should not be treated as a secret store even though this payload is only a public key.

The worker also accepts an EC2 administrator key provisioned independently by cloud-init. AWS security groups must restrict TCP/22 to the controller security group/private VPC path and, if needed, a specific administrator CIDR. Do not expose SSH to `0.0.0.0/0`.

## Persistence and SELinux

`/var/lib/docker` is conventional mutable host storage and remains outside bootc's immutable `/usr` deployment. Docker's data root is explicit in `daemon.json`, and the standard `container-selinux` policy is installed. SELinux is not disabled or made permissive.

This establishes the intended persistence boundary, but a successful image build is not proof of upgrade safety. Before production use, a VM/EC2 lifecycle test must:

1. write data into a Docker volume;
2. stage a visibly different bootc deployment;
3. reboot and verify the data;
4. roll back and reboot;
5. verify the same data and enforcing SELinux state again.

## Unattended OS updates

`bootc-fetch-apply-updates.timer` is enabled in the image. It is due daily at 11:00 UTC with up to 30 minutes of randomized delay and is persistent across downtime. Its upstream service runs `bootc upgrade --apply --quiet`: if the tracked image changed, bootc stages it and reboots into the new deployment. Coolify's containers are not upgraded by this timer and retain their separate application lifecycle.

The local QCOW2 tracks `localhost/coolify-bootc-worker:dev`, which is intentionally not reachable as a registry from inside the guest. Local update/rollback validation therefore requires a test registry, and production requires switching the host to a published, authenticated ECR reference. Do not treat the enabled timer alone as proof that registry authentication or rollback works.

Inspect the schedule and update state with:

```bash
systemctl list-timers bootc-fetch-apply-updates.timer
systemctl status bootc-fetch-apply-updates.service
bootc status
```

## Operations

Useful first-line diagnostics are:

```bash
systemctl status docker sshd
journalctl -u docker
bootc status
docker ps
docker info
df -h /var/lib/docker
getenforce
```

Automatic OS reboots are enabled for changed bootc images in the daily update window. Release promotion must still build, test, and publish a candidate before moving the tracked production reference. Exact recovery and rollback runbooks will be added after a two-version lifecycle test rather than guessed in advance.

## AWS direction

The AWS layer will use configurable architecture, region, instance types, encrypted gp3 volumes, separate controller/worker security groups, instance profiles, and public plus private VPC addressing. GitHub Actions will publish to ECR through OIDC—not long-lived AWS keys. AMIs will be generated separately from OCI images with upstream bootc tooling and explicitly selected by Terraform.

The cost-sensitive baseline has:

- no NAT Gateway;
- no EKS;
- no ECS or Fargate;
- no RDS by default;
- no ALB by default;
- no Route 53 requirement.

Those services can be added later only when a concrete operational requirement justifies their cost and complexity. External DNS is expected to point the Coolify hostname at the controller and application hostnames at the relevant worker.

ARM64/Graviton is preferred when every required application image is multi-architecture. AMD64 remains available for maximum third-party image compatibility. Production x86 emulation on ARM is not enabled implicitly.

See [proposal.md](proposal.md) for the complete staged implementation and acceptance criteria.

## License

Repository-authored source and configuration are licensed under AGPL-3.0-only. Packaged operating-system and container-runtime components retain their respective upstream licenses.
