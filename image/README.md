# Disk image configuration

`image-builder.env` pins the upstream unified osbuild image-builder container and the small source artifact size. The old standalone `bootc-image-builder` project has been deprecated for new integrations, so this repository invokes `image-builder build --bootc-ref`.

No user, SSH key, password, AWS credential, or Coolify state is embedded here. Worker authorization remains a cloud-init first-boot concern.

The local build creates either:

- `qcow2`, for the VM boot and persistence tests that must precede production use;
- `ami`, the disk artifact that can later be uploaded to a temporary private S3 bucket and registered as an EC2 AMI.

Creating an `.ami` file does not create an AMI in AWS. Upload and registration will be a separate, explicit operation after Terraform provides a restricted import bucket and VM import role.
