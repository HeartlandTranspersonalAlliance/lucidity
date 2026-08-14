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

## Current AWS implementation decisions

The first AWS deployment targets AMD64 with `t3a.small` for the controller and
`t3a.large` for the worker. ARM64 remains a supported future direction, but it is
deferred until the AMD64 AMI, deployment, recovery, and application compatibility
paths are proven end to end.

The initial deployment uses public subnets and one Elastic IP per EC2 node. It does
not use an ALB or NAT Gateway. The VPC still spans multiple Availability Zones and
retains isolated private subnets, tiered security groups, DNS support, and VPC Flow
Logs so private placement can be enabled later. Controller-to-worker management uses
private VPC addresses even though both nodes have direct public ingress. NAT Gateways
remain an explicit opt-in for future private-subnet workloads.

AWS-hosted controller secrets use one bundled AWS Secrets Manager secret encrypted
with a dedicated rotating KMS key. OpenTofu creates only the empty secret container,
KMS key, and least-privilege controller instance profile. Secret values are populated
out of band and resolved on the EC2 instance at runtime; they are never placed in an
AMI, OpenTofu configuration, plan, or state. The EC2 bootstrap remains gated on an
approved `asm-exec` package or source.

OpenTofu is not a secret store and must not receive the runtime value. Self-hosted
OpenBao remains a provider-neutral option, but operating it solely for this one small
deployment would add another stateful service, recovery procedure, and availability
dependency. The single Secrets Manager bundle is the selected initial tradeoff.

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

Create a clean structure similar to:

```text
.
├── Containerfile
├── README.md
├── LICENSE
├── Makefile
├── .gitignore
├── .editorconfig
│
├── roles/
│   ├── common/
│   ├── controller/
│   └── worker/
│
├── files/
│   ├── etc/
│   └── usr/
│
├── systemd/
│   ├── coolify-bootstrap.service
│   └── optional supporting units
│
├── scripts/
│   ├── build.sh
│   ├── validate-image.sh
│   ├── bootstrap-controller.sh
│   └── bootstrap-worker.sh
│
├── tests/
│   ├── test-image.sh
│   ├── test-controller.sh
│   └── test-worker.sh
│
├── image/
│   └── image-builder configuration
│
├── tofu/
│   ├── modules/
│   │   ├── network/
│   │   ├── controller/
│   │   ├── worker/
│   │   ├── registry/
│   │   └── github-oidc/
│   ├── environments/
│   │   └── aws/
│   ├── variables.tf
│   ├── outputs.tf
│   └── versions.tf
│
└── .github/
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

If the host needs a package, add it to the Containerfile and rebuild the image.

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
* a controller-only native `/nix` mountpoint bind-mounted from persistent `/var/lib/nix`, ready for a future Determinate Nix installation

Do NOT bake the actual mutable Coolify database, generated secrets, SSH private keys, or current Coolify containers into the bootc image.

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

The worker must not receive the controller's `/nix` mount. Keep SELinux enforcing; when Determinate Nix is installed later, use its OSTree-aware planner and SELinux policy support rather than disabling policy enforcement. Validate that the Nix store survives controller reboot, bootc update, and rollback.

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

If a multi-stage Containerfile or multiple Containerfiles are cleaner, use them.

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
t3a.large
8 GiB RAM
```

Allow overriding the worker to:

```text
t3a.medium
```

