# Coolify bootc appliance for AWS

This repository builds an image-mode Linux appliance for a small Coolify deployment on EC2. The implemented worker is an AlmaLinux 10 bootc host with Docker Engine, Compose, SSH, cloud-init, SELinux policy, and persistent Docker storage. A controller image foundation now exists, but its Coolify bootstrap is still planned.

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
- controller-only persistent, writable `/nix` mount prepared for a future Determinate Nix installation;
- worker image target for both arm64 and amd64 base manifests;
- Docker data root fixed explicitly at `/var/lib/docker`;
- key-only root SSH suitable for Coolify remote management;
- idempotent runtime installation of a Coolify public key;
- cloud-init and lightweight repository/image checks;
- pinned unified image-builder workflow for local QCOW2 and AWS disk artifacts;
- containerized KVM/QEMU lifecycle validation with disposable NoCloud credentials;
- two-version registry-backed bootc update and rollback validation with Docker data preserved;
- bootc-native unattended OS updates scheduled from 11:00 UTC daily;
- pull-request validation that builds and runs `bootc container lint`;
- Terraform-compatible OpenTofu modules for immutable ECR repositories and branch-restricted GitHub Actions OIDC publishing;
- a three-AZ VPC with public/private subnets, optional NAT Gateways, tiered security groups, and VPC Flow Logs;
- an empty controller runtime secret, dedicated rotating KMS key, and least-privilege EC2 instance profile, with no secret value in OpenTofu state.
- a private, auto-expiring AMI import bucket and least-privilege GitHub/VM Import roles for disposable compatibility tests.

The upstream base currently makes `bootc` and `rpm-ostree` depend on Podman, so Podman remains installed. It is a bootc host dependency/tool, not the production application runtime; Coolify workloads use Docker Engine.

Next milestones are authenticated ECR image publication, disposable AWS AMI import validation, persistent controller bootstrap, and EC2 launch templates. No untested AWS deployment code is presented as complete.

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
roles/controller/             controller-only persistent Nix mount foundation
roles/worker/                 worker-only systemd configuration
tofu/                         AWS network, runtime identity, secrets, ECR, and OIDC bootstrap
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

GitHub Actions is the primary build and test environment. Every pull request runs the lightweight and infrastructure checks below. Worker-impacting pull requests, every push to `main`, and every manual run execute the complete image lifecycle:

1. OpenTofu formatting, validation, and mocked infrastructure tests in a pinned Nix environment;
2. ShellCheck, static behavior tests, and actionlint;
3. separate amd64 controller and worker OCI builds plus `bootc container lint`;
4. controller image assertions for the controller-only persistent Nix mount;
5. a privileged worker QCOW2 conversion inside the pinned CI tooling container;
6. QCOW2 consistency checks;
7. a UEFI worker guest boot, cloud-init and SSH checks, and Docker-volume persistence across reboot;
8. a two-version bootc update and rollback through a disposable guest-reachable registry, with the same Docker data verified after each reboot.

The OpenTofu job installs Determinate Nix through a commit-pinned action. Image jobs install no packages onto the hosted runner. The worker job uses host `sudo` only for GitHub's documented udev rule granting access to the runner's existing `/dev/kvm` device; a repository test rejects every other workflow use of `sudo`. KVM accelerates the complete VM lifecycle without removing any reboot, update, or rollback checks, while QEMU TCG remains the automatic fallback. Build artifacts stay within the ephemeral job and are not uploaded, avoiding persistent storage cost and accidental publication of disposable SSH identities.

For pull requests, the worker lifecycle runs whenever a changed path may affect the worker image or its test harness. It is skipped only when all changes are limited to documentation, OpenTofu, Nix metadata used by OpenTofu, or controller-only role files. Pushes to `main` and manual runs always execute the full lifecycle, so an unknown or newly added path defaults to the safer full validation.

Local commands remain available for development and diagnosis, but a successful local run is not a substitute for the required GitHub checks.

## Build and validate locally

Requirements are a running Podman or Docker daemon, Bash, Make, jq, OpenSSH tools, and ShellCheck.

```bash
make lint
make test
make build-controller
make build-worker
make validate
nix develop --command make tofu-check
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

## Controller Nix storage foundation

Only the controller image contains an empty native `/nix` directory. At boot, `nix.mount` bind-mounts persistent `/var/lib/nix` at `/nix`; the worker image contains neither this mount nor Nix-specific state. This keeps the Nix store outside the bootc deployment without modifying the immutable root at runtime.

Nix is not installed in the image. The current Determinate Nix Installer's [OSTree planner](https://github.com/DeterminateSystems/nix-installer/blob/main/src/planner/ostree.rs) supports an explicit persistence path and installs its SELinux policy while SELinux remains enforcing. A future booted-controller bootstrap should select that planner with `/var/lib/nix`; `install linux --init none` does not expose the persistence option and is not used here. The controller VM test must confirm that `/nix` is a writable mount, then confirm its contents survive reboot, bootc update, and rollback before the controller milestone is considered complete.

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
make vm-registry-start-worker
make vm-update-rollback-worker
```

Validation checks cloud-init, separate administrator and Coolify SSH authentication, Docker, Compose, bootc, enforcing SELinux, the unattended-update timer, and a Docker volume marker across a real guest reboot. The VM remains running on `127.0.0.1:2222` afterward for inspection:

