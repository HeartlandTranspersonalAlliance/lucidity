# AWS bootc Coolify Appliance — Implementation Plan

You are working in a new, empty Git repository connected to a GitHub remote.

Build a reproducible, production-oriented bootc-based AWS appliance for hosting Coolify. The repository should ultimately support two roles built from the same general platform:

1. **Coolify Controller**

   * Runs the Coolify management plane.
   * Should not normally host user applications.
   * Runs on a small EC2 instance.

2. **Coolify Worker**

   * Managed remotely by the Coolify controller over SSH.
   * Runs application containers, databases, services, and the Coolify-managed reverse proxy.
   * Can be independently sized or replicated.

The target environment is AWS EC2.

Do not create a Kubernetes, ECS, Fargate, or Elastic Beanstalk architecture. This is intentionally an EC2 + Docker design.

## Implementation status (2026-08-17)

The repository is no longer empty. The implementation now uses the locked flake as
its authoritative build, infrastructure, test, security, and release graph:

- Den typed entities define the controller and worker; aspects own their payloads and
  unit fixtures, policies own output routing, and classes own evaluation behavior.
- Nix derives both bootc contexts and both Terranix/OpenTofu roots. Duplicate root
  Containerfile, role tree, Makefile, and hand-authored environment root were removed.
- `nix flake check` validates formatting, shell and workflow lint, generated bootc
  policy, SecretSpec contracts, mocked OpenTofu plans, release logic, and the Nebula
  NixOS VM topology. GitHub workflows are thin event, permission, credential, and
  flake-app adapters.
- Operational shell sources are packaged as patched Nix-store executables before a
  flake app can invoke them. All GitHub, Dependabot, and Syft YAML is parsed in the
  check graph, and external Actions must use immutable full commit pins.
- SecretSpec declares local, CI, and AWS Secrets Manager providers. Runtime values do
  not enter Nix evaluation, Git, AMIs, OpenTofu plans, or state.
- The generated AWS foundation includes EBS encryption defaults, public snapshot
  blocking, CloudTrail, AWS Config, GuardDuty, Inspector, Security Hub V2, immutable
  ECR repositories, OIDC roles, SSM management, and dedicated KMS keys.
- `nix run .#architecture` derives a Mermaid namespace graph directly from evaluated
  `den.aspects`; no separately maintained architecture graph is checked in.

The remaining advanced milestones are operational: merge the verified graph, apply
the reviewed foundation plan, publish immutable controller and worker images, create
and validate the missing controller AMI, deploy nodes only after explicit AMI inputs,
and complete backup, recovery, update, rollback, and incident-response drills. The
last live AWS inventory found no production EC2 nodes, launch templates, SSM-managed
nodes, or controller AMI, so the system is not yet production-ready despite the
repository controls being substantially complete.

## Current AWS implementation decisions

The first AWS deployment targets AMD64 with `t3a.small` for the controller and
`t3a.medium` for the worker. ARM64 remains a supported future direction, but it is
deferred until the AMD64 AMI, deployment, recovery, and application compatibility
paths are proven end to end.

The initial deployment uses public subnets and one Elastic IP per EC2 node. It does
not use an ALB or NAT Gateway. The VPC still spans multiple Availability Zones and
retains isolated private subnets, tiered security groups, DNS support, and VPC Flow
Logs so private placement can be enabled later. Both singleton nodes initially share
one Availability Zone to avoid cross-zone transfer charges. NAT Gateways remain an
explicit opt-in for future private-subnet workloads.

There is no public administrator SSH rule. Both nodes use AWS Systems Manager Session
Manager as an independent recovery channel. Ordinary administration and Coolify's
controller-to-worker SSH run over a Nebula overlay. The controller is the lighthouse
and relay, with only UDP/4242 exposed for mesh discovery. Production security groups
contain no TCP/22 rules. Administrator root login, worker-to-controller SSH, and
unspecified overlay traffic are denied. Security-group egress remains allowlisted.

AWS-hosted controller secrets use one bundled AWS Secrets Manager secret encrypted
with a dedicated, rotating customer-managed KMS key. OpenTofu creates only the empty
secret container and a least-privilege policy attached to the controller's shared EC2
instance profile. A flake app generates the complete first version in tmpfs, uploads
it without printing values, and refuses accidental replacement of `AWSCURRENT`.
Values are resolved on the EC2 instance at runtime; they are never placed in an AMI,
OpenTofu configuration, plan, state, or Nix store. The EC2 bootstrap uses the pinned
`asm-exec` package.

OpenTofu is not a secret store and must not receive the runtime value. OpenBao now
provides provider-neutral custody for the encrypted Nebula CA and other material that
must not be AWS-specific. It listens only on controller loopback, uses Raft storage,
and auto-unseals through a dedicated AWS KMS key. SecretSpec defines the provider and
profile contract without placing resolved values in Nix evaluation or the Nix store.

The locked Nix flake is the configuration and validation authority. Den owns host and
role composition, Home Manager owns the administrator profile, Terranix generates
Terraform-compatible OpenTofu JSON, and `nix flake check` is the complete hermetic
quality graph. Developer and CI commands are exposed as flake apps. GitHub workflows
should contain only event, permission, runner preparation, credential-bound cloud
steps, and calls into those apps. They must not recreate the check graph by manually
chaining formatters, linters, Make targets, or individual test scripts.

---

# 1. Core design goals

Implement the project according to these principles:

* bootc/image-mode Linux for the host OS.
* Docker Engine, not Podman, as the production application runtime.
* Host OS configuration is defined in Git and baked into the bootc image.
* Coolify itself remains containerized.
* Coolify application state must not be baked into the bootc image.
* Persistent/mutable application state belongs under persistent host storage.
* OS updates must be atomic and rollback-capable through bootc.
* Coolify updates must remain independent from OS updates.
* Coolify-managed application updates must remain independent from both.
* Infrastructure should be reproducible.
* AWS-specific dependencies should be kept minimal.
* ARM64 and AMD64 should both be supportable where reasonably possible.
* Never store AWS credentials, Coolify secrets, SSH private keys, passwords, or other secrets in Git.
* GitHub Actions should authenticate to AWS using OIDC rather than long-lived AWS access keys.