for smaller environments.

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
22/tcp
80/tcp
443/tcp
8000/tcp
6001/tcp
6002/tcp
```

Do not blindly expose all of these globally.

Where possible:

* 22 should be restricted to an administrator CIDR and/or replaced operationally by SSM.
* 8000 should be temporary/bootstrap-only or restricted.
* public production access should primarily be through 80/443.
* Coolify internal ports should be scoped based on actual requirements.

Document every inbound rule.

## Worker

Expected public inbound:

```text
80/tcp
443/tcp
```

SSH should preferably accept connections from:

* the controller security group/private address,
* an administrative CIDR,
* or be managed through SSM.

Avoid `0.0.0.0/0` SSH.

---

# 17. AWS Systems Manager

Investigate installing and enabling AWS Systems Manager Agent in both images.

If supported cleanly on the selected bootc architecture, prefer SSM Session Manager for routine administrative access.

This provides an escape hatch if SSH/firewall configuration breaks.

Do not make the entire system depend on SSM if that would compromise portability outside AWS.

Think of SSM as an AWS integration layer rather than a fundamental host dependency.

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

Create a validation workflow that runs for pull requests.

It should:

1. lint shell scripts,
2. validate Containerfiles,
3. run OpenTofu formatting checks,
4. run OpenTofu validation,
5. build the bootc images where feasible,
6. run `bootc container lint`,
7. execute lightweight tests,
8. fail clearly.

Use pinned or major-version-controlled GitHub Actions rather than arbitrary untrusted actions.

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

If automated AMI registration requires S3 upload/import, implement that cleanly and document cleanup of temporary artifacts.

---

# 24. Do not overuse EC2 Image Builder

AWS EC2 Image Builder may be useful, but do not automatically adopt it.

First determine whether bootc-image-builder + GitHub Actions provides a simpler and more transparent pipeline.

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

Do not require Route 53.

The user may use external DNS such as Cloudflare.

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
    → controller


*.apps.example.org
    → worker
```

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

OpenTofu state may ultimately be migrated to a protected remote backend, but do not require that just to perform the first local build.

Use GitHub Actions OIDC instead of stored AWS access keys. Put CI-only values
in GitHub Secrets, AWS-hosted runtime secrets in AWS Secrets Manager, and
provider-neutral or self-hosted secrets in OpenBao. Commit secret references,
never resolved secret values. Commit `.terraform.lock.hcl` so provider
selections and checksums are reviewed and reproducible.

For the AWS controller, OpenTofu provisions one empty Secrets Manager container,
a dedicated rotating KMS key, and an EC2 instance profile restricted to that secret
and key. It must not create an `aws_secretsmanager_secret_version` or accept secret
values as variables. Populate the JSON value through an out-of-band operator workflow.
At runtime, resolve individual keys using
`{{resolve:secretsmanager:secret-id:SecretString:json-key}}` with `asm-exec`.
Do not call Secrets Manager value-reading APIs from automation that can expose their
responses in plans, logs, CI output, or agent context.

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

Work incrementally.

## Milestone 1 — Repository scaffold

Create:

* Containerfile(s)
* Makefile
* scripts
* README
* GitHub validation workflow
* basic tests

Commit this coherent milestone.

---

## Milestone 2 — Common bootc host

Produce a bootable image containing:

* Docker
* SSH
* required host utilities
* working systemd configuration

Validate:

```text
bootc container lint passes
Docker starts
SSHD starts
image boots
```

Commit.

---

## Milestone 3 — Worker appliance

Build the worker role first.

This is intentionally first because it is simpler.

Validate:

* host boots,
* Docker works,
* SSH works,
* root key authentication works,
* Coolify prerequisites are satisfied,
* Docker data survives reboot,
* Docker data survives bootc upgrade/rollback.

Commit.

---

## Milestone 4 — Controller appliance

Implement persistent `/data/coolify`.

Implement idempotent first-boot initialization.

Validate:

* `/nix` is a writable bind mount backed by persistent `/var/lib/nix`,
* the worker image does not contain the controller-only Nix mount,
* Coolify initializes once,
* secrets survive reboot,
* Coolify containers restart after reboot,
* OS rebuild does not regenerate secrets,
* OS rollback does not destroy Coolify state.

Commit.

---

## Milestone 5 — Local integration test

Create a practical test procedure using VMs if feasible.

Test:

```text
controller VM
      ↓ SSH
worker VM
```

Verify that Coolify can register the worker and deploy a trivial application.

Use something minimal such as nginx or a tiny static HTTP container.