```bash
ssh -p 2222 -i image-output/vm/admin root@127.0.0.1
make vm-registry-stop-worker
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

The service runs after `cloud-final.service`. Reboots are safe: existing keys are retained and exact duplicates are not added. Never put a private key in user data, Git, an AMI, or OpenTofu configuration. EC2 user data should not be treated as a secret store even though this payload is only a public key.

The worker also accepts an EC2 administrator key provisioned independently by cloud-init. AWS security groups must restrict TCP/22 to the controller security group/private VPC path and, if needed, a specific administrator CIDR. Do not expose SSH to `0.0.0.0/0`.

## Persistence and SELinux

`/var/lib/docker` is conventional mutable host storage and remains outside bootc's immutable `/usr` deployment. Docker's data root is explicit in `daemon.json`, and the standard `container-selinux` policy is installed. SELinux is not disabled or made permissive.

The local lifecycle test establishes the intended persistence boundary by:

1. writing data into a Docker volume;
2. switching to a v1 image in a disposable local registry and staging a visibly different v2 bootc deployment;
3. rebooting and verifying the data;
4. rolling back and rebooting;
5. verifying the same data and enforcing SELinux state again.

The registry permits HTTP only on the QEMU host gateway for this disposable test. Production images do not contain that exception and must use authenticated HTTPS ECR references.

## Unattended OS updates

`bootc-fetch-apply-updates.timer` is enabled in the image. It is due daily at 11:00 UTC with up to 30 minutes of randomized delay and is persistent across downtime. Its upstream service runs `bootc upgrade --apply --quiet`: if the tracked image changed, bootc stages it and reboots into the new deployment. Coolify's containers are not upgraded by this timer and retain their separate application lifecycle.

The local QCOW2 initially tracks a local container-storage reference. The lifecycle harness switches it to explicit `lifecycle-v1` and `lifecycle-v2` tags in a disposable registry reachable only through the QEMU host gateway, then performs a real rollback. Production still requires switching the host to a published, authenticated ECR reference and validating registry authentication on EC2.

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

The AWS layer uses configurable architecture, region, and instance types. The initial target is AMD64 with `t3a.small` for the controller and `t3a.large` for the worker; ARM64 is deferred until the first AWS deployment path is proven. GitHub Actions will publish to ECR through OIDC, not long-lived AWS keys. AMIs will be generated separately from OCI images with upstream bootc tooling and explicitly selected by OpenTofu.

Networking spans three Availability Zones by default and provides public and isolated private subnets, DNS support, tiered security groups, and 90-day VPC Flow Logs. The initial two-node deployment puts the controller and worker in public subnets with one Elastic IP each. It uses private VPC addresses for controller-to-worker SSH and exposes only the required public service ports. NAT Gateways and an ALB are not justified for the expected five-to-ten-person, low-traffic workload and remain disabled.

OpenTofu is the infrastructure-as-code CLI for this project. Configuration remains Terraform-compatible where practical so the AWS provider and reusable modules retain broad ecosystem compatibility. Terraform is reserved for a documented incompatibility that cannot be resolved with OpenTofu. CI-only values belong in GitHub Secrets, AWS-hosted runtime secrets belong in AWS Secrets Manager, and provider-neutral or self-hosted secrets may use OpenBao.

The AWS stack creates one empty bundled controller-runtime secret, a dedicated rotating KMS key, and a controller EC2 instance profile scoped to that secret and key. OpenTofu never receives the secret value. The future EC2 bootstrap must resolve individual JSON keys at runtime through the repository-mandated `asm-exec` dynamic-reference flow. An approved `asm-exec` source is not yet present, so secret consumption is not claimed as implemented.

OpenTofu cannot safely replace a secret store because a managed secret value would enter its state. Running OpenBao only for this deployment would add more state, backup work, and availability risk than the single AWS secret warrants, so Secrets Manager remains the initial choice. OpenBao can replace it later if provider independence becomes an operational requirement.

The infrastructure intentionally has:

- direct public EC2 ingress with stable Elastic IPs;
- NAT Gateways disabled by default;
- no EKS;
- no ECS or Fargate;
- no RDS by default;
- no ALB by default;
- no Route 53 requirement.

Those services can be added later only when a concrete operational requirement justifies their cost and complexity. External DNS will point the controller hostname to its Elastic IP and application hostnames to the worker Elastic IP.

AMD64 is preferred for the first deployment and maximum third-party image compatibility. ARM64/Graviton remains a future optimization when every required application image is multi-architecture. Production x86 emulation on ARM is not enabled implicitly.

The AWS foundation is implemented under [`tofu/`](tofu/README.md). Its first apply creates immutable scanned ECR repositories, branch-restricted GitHub identities, and disposable AMI import resources. Networking and the empty encrypted controller secret are feature-gated until the AMI is accepted and EC2 deployment begins. The stack deliberately does not deploy instances or require AWS credentials during pull-request artifact validation. An authorized operator must perform the initial bootstrap apply, then manual import validation can use OIDC without storing AWS access keys in GitHub.

See [proposal.md](proposal.md) for the complete staged implementation and acceptance criteria.

## License

Repository-authored source and configuration are licensed under AGPL-3.0-only. Packaged operating-system and container-runtime components retain their respective upstream licenses.
