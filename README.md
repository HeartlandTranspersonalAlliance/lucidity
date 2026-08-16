# Coolify bootc appliance for AWS

This repository builds an image-mode Linux appliance for a small Coolify deployment on EC2. The worker is an AlmaLinux 10 bootc host with Docker Engine, Compose, SSH, cloud-init, SELinux policy, and persistent Docker storage. The controller image adds persistent Coolify storage and an idempotent first-boot bootstrap. Both roles pass the complete hosted KVM switch, update, and rollback lifecycle; the controller's EC2 lifecycle still needs validation.

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
| Coolify database, configuration, and generated keys | Coolify controller | `/data/coolify` bound to `/var/lib/coolify` |
| Credentials and private keys | Runtime/AWS secret mechanisms | Never the Git repository or OS image |

Coolify itself will remain containerized and retain its own update lifecycle. An OS build must not contain live Coolify state or make a Coolify application upgrade necessary.

## Current status

Implemented:

- shared AlmaLinux 10 bootc base using Docker's official RHEL repository;
- native `/nix` mountpoint present in both roles for a future Determinate Nix OSTree installation;
- targeted SELinux policy packages and an explicit enforcing configuration in both roles;
- AWS Systems Manager Agent enabled in both roles for shell access without public SSH;
- worker image target for both arm64 and amd64 base manifests;
- Docker data root fixed explicitly at `/var/lib/docker`;
- key-only root SSH suitable for Coolify remote management;
- idempotent runtime installation of a Coolify public key;
- controller storage persisted under `/var/lib/coolify` and bind-mounted at Coolify's required `/data/coolify` path;
- an idempotent controller bootstrap that preserves its environment and SSH identity across ordinary boots;
- a narrowly scoped persistent `container_file_t` rule for the Coolify tree while SELinux remains enforcing;
- checksum-pinned AWS `asm-exec` and AWS Workload Credentials Provider sources for runtime-only controller secret resolution;
- cloud-init and lightweight repository/image checks;
- pinned unified image-builder workflow for local QCOW2 and AWS disk artifacts;
- containerized KVM/QEMU lifecycle validation with disposable NoCloud credentials;
- two-version registry-backed bootc update and rollback validation with Docker data preserved;
- bootc-native unattended OS updates scheduled from 11:00 UTC daily;
- pull-request validation that builds and runs `bootc container lint`;
- Terraform-compatible OpenTofu modules for immutable ECR repositories and branch-restricted GitHub Actions OIDC publishing;
- an account-regional, versioned, encrypted S3 remote-state bootstrap with native locking and private S3 access logs;
- a three-AZ VPC with public/private subnets, optional NAT Gateways, tiered security groups, and VPC Flow Logs;
- an empty controller runtime secret, dedicated rotating KMS key, and least-privilege EC2 instance profile, with no secret value in OpenTofu state.
- a dedicated AMI snapshot KMS key and EBS Direct API upload path for disposable validation and retained releases.
- manually gated retained controller and worker AMI release gates, hardened launch templates that require explicit self-owned AMI IDs, and an explicitly enabled two-node deployment with stable Elastic IPs.
- immutable semantic releases that bind both tested ECR digests, SPDX SBOMs, and role-specific retained AMIs in one checksummed manifest.

The upstream base currently makes `bootc` and `rpm-ostree` depend on Podman, so Podman remains installed. It is a bootc host dependency/tool, not the production application runtime; Coolify workloads use Docker Engine.

The disposable AWS snapshot-to-AMI registration and T3a boot gates have passed on
merged `main`. The guest was validated through SSM without a key pair or inbound
SSH, and cleanup removed the instance, AMI, and snapshot. The delivery transport
writes the raw disk directly to EBS. A retained release pulls each role's immutable private ECR candidate for the full
source commit, uses those real registry references as the bootc sources, runs parallel EBS
Direct and T3a/SSM gates, and preserves both validated AMIs and encrypted snapshots. EC2 launch
templates and production instances are defined but remain disabled until exact controller and worker AMI IDs are
selected. The controller bootstrap now passes the full hosted KVM update/rollback
lifecycle with its persistent environment, SSH identity, Compose service set, bind mount,
and SELinux label intact. The controller AMI gate also waits for that bootstrap before
retaining the image. Its launch template now provisions a root-only environment file
containing only Secrets Manager references. The deployment module pins numeric launch
template versions, creates both nodes, and associates stable Elastic IPs. The
deployment plan is covered by mocked OpenTofu tests but remains production-unproven
until a reviewed apply and the Milestone 10 live checks succeed.