Commit test tooling/documentation.

---

## Milestone 6 — AWS OpenTofu foundation

Add:

* VPC
* subnet
* routing
* internet gateway
* security groups
* IAM roles
* ECR
* optional S3
* GitHub OIDC

Do not deploy EC2 until the AMI pipeline is ready unless using a temporary conventional AMI for testing.

For the initial apply, enable only ECR, GitHub OIDC, and disposable AMI import
resources. Keep networking and runtime secrets feature-gated until AWS accepts the
AMI artifact and the EC2 launch milestone begins.

Commit.

---

## Milestone 7 — ECR publishing

Implement GitHub Actions OIDC authentication.

Publish controller/worker bootc OCI images.

Verify tags and architecture.

Commit.

---

## Milestone 8 — AMI pipeline

Use the appropriate bootc image-building process to generate EC2-compatible images.

Register AMIs.

On pull requests, build and validate the raw AMD64 AMI artifact without AWS
credentials. After the foundation is applied on `main`, manually dispatch the same
workflow with AWS import enabled. It uploads to the lifecycle-controlled private S3
bucket, runs VM Import/Export using the project-scoped service role, verifies the AMI
metadata, then deletes the AMI, snapshots, and object.

Validate actual EC2 boot.

Commit.

---

## Milestone 9 — EC2 deployment

OpenTofu should launch:

```text
coolify-controller
coolify-worker-01
```

with:

```text
gp3 encrypted EBS
security groups
IAM instance profiles
public + private networking
appropriate architecture
```

Validate SSM/SSH.

Commit.

---

## Milestone 10 — End-to-end AWS validation

Test:

```text
Internet
   ↓
Coolify controller


Coolify
   ↓ private SSH
worker


Internet
   ↓
worker Traefik
   ↓
test app
```

Verify HTTPS using a test domain if available.

Do not require a real production domain for automated CI.

Commit.

---

## Milestone 11 — Update/rollback validation

Publish a visibly identifiable second OS image.

On a test EC2 machine:

```text
stage upgrade
reboot
confirm new deployment
confirm Docker/Coolify data
rollback
reboot
confirm previous deployment
confirm persistent data remains
```

Document exact results.

Commit.

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
persistent volumes survive reboot
persistent volumes survive OS update
persistent volumes survive rollback
SELinux remains enforcing
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

Containerfiles should be reproducible and readable.

Systemd units should:

* have explicit dependencies,
* restart sensibly,
* not create reboot loops,
* log useful errors.

---

# 42. Makefile interface

Provide a convenient top-level interface where practical:

```bash
make build
make build-controller
make build-worker
make test
make lint
make validate
make image-controller
make image-worker
make tofu-fmt
make tofu-validate
```

Do not hide critical behavior behind inscrutable Makefile logic.

The underlying commands should remain discoverable.

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
[ ] Coolify persistent state survives reboot.
[ ] Coolify persistent state survives bootc update.
[ ] Coolify persistent state survives bootc rollback.
[ ] Worker Docker state survives the same lifecycle.
[ ] Coolify can manage the worker over SSH.
[ ] Worker can serve a deployed test application.
[ ] GitHub Actions validates pull requests.
[ ] GitHub Actions authenticates to AWS using OIDC.
[ ] Images publish to ECR.
[ ] AWS-compatible AMIs can be generated.
[ ] OpenTofu can launch controller and worker EC2 instances.
[ ] Security groups expose only required services.
[ ] No long-lived AWS credentials are stored in GitHub.
[ ] README explains initial deployment.
[ ] README explains updates.
[ ] README explains rollback.
[ ] README explains recovery.
```

After initialization, print a concise summary containing:

1. repository structure created,
2. decisions made,
3. anything that remains experimentally uncertain,
4. commands I should run locally,
5. AWS values I need to supply,
6. the next recommended milestone.

Begin implementation with **Milestones 1–3** rather than attempting to implement the entire architecture at once.