The lifecycle should conceptually be:

```text
Host OS:
Git
  ↓
GitHub Actions
  ↓
bootc OCI image
  ↓
container registry
  ↓
bootc update
  ↓
reboot
  ↓
new deployment


Coolify:
Coolify containers
  ↓
Coolify's own update mechanism


Applications:
Git repositories
  ↓
Coolify
  ↓
Docker workloads
```

Keep these concerns separated.

---

# 2. Base operating system

Start with:

```text
quay.io/almalinuxorg/almalinux-bootc:10
```

or the correct current AlmaLinux 10 bootc tag discovered from the upstream AlmaLinux bootc project.

Do not blindly hard-code a tag without validating that it currently exists.

Make the base image easy to change using either:

```Dockerfile
ARG BASE_IMAGE=
FROM ${BASE_IMAGE}
```

or an equivalent mechanism supported by the build system.

Document clearly that AlmaLinux bootc images are currently considered experimental upstream.

The implementation should not depend on AlmaLinux-specific behavior where a generic RHEL-family/bootc-compatible solution is practical.

---

# 3. Initial repository structure

The implemented feature-first structure is:

```text
.
├── flake.nix
├── flake.lock
├── README.md
├── LICENSE
├── nix/
│   ├── den/
│   │   ├── entities/
│   │   ├── aspects/
│   │   │   ├── common/
│   │   │   ├── controller/{files,tests}/
│   │   │   └── worker/{files,tests}/
│   │   ├── classes/{bootc,terranix.nix}
│   │   └── policies/
│   ├── flake/{architecture,checks,formatting,outputs,project}.nix
│   ├── infra/{aws,state}.nix
│   ├── home/
│   └── pkgs/
├── scripts/
│   └── hardware/VM and AWS boundary adapters
├── tests/
│   └── cross-cutting integration fixtures
├── tofu/
│   ├── modules/
│   │   ├── account-security-baseline/
│   │   ├── network/
│   │   ├── ecr/
│   │   ├── ec2-launch-templates/
│   │   ├── ec2-nodes/
│   │   └── state-backend/
│   └── examples/
├── secretspec.toml
└── .github/
    └── workflows/
    ├── workflows/
    │   ├── validate.yml
    │   ├── build.yml
    │   ├── publish.yml
    │   └── ami.yml
    └── dependabot.yml
```

This is a guideline, not an absolute requirement. Improve it if a cleaner layout becomes apparent.

Avoid unnecessary abstraction during the first implementation.

---

# 4. Common bootc host image

The common image should contain the host-level prerequisites necessary for both controller and worker roles.

Install and configure at least:

* bootc tooling already required by the base image
* Docker Engine
* Docker Compose plugin
* OpenSSH server
* curl
* wget if required
* git
* jq
* openssl
* ca-certificates
* tar
* gzip
* NetworkManager/cloud networking requirements
* AWS EC2 compatibility
* cloud-init if appropriate for bootc EC2 provisioning
* AWS Systems Manager Agent if practical and officially available for the architecture
* SELinux support
* logrotate/system logging prerequisites

Use the official Docker repository/packages rather than distribution packages if that is required to guarantee a current supported Docker Engine.

Coolify requires Docker Engine 24 or newer.

Do not install Docker through Snap.

Enable:

```text
docker.service
sshd.service
```

as appropriate.

Run:

```bash
bootc container lint
```

during the image build or validation process and fail the build on fatal problems.

---

# 5. Do not weaken the immutable model

Avoid treating the bootc host like a conventional mutable VPS.

Do not rely on runtime:

```bash
dnf install ...
```

for normal system configuration.

If the host needs a package, add it to the owning Den aspect or bootc class and
rebuild the generated image context.

Clearly document:

```text
OS software/configuration → image
Application state → persistent filesystem
Coolify workloads → Docker
Secrets → runtime/AWS secret mechanisms
```

Runtime emergency debugging is acceptable, but persistent changes should be represented in Git.

---

# 6. Docker persistence

Verify exactly where Docker's persistent storage lives on the bootc host.

The Docker data root must survive bootc upgrades.

Prefer the conventional:

```text
/var/lib/docker
```

unless there is a compelling reason to change it.

Do not place Docker's mutable state inside an immutable `/usr` path.

Add validation tests demonstrating that:

1. a container can be created,
2. persistent data can be written,
3. an OS image update can occur,
4. the host can reboot into the new deployment,
5. Docker data remains present.

---

# 7. Coolify persistence model

Coolify expects:

```text
/data/coolify
```

Do not put mutable Coolify state in the bootc image.

Determine the cleanest bootc-compatible solution.

Preferred architecture:

```text
/data/coolify
     ↓
persistent host storage
```

A reasonable implementation may be:

```text
/var/lib/coolify
```

with:

```text
/data/coolify
```

bind-mounted or otherwise mapped to it.

Prefer a systemd mount/bind mount or another robust filesystem-native solution rather than a fragile runtime symlink if there are meaningful operational advantages.

The final result must preserve Coolify's expected path:

```text
/data/coolify
```

while ensuring its contents survive bootc deployments.

Document the exact persistence behavior.

---

# 8. Controller role

The controller should contain everything necessary for Coolify to bootstrap itself without modifying the host OS.

The OS image should provide:

* Docker Engine
* Compose
* OpenSSH
* networking prerequisites
* filesystem layout
* persistent `/data/coolify`
* required utilities
* a native `/nix` mountpoint on both roles, ready for a future Determinate Nix OSTree installation

Do NOT bake the actual mutable Coolify database, generated secrets, SSH private keys, or current Coolify containers into the bootc image.

Coolify's current production Compose file bind-mounts several `/data/coolify`
directories without an SELinux relabel option. Before starting those containers,
define a persistent `semanage fcontext` rule for the required tree using the
`container_file_t` type and apply it with `restorecon`. Scope the rule to the smallest
Coolify-owned tree; do not relabel unrelated host paths. Treat unexpected AVC denials
as deployment failures and refine labels or policy instead of switching SELinux to
permissive mode.

Implement an idempotent first-boot bootstrap process.

The bootstrap should roughly perform the manual Coolify installation workflow:

```text
Create required /data/coolify directories

Generate Coolify SSH key only if one does not already exist

Place its public key in the appropriate root authorized_keys file if needed

Obtain the current official Coolify:
  docker-compose.yml
  docker-compose.prod.yml
  .env.production template
  upgrade.sh

Generate initial secrets only if they do not already exist

Create the attachable "coolify" Docker network if absent

Start Coolify using Docker Compose
```

Never regenerate secrets on ordinary boots.

Never overwrite an existing working Coolify installation.

The bootstrap process must be idempotent.

A reboot must not reinstall or reset Coolify.

An OS rollback must not reset Coolify.

Keep SELinux enforcing on both roles. The image creates `/nix`, but it must not ship a
hand-written `nix.mount`: Determinate's OSTree planner owns the persistent bind mount,
daemon units, and native SELinux policy action. After the AMD64 AMI path is proven,
install Determinate Nix on both the controller and worker through a reviewed,
version-pinned installer using an explicit persistent path such as `/var/lib/nix`.
Validate that the daemon operates under enforcing SELinux and that the Nix store
survives reboot, bootc update, rollback, and the intended instance-replacement path.

---

# 9. Coolify version/update ownership

Do not pin Coolify permanently into the bootc image unless technically unavoidable.

The desired ownership model is:

```text
bootc image owns:
  Docker
  SSH
  kernel/userspace
  host utilities
  systemd
  host configuration


Coolify owns:
  Coolify containers
  Coolify application lifecycle


persistent filesystem owns:
  Coolify database
  environment
  SSH keys
  application configuration
```

Coolify should retain its native ability to update itself.

Do not make an OS image rebuild necessary merely to upgrade Coolify.

---

# 10. Worker role

The worker image should be significantly simpler than the controller.

It needs:

* Docker Engine 24+
* Docker Compose plugin
* OpenSSH
* root SSH capability compatible with Coolify
* appropriate persistent Docker storage
* networking
* optional AWS SSM access
* bootc updating/rollback

It should NOT contain the Coolify management application.

Coolify connects to remote servers using SSH and requires Docker Engine.

Prepare the worker so a Coolify-generated public key can be placed in:

```text
/root/.ssh/authorized_keys
```

without rebuilding the image.

Do not embed that key at image-build time.

Support passing authorized keys using:

* EC2/cloud-init/user-data,
* an AWS mechanism,
* or another secure first-boot approach.

Document which mechanism is selected and why.

---

# 11. Role selection

Prefer generating two images from shared common layers:

```text
coolify-controller
coolify-worker
```

rather than one image containing unused controller components everywhere.

For example:

```text
common bootc base
      │
      ├── controller image
      │
      └── worker image
```

Avoid duplicating package installation logic.

Nix generates one role-specific Containerfile per evaluated host while sharing the
class implementation and common aspect.

---

# 12. SELinux

Do not disable SELinux merely to make Docker or Coolify work.

Keep SELinux enforcing if feasible.

Test:

* Docker volumes,
* bind mounts,
* `/data/coolify`,
* reverse proxy workloads,
* Coolify containers.

Use correct labels/mount options where necessary.

If Coolify fundamentally requires a workaround, document it precisely.

Do not use:

```text
setenforce 0
```

or global permissive mode as the normal configuration.

---

# 13. AWS architecture

Create OpenTofu configuration for a minimal AWS deployment.

Use the `tofu` CLI and OpenTofu-native CI tooling. Keep `.tf` configuration,
AWS provider, module, state, and `.terraform.lock.hcl` formats compatible with
Terraform where practical. Use Terraform only when a required integration has
a documented incompatibility with OpenTofu and isolate that exception.

Use variables rather than hard-coded IDs.

Default region should be configurable.

A reasonable default can be:

```text
us-east-2
```

but do not make the project depend on it.

Create a production VPC across at least two Availability Zones:

```text
VPC
├── public subnets
│   ├── Internet Gateway route
│   ├── Coolify controller EC2 with Elastic IP
│   └── Coolify worker EC2 with Elastic IP
└── private subnets
    └── isolated until private workload placement is justified
```

Enable VPC DNS support, DNS hostnames, and VPC Flow Logs. Keep public ingress in
separate security groups from controller-to-worker management traffic. NAT Gateways
are optional and disabled by default; if private workloads later require outbound
internet access, enable one Availability Zone-local NAT Gateway and route per selected
Availability Zone.

Internal controller-to-worker communication should use private VPC addressing whenever practical.

---

# 14. EC2 sizing defaults

Make instance types configurable.

Initial AMD64 defaults:

Controller:

```text
t3a.small
2 GiB RAM
```

Worker:

```text
t3a.medium
4 GiB RAM
```

Allow overriding the worker to:

```text
t3a.large
```

after measured memory pressure requires 8 GiB.

Architecture remains parameterized so ARM64/Graviton can be revisited after the
initial AMD64 deployment and every required Docker workload has been verified as
multi-architecture.

---

# 15. EBS

Use gp3.

Suggested defaults:

Controller:

```text
40 GiB gp3
```

Worker:

```text
80 GiB gp3
```

Make sizes configurable.

Do not pay for provisioned performance above normal gp3 baseline without a documented need.

Enable encryption.

Investigate whether separating application state onto a distinct EBS volume provides enough operational benefit to justify the complexity.

Preferred long-term model could be:

```text
root EBS
  → bootc OS


data EBS
  → /var/lib/docker
  → /data/coolify
```

However, do not implement additional EBS volumes purely for architectural aesthetics.

If separate data volumes materially simplify disaster recovery and instance replacement, implement them and document the trade-off.

---

# 16. Security groups

Create separate security groups.

## Controller

Expose only what Coolify actually requires.

Expected potential ports include:

```text
80/tcp
443/tcp
```

Do not expose controller management ports globally. Access the temporary Coolify
bootstrap UI on port 8000 through an SSM port-forwarding session.

Where possible:

* public production access should primarily be through 80/443.
* controller-to-worker TCP/22 must be security-group-to-security-group only.
* Coolify internal ports must remain private unless a tested feature requires one.

Document every inbound rule.

## Worker

Expected public inbound:

```text
80/tcp
443/tcp
```

SSH accepts only the controller security group/private address. Routine worker
administration uses SSM and does not add a public or administrator-CIDR TCP/22 rule.