Merged-main run `31899706447` measured the 12 GiB EBS Direct upload at about 33
seconds and reached a launchable AMI about 48 seconds after upload began. The complete
upload, registration, boot validation, and cleanup step took 4 minutes 54 seconds;
the previous VM Import phase alone took about 14 minutes.

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
roles/controller/             controller-only host configuration
roles/worker/                 worker-only systemd configuration
tofu/bootstrap/state/         protected S3 remote-state bootstrap
tofu/environments/aws/        AWS network, compute, identity, secrets, ECR, and OIDC stack
scripts/build.sh              local image build
scripts/bootstrap-controller.sh idempotent Coolify initialization
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

GitHub Actions is the primary build and test environment. Every pull request runs the lightweight and infrastructure checks below. Role-impacting pull requests build and validate each affected controller or worker image and disk. The merge queue executes the complete guest lifecycle once for each affected role, while manual and weekly runs exercise both roles:

1. OpenTofu formatting, validation, and mocked infrastructure tests in a pinned Nix environment;
2. codespell, whole-tree whitespace checks, ShellCheck, static behavior tests, and actionlint;
3. separate amd64 controller and worker OCI builds plus `bootc container lint`;
4. controller image assertions for the native `/nix` mountpoint and enforcing SELinux configuration;
5. a privileged worker QCOW2 conversion inside the pinned CI tooling container;
6. QCOW2 consistency checks;
7. on integration runs, UEFI controller and worker guest boots plus cloud-init, service, and SSH checks;
8. registry switches, two-version bootc updates, and rollbacks through disposable guest-reachable registries, with the same persistent state verified after each reboot.

The OpenTofu job installs Determinate Nix through a commit-pinned action. The same pinned development environment supplies codespell, and repository lint checks spelling and tracked-text style across the complete tree. Root EditorConfig rules align editors and CI on LF line endings, final newlines, and trimmed trailing whitespace. Image jobs use the runner's supplied container tools. Lifecycle jobs use host `sudo` for GitHub's documented udev rule granting access to the runner's existing `/dev/kvm` device. AMI jobs use narrowly scoped root Podman commands because osbuild consumes the bootc source through shared root container storage. KVM accelerates every VM test, while QEMU TCG remains the automatic fallback. Build artifacts stay within the ephemeral job. A daily read-only AWS audit reports disposable validation instances, AMIs, or snapshots that remain tagged after 12 hours, covering runner termination cases where an EXIT trap cannot execute.

For pull requests and merge groups, a lightweight `ubuntu-slim` job classifies changed paths before allocating the full VM runners. Documentation, OpenTofu, and role-exclusive changes select only their relevant jobs; unknown, shared, workflow, or classifier changes select both roles. Each selected pull-request role builds and validates a QCOW2. The required serial merge queue runs the affected role's initial boot, update, rollback, and persistence checks against the exact candidate merged with current `main`. A weekly Monday run and manual dispatch exercise both complete lifecycles to detect upstream image drift. Raw AMI compatibility runs on pull requests when its workflow or the shared disk build and validation scripts change. Validation consumes role-scoped GHCR caches read-only, while trusted publication runs refresh those caches with the minimum required token permissions.

Local commands remain available for development and diagnosis, but a successful local run is not a substitute for the required GitHub checks.

After relevant changes merge to `main`, **Publish bootc images** builds and validates
the AMD64 controller and worker images, assumes the repository-scoped AWS role through
GitHub OIDC, and publishes each image under an immutable `sha-<full-commit>` tag. It
verifies the tag digest and remote `linux/amd64` manifest before succeeding. Pull
requests use read-only validation permissions. Stable-channel promotion remains a
separate post-validation operation.

## Immutable releases and SBOMs

`VERSION` seeds the first release at `0.1.0`. Manually dispatch **Release bootc appliance**
from `main` after its required checks pass. The default `auto` bump applies conventional
commit intent since the previous release: a breaking-change marker selects major,
`feat:` selects minor, and other changes select patch. The dispatch also offers explicit
patch, minor, and major overrides when commit history does not express the release impact.

The release workflow calls candidate publication directly as a reusable job with the
exact selected source commit. An existing immutable ECR tag makes this idempotent and
keeps publication inside the release dependency graph with scoped OIDC permissions.
Promotion reuses the tested manifest. Two parallel jobs
copy each tested `sha-<commit>` manifest to its immutable `vX.Y.Z` ECR tag, scan the
exact `repository@sha256:digest` with pinned Syft, produce SPDX JSON, and attest each
SBOM against that digest. Each role's digest and uncompressed SBOM SHA-256 are passed
to parallel retained EBS Direct AMI gates, whose installed bootc deployments track
immutable version tags rather than a mutable channel. After both boot validations, the
workflow creates a schema-v2 manifest binding the version, source commit, controller
and worker OCI digests, SBOM hashes, role-specific AMI and encrypted snapshot IDs, and
workflow evidence.

