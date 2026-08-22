# Application backup and restore

Lucidity uses two independent recovery layers:

- AWS Backup keeps seven daily, crash-consistent recovery points for each EC2
  node and its EBS volumes.
- Restic copies important application data to an independent S3-compatible
  repository. It keeps 7 daily, 4 weekly, and 6 monthly snapshots.

The operating target is a 24-hour recovery point objective and an 8-hour
recovery time objective. A snapshot is not a backup unless a restore drill has
proved it can recover the service.

## Choose a repository

Use a separate bucket, account, or self-hosted system that does not depend on
the controller or worker being healthy.

| Backend | Status | Authentication |
|---|---|---|
| AWS S3 | Supported | EC2 instance role with a role-specific prefix |
| Backblaze B2 S3 API | Supported | Scoped application key in SecretSpec |
| Garage S3 | Supported | Scoped access key in SecretSpec |
| RustFS S3 | Experimental | Scoped access key in SecretSpec |

RustFS remains experimental while its upstream release line is beta. RustFS
and Garage are backup destinations only; this stack does not deploy them.
Choose provider durability, egress, API-call, minimum-retention, and lifecycle
charges before committing to a backend. Restic deduplicates and compresses
data, so the bill is driven by changed data rather than the raw size of every
snapshot.

For AWS S3, set these OpenTofu inputs to attach least-privilege access to the
existing node roles:

```hcl
application_backup_bucket_arn         = "arn:aws:s3:::example-backups"
application_backup_bucket_kms_key_arn = "arn:aws:kms:us-east-2:ACCOUNT:key/KEY_ID"
application_backup_secret_arns = {
  controller = []
  worker     = ["arn:aws:secretsmanager:us-east-2:ACCOUNT:secret:EXACT_SECRET"]
}
application_backup_secret_kms_key_arn = "arn:aws:kms:us-east-2:ACCOUNT:key/KEY_ID"
```

The S3 policy limits each node to `lucidity/controller` or
`lucidity/worker`. Only exact SecretSpec-managed secret ARNs are readable.

## Configure a node

Copy `/etc/lucidity/backup-target.env.example` to the root-owned
`/etc/lucidity/backup-target.env`. It contains identifiers only, never keys or
passwords.

AWS S3 example:

```dotenv
LUCIDITY_BACKUP_BACKEND=aws-s3
LUCIDITY_BACKUP_REPOSITORY=s3:s3.us-east-2.amazonaws.com/example-backups/lucidity/controller
```

S3-compatible example:

```dotenv
LUCIDITY_BACKUP_BACKEND=garage-s3
LUCIDITY_BACKUP_REPOSITORY=s3:https://garage-backup.example.org/example-backups/lucidity/worker
LUCIDITY_BACKUP_PATHS=/var/lib/coolify:/var/lib/nebula
```

Backblaze, Garage, and RustFS endpoints must use HTTPS. If the server requires
path-style requests, configure that behavior at the endpoint or proxy. Keep a
separate repository, password, credentials, and prefix for each role.

The controller resolves its backup password and compatible-S3 credentials from
loopback-only OpenBao. Its systemd service loads a narrowly scoped OpenBao token
from `/var/lib/openbao/backup-token` as a systemd credential. The worker uses
SecretSpec's AWS provider and its EC2 role to resolve only the exact Secrets
Manager ARNs declared in OpenTofu. SecretSpec materializes
`RESTIC_PASSWORD_FILE` as a private temporary file for the restic process.

Create restic secrets interactively with SecretSpec. Never place values in a
shell argument, environment file, Nix expression, OpenTofu variable, state
file, or journal. Add a second restic key and keep it with a different operator
in offline custody so loss of OpenBao or AWS access does not make the repository
unrecoverable.

## Select data and hooks

Default controller inputs are Coolify state, Nebula identity, and atomic
OpenBao Raft snapshots. Default worker inputs are Coolify state and Nebula
identity. A worker hook briefly stops OOYE and the labeled Continuwuity
container, then stages OOYE's registration and SQLite files plus the explicit
`lucidity-continuwuity-data` volume. Lucidity deliberately refuses `/`,
`/var/lib/docker`, and `/var/lib/nix` as direct backup roots.

Put executable, root-owned dump hooks in `/etc/lucidity/backup.d`. Each hook
receives a private staging directory as its only argument. Use hooks for
database-consistent dumps and application-specific exports. Do not copy a live
database file when its engine provides a dump or snapshot command.

## Operate and verify

```console
sudo lucidity backup init
sudo lucidity backup run
sudo lucidity backup check
sudo systemctl enable --now lucidity-backup.timer
```

The timer runs daily before the AWS Backup window. Controller runs also create
an atomic OpenBao snapshot first. Repository checks read a rotating 5 percent
of stored data. The self-hosted Prometheus collector alerts through Alertmanager
and ntfy when a configured application backup is more than 30 hours old. Review
AWS Backup job status during the production audit; Lucidity does not create a
CloudWatch or SNS notification path.

Stage a restore without changing live data:

```console
sudo lucidity backup restore latest /var/lib/lucidity-restore/drill-YYYYMMDD
```

The destination must be new and below `/var/lib/lucidity-restore`. Lucidity
never overwrites live state. Verify checksums, ownership, database imports,
OpenBao Raft health, Nebula identity, and application behavior in an isolated
environment. Promote the staged data only after an independent operator reviews
the evidence and approves the outage procedure.

Run a restore drill before production and at least quarterly. Record the
snapshot age, elapsed recovery time, recovered service checks, and any manual
steps. Production is ready only when the drill meets the 24-hour RPO and 8-hour
RTO.