---

# 17. AWS Systems Manager

Install and enable AWS Systems Manager Agent in both images. Use Session Manager as
the sole external shell path and use its port-forwarding document for the temporary
controller bootstrap UI. Do not create public TCP/22 or TCP/8000 ingress rules.

Do not make the entire system depend on SSM if that would compromise portability outside AWS.

Think of SSM as an AWS integration layer rather than a fundamental host dependency;
local VM recovery remains available without AWS.

---

# 18. IAM instance profiles

Use IAM roles attached to EC2 instances.

Do not place AWS access keys on disk.

Controller/worker roles should initially have minimal or no AWS API privileges beyond those actually needed.

If SSM is enabled, grant only the required managed instance permissions.

If application backups will eventually target S3, create narrowly scoped permissions separately.

Do not grant:

```text
AdministratorAccess
PowerUserAccess
AmazonS3FullAccess
```

to either EC2 instance.

Apply least privilege.

---

# 19. Container registry

Support publishing the bootc image to Amazon ECR.

Create ECR repositories such as:

```text
coolify-bootc/controller
coolify-bootc/worker
```

or a cleaner equivalent.

Enable:

* immutable version tags with one narrowly excluded mutable `stable` channel,
* vulnerability scanning if available and cost-effective,
* lifecycle retention.

Use meaningful version tags.

Examples:

```text
main
sha-<gitsha>
v1.0.0
2026.08.14
```

Do not rely exclusively on `latest`.

Publish every build under an immutable version or commit tag. Move `stable` only
after the candidate has passed image and boot validation. Production bootc hosts may
track `stable`, while the immutable prior digest remains available for rollback.

---

# 20. GitHub Actions → AWS authentication

Use GitHub Actions OIDC federation with AWS IAM.

Do NOT require repository secrets containing:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

OpenTofu should be capable of creating:

* GitHub OIDC identity provider if appropriate,
* IAM role,
* trust policy,
* least-privilege ECR publishing policy.

Restrict the trust policy to this repository.

Where possible, restrict production publishing further to:

```text
main
```

and/or GitHub environments.

Document the bootstrapping problem: OpenTofu cannot initially assume a role that does not yet exist.

Provide a safe initial setup procedure.

---

# 21. CI workflow

`nix flake check` is the authoritative hermetic validation command locally and in CI.
The flake graph declares formatting, dead-code checks, ShellCheck, actionlint,
repository policy, generated host manifests, SecretSpec schemas, Terranix output
contracts, focused unit tests, and the NixOS Nebula policy test. Any copied executable
used by a derivation must have its shebang normalized with `patchShebangs` before
execution so the sandbox uses pinned Nix-store interpreters.

The required GitHub workflow runs the one flake command. It must not duplicate the
graph with a development shell followed by manual formatter, linter, Make, or test
script invocations. Pinned GitHub Actions may prepare checkout, Nix, KVM, cache, OIDC,
and artifacts, but validation ownership remains in the flake.

Hardware-assisted bootc, two-node Coolify, AMI import, production deployment, and
release exercises depend on container daemons, KVM, GitHub OIDC, or live AWS APIs and
therefore are not hermetic flake checks. Expose each as a named flake app whose runtime
tools are declared by Nix. Their GitHub YAML is only an event, permissions, runner,
credential, and artifact adapter. It must call the app rather than manually chaining
repository scripts. Cleanup traps remain inside the app-level orchestration, with a
scheduled read-only cloud audit covering interrupted runners.

---

# 22. Build workflow

On changes to relevant image files:

```text
push → main
```

build:

```text
controller
worker
```

for the selected architecture.

Initially prioritize:

```text
linux/amd64
```

but retain a future path for:

```text
linux/arm64
```

as well.

Do not claim multi-architecture support until CI actually builds and validates both architectures.

---

# 23. AMI creation

Research and implement the most appropriate current bootc-supported process for producing an AWS-compatible EC2 image.

Prefer upstream bootc tooling such as:

```text
bootc-image-builder
```

where appropriate.

The output should ultimately become an AMI usable by OpenTofu/EC2.

Keep the following artifacts conceptually separate:

```text
OCI bootc image
        ↓
bootc image builder
        ↓
AWS-compatible disk image
        ↓
AMI
        ↓
EC2
```

Do not confuse an ECR OCI image with an EC2 AMI.

Automate this only after the container image itself works reliably.

Use direct EBS snapshot upload for automated AMI registration. Keep its encryption,
metadata validation, and deterministic cleanup contract mandatory.

AWS does not currently publish a pre-generated Fedora or CentOS bootc AMI, and
the RHEL image-mode workflow also expects operators to generate their own AMI.
Keep the distribution-owned bootc container as the source of truth rather than
depending on an unverified public AMI.

AWS VM Import/Export does not list AlmaLinux in its supported OS matrix, and a
real `import-image` validation rejected the AlmaLinux 10 bootc disk during OS
detection. Upload the raw disk directly as an encrypted EBS snapshot, then
register the snapshot explicitly as an AMD64, UEFI, HVM, ENA-enabled,
IMDSv2-only AMI. This preserves the AlmaLinux identity without pretending it is
RHEL or Rocky Linux. The legacy S3 and VM Import fallback is intentionally removed.
A successful registration is not proof of bootability;
the disposable T3a launch test remains mandatory for each materially changed disk
pipeline.

Use the same EBS Direct registration implementation for retained releases rather
than adding a second AMI builder. A retained release is allowed only from `main`, must
build its disk from the corresponding immutable private ECR `sha-<full-commit>`
candidate, carry that commit and role as tags, and pass the disposable T3a/SSM
guest gate before its AMI and encrypted snapshot are preserved. Failed candidates are
deleted. A rerun for an already validated role and commit reuses the immutable AMI.
The resulting AMI ID is an operator-reviewed OpenTofu input, never a newest-image
lookup or an automatic deployment trigger.

After the EBS Direct KMS permission was corrected, merged-main run `31899706447`
completed the same registration and T3a/SSM boot gate on 2026-08-15. Its 12 GiB raw
upload completed in about 33 seconds and the AMI was launchable about 48 seconds after
upload began. The complete AWS validation and cleanup step took 4 minutes 54 seconds,
compared with roughly 14 minutes for the earlier VM Import phase alone.