The GitHub release is created as a draft with the manifest, compressed SBOMs, and their
checksums attached before it is published. Repository release immutability then protects
the Git tag and assets. ECR expires only untagged images, so immutable release tags remain
durable. EC2 copies the release version, source image digest, and SBOM hash onto the AMI
and snapshot for discovery, but those mutable resource tags are not the trust boundary;
the published release manifest, OCI digest, AMI ID, and snapshot ID are authoritative.

## Build and validate locally

Requirements are a running Podman or Docker daemon, Bash, Make, jq, OpenSSH tools, and ShellCheck.

```bash
make lint
make test
make build-controller
make build-worker
make validate-controller
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

## Determinate Nix roadmap

Both images contain an empty native `/nix` directory. This follows the proven Purplefin bootc boundary: the immutable image supplies the mountpoint, while Determinate's installer owns the generated mount, daemon, socket, and SELinux-policy integration. The repository deliberately does not maintain a competing `nix.mount` unit.

Nix installation is a post-AMI milestone for both controller and worker, not a prerequisite for the first AWS boot. Use a reviewed, version-pinned Determinate Nix Installer with its native [OSTree planner](https://github.com/DeterminateSystems/nix-installer/blob/main/src/planner/ostree.rs), an explicit persistent path such as `/var/lib/nix`, and its native SELinux policy action. Do not use the generic Linux planner or disable SELinux. Validation must prove `nix-daemon` works while `getenforce` reports `Enforcing`, and that the store survives reboot, bootc update, rollback, and instance replacement with the intended persistent volume attached.

## Build a bootable disk artifact

The current upstream path is the unified osbuild `image-builder`; standalone `bootc-image-builder` is deprecated for new integrations. The builder runs privileged through `run0`, consumes the selected role image from local Podman storage, and is pinned by digest in `image/image-builder.env`.

Build a local VM disk first:

```bash
make image-controller
make validate-disk-controller
make image-worker
make validate-disk-worker
```

After VM boot and persistence testing succeeds, generate an AWS-format disk artifact:

```bash
make ami-controller
make ami-worker
```

Artifacts are placed under `image-output/` and ignored by Git. An `.ami` artifact is not an EC2 AMI: it still requires upload to an EBS snapshot and explicit EC2 registration. The validation and release path uses the EBS Direct APIs. This command performs no AWS upload and receives no AWS credentials. See [image/README.md](image/README.md) for the boundary.

## Boot and test the roles locally

The pinned image-builder container also supplies QEMU and OVMF, so the host only needs Podman, KVM access, `qemu-img`, `xorriso`, and OpenSSH. Each VM uses an overlay over its generated QCOW2 and a NoCloud seed with a disposable administrator key. The worker seed also includes its separate disposable Coolify key.

For the controller:

```bash
make vm-init-controller
make vm-start-controller
make vm-validate-controller
make vm-registry-start-controller
make vm-update-rollback-controller
```

The controller validation waits for the real Compose bootstrap, verifies every configured service is running, and proves that the generated environment, controller SSH identity, persistent marker, bind mount, and SELinux label survive the registry switch, update, and rollback reboots. The initial validation does not add a redundant ordinary reboot. It rejects relevant SELinux AVC denials. The controller VM listens on `127.0.0.1:2223` and uses `image-output/vm-controller/`.

For the worker:

```bash
make vm-init-worker
make vm-start-worker
make vm-validate-worker
make vm-registry-start-worker
make vm-update-rollback-worker
```

Validation checks cloud-init, separate administrator and Coolify SSH authentication, Docker, Compose, bootc, enforcing SELinux, the unattended-update timer, and a Docker volume marker across the registry switch, update, and rollback reboots. The VM remains running on `127.0.0.1:2222` afterward for inspection:

```bash
ssh -p 2222 -i image-output/vm/admin root@127.0.0.1
make vm-registry-stop-worker
make vm-stop-worker
make vm-clean-worker
```

`vm-clean-worker` deletes only generated files under `image-output/vm/`. Exact results and current limitations are recorded in [docs/local-vm-validation.md](docs/local-vm-validation.md).

Use `make vm-registry-stop-controller`, `make vm-stop-controller`, and
`make vm-clean-controller` for the controller. These commands affect only the
controller's disposable registry, VM container, and generated files under
`image-output/vm-controller/`.

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

The worker also accepts an EC2 administrator key in the local VM test harness. AWS administration uses Systems Manager Session Manager instead: there is no public TCP/22 rule. The only EC2 SSH path is controller-to-worker over private VPC addresses because Coolify requires it. Do not expose SSH to an administrator CIDR or `0.0.0.0/0`.

## Persistence and SELinux

`/var/lib/docker` is conventional mutable host storage and remains outside bootc's immutable `/usr` deployment. Docker's data root is explicit in `daemon.json`, the standard `container-selinux` and targeted policy packages are installed, and `/etc/selinux/config` requires enforcing mode. The booted-VM test rejects anything other than `Enforcing`.

Coolify officially lists AlmaLinux among its supported Red Hat-family hosts, but its current production Compose file uses `/data/coolify` bind mounts without SELinux relabel flags. The controller image adds a persistent, narrowly scoped `container_file_t` file-context rule for the required `/data/coolify` tree, and the bootstrap runs `restorecon` before starting Coolify. An end-to-end test must still reject AVC denials; disabling or weakening SELinux is not an accepted workaround.

The controller implements that boundary with a systemd-managed bind mount from
`/var/lib/coolify` to `/data/coolify`. Its bootstrap downloads the official Compose,
production override, environment template, and upgrade scripts only when absent. It
fills empty initial secret fields, creates the controller SSH identity and attachable
Docker network only when needed, reapplies the SELinux label, and runs Compose without
overwriting a working installation. It pulls application images on initial installation
and uses locally cached images on subsequent OS boots, keeping Coolify upgrades separate
from the bootc lifecycle. Lightweight tests prove a second run preserves the environment
and SSH identity. The controller VM harness extends those assertions across the
registry switch, bootc update, and rollback reboots, and the full hosted KVM run passes.
The disposable EC2 gate is still required before this persistence path is considered
production-proven.

The local lifecycle test establishes the intended persistence boundary by:

1. writing data into a worker Docker volume or the controller's persistent Coolify tree;
2. switching to a v1 image in a disposable local registry and staging a visibly different v2 bootc deployment;
3. rebooting and verifying the data;
4. rolling back and rebooting;
5. verifying the same data and enforcing SELinux state again. For the controller it
   also compares hashes of the generated environment and private key and requires the
   same complete Compose service set after every deployment change.

The registry permits HTTP only on the QEMU host gateway for this disposable test. Production images do not contain that exception and must use authenticated HTTPS ECR references.

## Unattended OS updates

`bootc-fetch-apply-updates.timer` is enabled in the image. It is due daily at 11:00 UTC with up to 30 minutes of randomized delay and is persistent across downtime. Its upstream service runs `bootc upgrade --apply --quiet`: if the tracked image changed, bootc stages it and reboots into the new deployment. Coolify's containers are not upgraded by this timer and retain their separate application lifecycle.

The local QCOW2 initially tracks a local container-storage reference. The lifecycle harness switches it to explicit `lifecycle-v1` and `lifecycle-v2` tags in a disposable registry reachable only through the QEMU host gateway, then performs a real rollback. Production still requires switching the host to a published, authenticated ECR reference and validating registry authentication on EC2.

For private ECR, the image builds the official Amazon ECR credential helper v0.12.0
from checksum-pinned source. At boot, `coolify-bootc-ecr-auth.service` reads the fully
qualified registry from `bootc status`, validates that it is a private ECR hostname,
and atomically writes a mode-0600 `/run/ostree/auth.json` that references
`docker-credential-ecr-login`. No registry password or 12-hour authorization token is
stored in the image or on persistent disk. The helper obtains short-lived credentials
from the EC2 instance profile, whose policy is restricted to the matching controller
or worker repository. The service runs before `bootc-fetch-apply-updates.service`.

Disposable local-registry images intentionally do not create this file. The retained
AMI gate must verify the installed ECR reference and a successful authenticated
`bootc upgrade --check` before EC2 deployment is declared complete.

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

Automatic OS reboots are enabled for changed bootc images in the daily update window. Release promotion must still build, test, and publish a candidate before moving the tracked production reference. The two-version lifecycle is proven in hosted KVM. The [AWS node recovery runbook](docs/node-recovery.md) defines the backup boundary, isolated restore drill, retained-volume handling, and production cutover; its recovery-time objective remains unset until both AWS restore drills pass.

## AWS direction

The AWS layer uses configurable architecture, region, and instance types. The initial target is AMD64 with `t3a.small` for the controller and `t3a.large` for the worker; ARM64 is deferred until the first AWS deployment path is proven. GitHub Actions publishes immutable candidates to ECR through OIDC, not long-lived AWS keys. AMIs are generated separately from OCI images with upstream bootc tooling and explicitly selected by OpenTofu.

Networking spans three Availability Zones by default and provides public and isolated private subnets, DNS support, tiered security groups, and 90-day VPC Flow Logs. The initial two-node deployment puts the controller and worker in public subnets with one Elastic IP each. It uses private VPC addresses for controller-to-worker SSH and exposes only the required public service ports. NAT Gateways and an ALB are not justified for the expected five-to-ten-person, low-traffic workload and remain disabled. Optional [node monitoring](docs/node-monitoring.md) adds only EC2 status, CPU, and burst-credit alarms with encrypted email delivery; paid EC2 detailed monitoring stays off because those alarms use metrics already included with basic monitoring.

OpenTofu is the infrastructure-as-code CLI for this project. Configuration remains Terraform-compatible where practical so the AWS provider and reusable modules retain broad ecosystem compatibility. Terraform is reserved for a documented incompatibility that cannot be resolved with OpenTofu. CI-only values belong in GitHub Secrets, AWS-hosted runtime secrets belong in AWS Secrets Manager, and provider-neutral or self-hosted secrets may use OpenBao.

The AWS stack creates one empty bundled controller-runtime secret, a dedicated rotating KMS key, and a controller EC2 instance profile scoped to that secret and key. OpenTofu never receives the secret value. The controller image builds AWS Workload Credentials Provider 3.1.1 from checksum-pinned source and installs AWS's checksum-pinned `asm-exec`. The controller launch template's cloud-init data writes `/etc/coolify-controller/runtime-secrets.env` with seven dynamic references and mode `0600` before `cloud-final.service` completes; it contains no resolved secret. The bootstrap wrapper rejects plaintext and resolves those references only at runtime through the instance role. Populate all seven JSON values through an out-of-band operator workflow before launching production EC2.

OpenTofu cannot safely replace a secret store because a managed secret value would enter its state. Running OpenBao only for this deployment would add more state, backup work, and availability risk than the single AWS secret warrants, so Secrets Manager remains the initial choice. OpenBao can replace it later if provider independence becomes an operational requirement.

The infrastructure intentionally has:

- direct public EC2 ingress with stable Elastic IPs;
- NAT Gateways disabled by default;
- no EKS;
- no ECS or Fargate;
- no RDS by default;
- no ALB by default;
- no Route 53 requirement.

Those services can be added later only when a concrete operational requirement justifies their cost and complexity. Cloudflare DNS points the controller hostname to its Elastic IP and all application hostnames to the single worker Elastic IP. See the [cost and addressing guide](docs/cost-optimization.md) for the record layout, proxy boundary, and IPv6 decision.

AMD64 is preferred for the first deployment and maximum third-party image compatibility. ARM64/Graviton remains a future optimization when every required application image is multi-architecture. Production x86 emulation on ARM is not enabled implicitly.

The AWS foundation is implemented under [`tofu/`](tofu/README.md). Its first apply creates immutable scanned ECR repositories, branch-restricted GitHub identities, and disposable AMI snapshot validation resources. Networking, the empty encrypted controller secret, launch templates, production instances, and daily node backups are independently gated until retained AMIs are accepted and deployment begins. Pull-request artifact validation does not require AWS credentials. An authorized operator must perform the initial bootstrap apply, then manual snapshot validation can use OIDC without storing AWS access keys in GitHub.

See [proposal.md](proposal.md) for the complete staged implementation and acceptance criteria.

## Publish immutable bootc candidates to ECR

After the OpenTofu foundation is applied, configure these non-secret GitHub repository
variables from its outputs:

| GitHub variable | OpenTofu output |
|---|---|
| `AWS_ECR_PUBLISH_ROLE_ARN` | `github_publish_role_arn` |
| `AWS_ECR_CONTROLLER_REPOSITORY_URL` | `ecr_repository_urls["controller"]` |
| `AWS_ECR_WORKER_REPOSITORY_URL` | `ecr_repository_urls["worker"]` |

The publishing workflow runs only for `main`, uses short-lived OIDC credentials, and
does not require AWS access-key secrets. Every published controller and worker image
uses `sha-<full-commit>` so the repository's immutable-tag policy binds that name to
one digest. A manual rerun retains an existing immutable image instead of attempting
to overwrite it.

The ECR repositories reserve `stable` as their only mutable channel, but candidate
publication deliberately does not update it. Add promotion only after a candidate has
passed the corresponding boot test, and retain its immutable SHA tag and digest for
rollback.

## License

Repository-authored source and configuration are licensed under AGPL-3.0-only. Packaged operating-system and container-runtime components retain their respective upstream licenses.
