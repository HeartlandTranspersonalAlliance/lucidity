# Upstream OSBuild AWS uploader evaluation

Date: 2026-08-14

The repository-pinned `ghcr.io/osbuild/image-builder-cli` image reports
`image-builder` commit `e0aa653eb4c8e19683a36714eaffbae1d81942a4`. Its
native AWS uploader was evaluated as a possible replacement for
`scripts/validate-ami-import.sh` after GitHub Actions run `31859796836` proved
the explicit snapshot registration workflow.

## Result

Keep the current explicit snapshot workflow. Its optimized path uses pinned
`coldsnap` and the EBS Direct APIs, while the original AWS CLI and VM Import path
remains available as a compatibility fallback. The upstream uploader avoids
AlmaLinux OS detection by calling `ImportSnapshot`, supports an explicit UEFI
boot mode, enables ENA, uploads with short-lived environment credentials, and
removes its intermediate S3 object. Those are useful properties, but it does
not currently meet this repository's complete security and cleanup contract.

The pinned implementation:

- does not request encryption in `ImportSnapshotInput`;
- does not set `ImdsSupport` in `RegisterImageInput`;
- cannot select the project-specific `lucidity-vmimport` service role;
- preflights with account-wide bucket listing and bucket ACL access;
- registers `/dev/sda1` without the repository's explicit gp3 and
  delete-on-termination mapping; and
- returns a persistent AMI while retaining its snapshot, rather than providing
  the validation workflow's deterministic AMI and snapshot cleanup.

An AWS execution was intentionally not performed. Static inspection proves the
registered AMI would omit the required IMDSv2 declaration, so broader IAM
permissions and additional disposable resources could not produce a passing
comparison.

## Reconsideration gate

Reevaluate the native uploader when the pinned upstream interface can:

1. explicitly encrypt the imported snapshot;
2. register an IMDSv2-only AMI;
3. accept a VM Import/Export service role name;
4. avoid account-wide S3 discovery; and
5. return enough AMI and snapshot identity for reliable failure and success
   cleanup.

Until then, using a custom wrapper around the upstream uploader would retain
the same maintenance burden while reducing security control. Packer has the
same status: it does not solve the absent bootc source AMI or reduce AWS cost,
so it remains deferred.