Keep a separate, disposable benchmark for the alternative runtime-switch model. The
benchmark may create a digest-pinned, management-enabled CentOS Stream 10 bootc base
AMI through EBS Direct, launch it without an SSH key, switch it through SSM to the
current immutable AlmaLinux worker ECR image, reboot, and run the normal guest checks
on the switched host. Record the OCI pull/stage time independently from reboot and
validation, then remove the benchmark instance, AMI, and snapshot. Do not use the
upstream image-builder AWS uploader for this comparison because its documented path
requires S3 staging and the VM Import service role. Do not replace ECR with GHCR in the
same benchmark; registry choice and AMI delivery strategy must remain separate
variables.

---

# 24. Do not overuse EC2 Image Builder

AWS EC2 Image Builder may be useful, but do not automatically adopt it.

First determine whether bootc-image-builder + GitHub Actions provides a simpler and more transparent pipeline.

The current unified OSBuild `image-builder` already builds the AlmaLinux bootc AMI
disk. A bounded evaluation of its pinned native AWS uploader found that it uses
snapshot import, supports UEFI, and enables ENA, but does not request snapshot
encryption, set AMI IMDSv2 support, or provide the validation workflow's deterministic
AMI and snapshot cleanup. Its
preflight also requires account-wide bucket discovery. Keep the current explicit
explicit snapshot workflow and reevaluate only after upstream closes those gaps. The full
comparison is recorded in `docs/upstream-aws-uploader-evaluation.md`.

Packer is not part of the initial pipeline. Its normal `amazon-ebs` workflow needs
an existing source AMI, while import-oriented builders still depend on AWS VM
Import/Export. Adding Packer would not reduce AWS cost or solve the AlmaLinux OS
detection issue. Revisit it only if multi-cloud builds or AMI catalog promotion
workflows make the extra dependency worthwhile.

Use EC2 Image Builder only if it clearly reduces operational burden.

The repository should remain understandable to a Linux administrator without requiring deep AWS proprietary tooling.

---

# 25. Launch Templates

Once AMI generation works, use EC2 Launch Templates for controller and worker definitions.

OpenTofu should be able to point at a specific generated AMI.

Do not silently roll production instances onto a new AMI just because CI created one.

Image publication and instance deployment should be separate operations.

---

# 26. Updating existing instances

Support the bootc-native model for OS updates.

An existing system should be capable of something equivalent to:

```bash
bootc status
bootc upgrade
systemctl reboot
```

or the correct current bootc commands.

Do not hard-code commands without checking current upstream syntax.

Provide:

```text
scripts/update-host.sh
```

only if it adds meaningful safety/validation.

Before rebooting, it should ideally verify:

* new deployment staged correctly,
* required persistent paths mounted,
* Docker healthy,
* sufficient disk space.

---

# 27. Rollback

Rollback is a core requirement, not an optional feature.

Document and test:

```text
current bootc deployment
previous bootc deployment
```

Validate that rolling the OS back does not alter:

```text
/data/coolify
/var/lib/docker
application volumes
Coolify database
```

Create a documented recovery procedure.

---

# 28. Disaster recovery

Design the architecture so the controller EC2 instance can eventually be treated as replaceable.

Desired recovery model:

```text
launch new controller
        ↓
boot known-good bootc AMI/image
        ↓
restore/attach persistent Coolify state
        ↓
start Coolify
        ↓
controller resumes management
```

Similarly:

```text
launch new worker
        ↓
boot worker image
        ↓
restore required persistent data
        ↓
authorize controller SSH key
        ↓
reconnect in Coolify
```

Do not promise seamless recovery before it has been tested.

---

# 29. S3 backups

Prepare, but do not over-engineer, support for application/Coolify backups to S3.

If OpenTofu creates an S3 bucket:

* enable encryption,
* enable versioning if sensible,
* block public access,
* use lifecycle policies,
* give Coolify narrowly scoped access.

Never make the S3 bucket public.

Do not hard-code credentials into Coolify.

Document whether Coolify supports using an instance role directly or whether another credential mechanism is required.

Do not invent support that has not been confirmed.

---

# 30. DNS

Use Cloudflare for authoritative DNS and optional HTTP proxying. Cloudflare remains the
authoritative zone and the AWS stack exposes origin IP outputs.

Expose OpenTofu outputs containing:

```text
controller_public_ip
controller_private_ip
worker_public_ip
worker_private_ip
```

Document required records.

Because Coolify secondary servers proxy their own applications, application DNS should point directly at the worker hosting that application rather than at the controller.

Example:

```text
coolify.example.org
    → controller Elastic IP (proxied A record)


*.apps.example.org
    → worker Elastic IP (proxied A record)


matrix.example.org
    → worker Elastic IP (proxied A record, federation on 443)
```

Many DNS records may reuse the same worker address. Cloudflare's shared anycast proxy
addresses are the public frontend; the stable worker Elastic IP remains the origin.
The production OpenTofu stack manages the controller, application, wildcard
application, and Matrix A records only when `enable_cloudflare_dns` is explicitly
enabled after the EC2 Elastic IPs exist. Provider authentication is supplied through
the `CLOUDFLARE_API_TOKEN` runtime environment variable and never stored in HCL or
OpenTofu state.
Keep public IPv4 connectivity for the nodes because required container registries and
Discord bridge endpoints currently depend on IPv4 egress. The two Elastic IPs cost less
than providing that path through AWS DNS64/NAT64 and a NAT Gateway.

---

# 31. Coolify-to-worker networking

Prefer Coolify SSH management over private VPC networking:

```text
controller private IP
      ↓ SSH
worker private IP
```

Application traffic should flow:

```text
Internet
   ↓
worker public IP
   ↓
Coolify-managed Traefik
   ↓
application
```

Do not route application traffic through the controller.

---

# 32. Architecture support

AMD64 is the initial AWS target using T3a instances. ARM64 remains a documented
future build path after AMI creation, recovery, and application-image compatibility
have been validated on AMD64.

CI should eventually verify both.

The README should explain:

```text
AMD64
  → initial deployment target
  → maximum third-party container compatibility


ARM64
  → cheaper Graviton instances
  → revisit when application images and the AMI pipeline are verified
```

