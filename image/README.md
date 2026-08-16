# Disk image configuration

`image-builder.env` pins the upstream unified osbuild image-builder container and the small source artifact size. The old standalone `bootc-image-builder` project has been deprecated for new integrations, so this repository invokes `image-builder build --bootc-ref`.

No user, SSH key, password, AWS credential, or Coolify state is embedded here. Worker authorization and controller initialization remain first-boot concerns.

The local build creates either:

- `qcow2`, for controller or worker VM boot and persistence tests that must precede production use;
- `ami`, the raw disk artifact that can later be uploaded directly to an encrypted EBS snapshot and registered as an EC2 AMI.

Creating an `.ami` build output does not create an AMI in AWS. Upload and registration are separate, explicit EBS Direct operations after OpenTofu provides the restricted validation role and snapshot KMS key. No S3 staging bucket or VM Import role is used.

The first AWS target is AMD64/T3a. ARM64 remains deferred until the AMD64 controller
and worker lifecycle, recovery, and application compatibility paths are proven. Each
AMD64 raw artifact must pass the disposable GitHub registration and launch gate before
it is described as deployable.