Do not transparently run x86 containers under emulation in production unless explicitly configured.

---

# 33. Observability

Keep monitoring lightweight.

At minimum make it easy to inspect:

```bash
systemctl status docker
journalctl -u docker
bootc status
docker ps
docker info
df -h
```

Consider CloudWatch Agent only if it provides useful value without unnecessary cost/complexity.

Do not build a large monitoring platform into the base appliance.

Implemented as an explicit OpenTofu gate: both production nodes receive standard
CloudWatch alarms for EC2 status-check failures, sustained high CPU, and low T3a CPU
credits. Alarm and recovery transitions use one encrypted SNS email channel. No agent,
custom metric, dashboard, or synthetic monitor is added to the base appliance. The
recipient must confirm and test the subscription after apply. Paid EC2 detailed
monitoring is disabled because the one-minute status-check and five-minute CPU and
credit metrics used by these alarms are already included in basic monitoring.

An independent, explicitly enabled account-wide annual AWS cost budget provides the
financial guardrail. The monitoring-only budget excludes credits and refunds from the
measured amount and sends email at 80 percent actual, 100 percent forecasted, and 100
percent actual spend. It intentionally uses no Budget Action, automatic instance stop,
or IAM mutation. Account-wide scope ensures that untagged leaked resources remain
visible; the reviewed annual limit defaults to 1,100 USD for the initial deployment.

---

# 34. Automatic OS updates

Do NOT enable unattended automatic bootc reboots in the initial version.

The first implementation should support:

```text
build new image
publish image
stage update
validate
reboot deliberately
```

Later, controlled automated update policies may be added.

The controller and worker should not unexpectedly reboot because an OCI tag changed.

---

# 35. Image tagging/update safety

Never configure production systems to blindly track a mutable `latest` tag without a rollback/test strategy.

Prefer immutable image references or controlled channels.

Possible model:

```text
:testing
:stable
sha256 digest
```

The promotion process should eventually be:

```text
build
 ↓
test
 ↓
publish candidate
 ↓
validate
 ↓
promote to stable
 ↓
operator stages upgrade
```

---

# 36. Secrets

No secrets in Git.

Ensure `.gitignore` excludes:

```text
.env
*.pem
*.key
terraform.tfstate
terraform.tfstate.*
override tfvars containing secrets
build artifacts
AMI temporary files
```

Production OpenTofu state uses a separately bootstrapped account-regional S3 backend
with encryption, versioning, TLS-only access, native conditional-write locking, ABAC,
and private S3 server access logs. The state bootstrap begins locally because it must
create its own backend, then migrates itself before the main AWS stack is applied.

Use GitHub Actions OIDC instead of stored AWS access keys. Put CI-only values
in GitHub Secrets, AWS-hosted runtime secrets in AWS Secrets Manager, and
provider-neutral or self-hosted secrets in OpenBao. Commit secret references,
never resolved secret values. Commit `.terraform.lock.hcl` so provider
selections and checksums are reviewed and reproducible.

For the AWS controller, OpenTofu provisions one empty Secrets Manager container,
uses a dedicated rotating customer-managed KMS key, and provisions an EC2 instance
profile restricted to that secret. It must not create an
`aws_secretsmanager_secret_version` or accept secret values as variables. Populate the
JSON value through an out-of-band operator workflow.
At runtime, resolve individual keys using
`{{resolve:secretsmanager:secret-id:SecretString:json-key}}` with `asm-exec`.
SecretSpec's checked-in `awssm` alias may perform its internal read/write operations
for scoped `check`, `set`, and `run` commands; it must never print values. Other
automation must not call secret-value read APIs in ways that can expose responses in
plans, logs, CI output, or agent context. Host services continue to use dynamic
references and `asm-exec`.

---

# 37. README requirements

Write a high-quality README targeted at an experienced Linux/VM administrator who is relatively new to AWS.

Explain:

1. What bootc is doing.
2. Why Coolify is not baked directly into the OS image.
3. Controller vs worker.
4. Repository layout.
5. Local image build.
6. Local validation.
7. AWS prerequisites.
8. GitHub OIDC bootstrap.
9. OpenTofu workflow.
10. ECR publishing.
11. AMI creation.
12. Launching the controller.
13. Launching a worker.
14. Connecting worker to Coolify.
15. OS upgrades.
16. OS rollback.
17. Coolify upgrades.
18. Backups.
19. Recovery.
20. Cost-sensitive AWS choices.

Explicitly mention:

```text
Direct public EC2 with Elastic IPs for the initial two-node deployment
NAT Gateways disabled by default
No EKS
No ECS
No Fargate
No RDS by default
No ALB by default
```

and explain that these services can be added later if a concrete requirement justifies them.

---

# 38. Development milestones

Status was reconciled on 2026-08-17 against the current jj working-copy parent,
GitHub, and read-only AWS inventory in `us-east-2`. Repository completion and live
deployment are deliberately separate. The Nix-native work is still on draft PR #42,
not on `main`, and the live AWS foundation therefore reflects the older main branch.

## Milestone 1 - Nix-owned repository scaffold

**Status: complete on the current branch.** The locked flake, Den modules, role
profiles, generated bootc contexts, Terranix roots, SecretSpec contract, tests,
documentation, and pinned GitHub Actions are present. `flake.lock`, not a language-
specific package manager lock file, is the dependency lock authority.

## Milestone 2 - Common bootc host

**Status: complete and CI-validated.** Both generated contexts contain Docker,
OpenSSH, SSM Agent, SELinux policy, bootc lifecycle support, cloud-init, Nix profile
activation, and persistent host paths. The current branch's bootc and AMI compatibility
workflows pass.

## Milestone 3 - Worker appliance

**Status: complete locally and in CI; partially released in AWS.** The worker boots,
accepts only the intended mesh management identity, runs Docker, and preserves Docker,
Nix, Coolify, and Nebula state through switch and rollback tests. AWS contains a
private, encrypted, UEFI, IMDSv2 worker AMI for `v0.1.0`; no worker is deployed.

## Milestone 4 - Controller appliance

**Status: complete locally and in CI; not released as a retained AWS AMI.** The
controller has idempotent Coolify bootstrap, persistent `/data/coolify`, OpenBao,
SecretSpec and `asm-exec` integration, and SELinux-enforcing lifecycle validation. The
two-node integration workflow registers a worker and deploys a digest-pinned test app.
AWS currently has no retained controller AMI and no controller instance.

## Milestone 4A - Determinate Nix on both roles

**Status: complete in the image and hosted VM tests; production validation pending.**
The pinned installer, native OSTree planner, persistent `/var/lib/nix`, system profile,
Home Manager activation, and rollback behavior are flake-owned. Production proof must
be repeated after both AWS nodes exist.

## Milestone 5 - Nix-native local integration

**Status: complete locally; remote validation covers the published parent.** The
current working copy passes the full hermetic flake graph. PR #42's published parent
also passed AMD64 AMI compatibility and controller-worker Coolify integration. The
supported developer entrypoints are named flake apps; the removed Makefile and legacy
role tree are not compatibility surfaces.

## Milestone 6 - AWS OpenTofu foundation

**Status: partially deployed.** Terranix generates Terraform-compatible OpenTofu JSON,
and the live account has remote-state and access-log buckets, three public and three
isolated subnets, routing, an Internet Gateway, rejected-traffic flow logs, ECR, IAM
roles, GitHub OIDC, and AMI validation resources. The state buckets are versioned,
encrypted, non-public, and access-logged.

The live security groups still contain the earlier private TCP/22 design. Applying the
reviewed Nix-native plan must remove those rules and add only the declared Nebula
UDP/4242 path. Treat this as intentional pending migration, not evidence that the
current branch has already reached production. Production variables explicitly keep
the existing 90-day VPC flow-log retention instead of accepting the module's lower
cost-oriented default.

## Milestone 7 - ECR publishing and supply chain

**Status: complete for the current `main`; current branch publication pending merge.**
Controller and worker repositories are scan-on-push, immutable except for the explicit
`stable` channel, and retain immutable SHA and `v0.1.0` tags while expiring untagged
images after seven days. The `.#release` flake app owns semantic version selection,
ECR promotion, SBOM generation, inventory, AMI manifest assembly, and publication;
GitHub YAML retains permissions and attestations only. There
is no published GitHub release, so a complete release must prove that controller and
worker OCI images, retained AMIs, manifest, attestations, and GitHub release all refer
to one source revision.

## Milestone 8 - AMI pipeline

**Status: partial.** Pull-request AMD64 compatibility passes and two private encrypted
worker AMIs remain available. The account has no retained controller AMI, so the
schema-v2 two-role release invariant is not satisfied. Complete this milestone by
running the Nix-app-orchestrated retained release from `main`, verifying both actual
EC2 boots, and recording one immutable manifest without changing running nodes.

## Milestone 9 - EC2, mesh, secrets, and recovery deployment

**Status: declared but not deployed.** The generated OpenTofu graph gates hardened
launch templates, exact AMI inputs, two protected EC2 instances, Elastic IPs,
Cloudflare records, the empty controller runtime secret, OpenBao KMS auto-unseal,
backups, and node alarms. A separate account-security gate now declares default EBS
encryption with a customer-managed key, public-snapshot blocking, a multi-region
integrity-validated CloudTrail, continuous AWS Config, GuardDuty, Inspector for EC2
and ECR, Security Hub V2, and a seven-year protected audit bucket. Live inventory
found none of those resources and no SSM
managed nodes. Apply only a reviewed saved plan through the `infra` flake app; never
pass secret values through Nix or OpenTofu.

## Milestone 10 - End-to-end AWS acceptance

**Status: blocked by Milestone 9.** After deployment, the validation flake app must use
OIDC and SSM to prove controller and worker identity, no security-group TCP/22,
administrator and Coolify SSH policy over Nebula, OpenBao loopback-only access and
auto-unseal, controller bootstrap, Cloudflare HTTPS, and a worker-hosted application.
Record the exact AMI and OCI digests in the acceptance evidence.

## Milestone 11 - Update, rollback, backup, and restore

**Status: implemented for disposable/local lifecycle tests; production drill pending.**
The harness proves switch, reboot, rollback, Docker-volume persistence, SSM, and
enforcing SELinux on disposable infrastructure. Production completion additionally
requires enabled AWS Backup, a successful controller restore, a successful worker
restore, OpenBao Raft snapshot restoration, Nebula re-enrollment, measured timings,
and approved RTO/RPO targets.

## Milestone 12 - Flake authority and thin CI adapters

**Status: complete in the current working copy; publication pending.** `nix flake check` owns every hermetic check, copied test
executables receive Nix-store shebangs through `patchShebangs`, and named flake apps
expose build, check, generation, VM, infrastructure, CI, and release entrypoints. The
required GitHub workflow is a thin adapter around the one flake check. The scheduled
disposable-resource audit and production deployment validator now enter through
named flake apps and obtain all command-line dependencies from Nix.

Integration, AMI build/import, and release operations enter through named flake apps.
Workflow YAML retains events, least-privilege permissions, runner/KVM setup, OIDC
exchange, phase timing, diagnostics, and artifact upload, but does not call Make
targets or repository scripts directly. Remote completion requires publishing the
current working copy and passing the same graph on the merge candidate.

## Milestone 13 - Account security and operational baseline

**Status: not configured.** Live inspection found no CloudTrail trail, AWS Config
recorder, GuardDuty detector, Inspector scanning, Security Hub or Security Hub CSPM,
Lucidity node alarms, Lucidity backup vault, or Lucidity annual budget. Account-level
EBS encryption by default is disabled and EBS snapshot public-access blocking is not
enabled. The audit also ran as an IAM user rather than an assumed temporary role.

Resolve these through reviewed OpenTofu modules and an explicit account-level policy
decision. At minimum, production acceptance requires auditable API history,
configuration change recording, threat and vulnerability detection, encrypted alert
routing, confirmed recipients, budget notifications, and temporary operator
credentials. Keep security-service configuration factual in reports and do not hide
findings through suppression rules.

## Milestone 14 - Production go-live decision

**Status: not ready.** Go-live requires PR #42 or its successor merged with a passing
merge-queue check, the obsolete overlapping PR closed, generated/live drift reconciled,
Milestones 8 through 13 completed, and a documented acceptance of the initial
single-AZ/singleton availability tradeoff. Do not label this design highly available;
multi-AZ failover requires an additional architecture milestone.

---

# 39. Testing philosophy

Do not accept "the image built successfully" as proof that the appliance works.

Test actual behavior.

Important assertions include:

```text
Docker daemon starts
Docker Compose works
SSH authentication works
Coolify can SSH to localhost/controller if required
Coolify can SSH to worker
Coolify can start containers
Traefik can bind 80/443
Coolify bind mounts work without SELinux AVC denials
persistent volumes survive reboot
persistent volumes survive OS update
persistent volumes survive rollback
SELinux remains enforcing
Determinate Nix uses its OSTree planner and works under enforcing SELinux on both roles
```

Where full automation is impractical, provide repeatable manual verification steps.

---

# 40. Avoid premature complexity

Do not initially implement:

* autoscaling groups,
* ALB,
* ECS,
* Kubernetes,
* RDS,
* ElastiCache,
* NAT Gateway,
* multi-region replication,
* Route 53 dependency,
* HashiCorp Vault,
* complex service discovery,
* elaborate observability stacks.

The target is a small nonprofit deployment with strong operator control.

Favor transparent Linux infrastructure.

---

# 41. Coding standards

Shell:

```text
set -Eeuo pipefail
```

where appropriate.

Use ShellCheck.

OpenTofu:

```text
tofu fmt
tofu validate
```

Pin provider constraints sensibly.

Do not commit generated state.

Generated Containerfiles should be reproducible and readable, and their complete
inputs must be represented by Nix derivations.

Systemd units should:

* have explicit dependencies,
* restart sensibly,
* not create reboot loops,
* log useful errors.

---

# 42. Flake application interface

The flake exposes the supported top-level interface:

```bash
nix run .#check
nix run .#generate
nix run .#build-controller
nix run .#build-worker
nix run .#test-controller
nix run .#test-worker
nix run .#test-mesh
nix run .#audit-ami-resources
nix run .#validate-deployment
nix run .#infra -- plan
nix run .#infra -- apply SAVED_PLAN
nix run .#state -- plan
nix run .#architecture
nix run .#release
```

`nix flake check` remains the direct authoritative CI command. Named apps may call a
Nix-packaged orchestration program internally, but every runtime dependency must be
declared by its derivation. Compatibility with the removed Makefile, role tree,
hand-authored environment root, and direct-script interfaces is intentionally not
provided.

---

# 43. Documentation of unsupported/experimental areas

Call out clearly:

* AlmaLinux bootc is currently experimental upstream.
* bootc-specific deployment of Coolify is not an officially documented Coolify deployment model.
* Coolify itself supports AlmaLinux, ARM64/AMD64, Docker 24+, and remote Linux servers.
* this repository combines supported components in a custom image-mode architecture.
* testing is therefore required before treating it as production-ready.

Do not misrepresent upstream support.

---

# 44. First implementation priority

Do not start by writing all OpenTofu configuration.

Start by proving this sequence locally:

```text
AlmaLinux 10 bootc image
        ↓
Docker Engine
        ↓
working SSH
        ↓
persistent storage
        ↓
Coolify worker
```

Then build:

```text
controller
```

Only after both roles work should AWS automation become the primary focus.

The hardest unknown is not OpenTofu. It is confirming the bootc + Docker + Coolify persistence lifecycle.

Solve that first.

---

# 45. Commit strategy

Make coherent commits as milestones are completed.

Suggested sequence:

```text
chore: initialize bootc appliance repository

feat: add common AlmaLinux bootc host image

feat: add Coolify worker image

feat: add persistent Coolify controller

test: add controller worker integration validation

feat: add AWS OpenTofu foundation

ci: publish bootc images to ECR with OIDC

feat: generate EC2 AMIs from bootc images

feat: deploy controller and worker on EC2

docs: document bootc upgrade and rollback workflow
```

Do not combine the entire project into one enormous commit.

---

# 46. Stop conditions and judgment

You have authority to make normal implementation decisions without asking for confirmation.

However:

* do not fabricate AWS resource identifiers,
* do not fabricate GitHub owner/repository names,
* do not fabricate DNS names,
* do not commit secrets,
* do not perform destructive cloud operations without an explicit deployment command,
* do not silently deploy infrastructure while merely implementing the repository.

Use variables/placeholders where environment-specific values are unknown.

If an upstream API, command, package, image tag, or AWS process has changed, consult the current official upstream documentation rather than coding from memory.

---

# 47. Definition of done

The initial project is complete when all of the following are true:

```text
[ ] Controller bootc image builds.
[ ] Worker bootc image builds.
[ ] bootc lint succeeds.
[ ] ARM64 image works.
[ ] AMD64 path is documented or working.
[ ] Docker Engine 24+ starts on boot.
[ ] SSH starts on boot.
[ ] SELinux remains enforcing.
[ ] Determinate Nix works on both roles under enforcing SELinux.
[ ] Nix store state survives bootc reboot, update, and rollback.
[ ] Coolify persistent state survives reboot.
[ ] Coolify persistent state survives bootc update.
[ ] Coolify persistent state survives bootc rollback.
[ ] Worker Docker state survives the same lifecycle.
[ ] Coolify can manage the worker over SSH.
[ ] Worker can serve a deployed test application.
[ ] GitHub Actions validates pull requests.
[ ] GitHub Actions authenticates to AWS using OIDC.
[ ] Images publish to ECR.
[x] AWS-compatible AMIs can be generated and registered through encrypted snapshot import.
[x] OpenTofu can launch controller and worker EC2 instances.
[ ] Security groups expose only required services.
[ ] Session Manager provides shell access with no public TCP/22 rule.
[ ] No long-lived AWS credentials are stored in GitHub.
[ ] README explains initial deployment.
[ ] README explains updates.
[ ] README explains rollback.
[x] README explains recovery.
```

After initialization, print a concise summary containing:

1. repository structure created,
2. decisions made,
3. anything that remains experimentally uncertain,
4. commands I should run locally,
5. AWS values I need to supply,
6. the next recommended milestone.

Begin implementation with **Milestones 1–3** rather than attempting to implement the entire architecture at once.
