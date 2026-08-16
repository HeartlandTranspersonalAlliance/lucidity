# Controller and worker recovery

This runbook covers recovery of the two production EC2 nodes created by the
OpenTofu stack. It does not claim zero data loss or seamless failover. AWS Backup
creates crash-consistent recovery points for all EBS volumes attached to each
selected instance. Application-consistent database exports remain a separate
Coolify backup milestone.

## Recovery contract

When `enable_node_backups=true`, OpenTofu configures:

- a daily backup at 05:00 UTC;
- 7-day retention by default;
- exact selection of the controller and worker instance ARNs;
- a customer-managed KMS key;
- governance-mode Vault Lock with 7-to-365-day retention bounds;
- one role used only to create backups;
- one restore role whose `iam:PassRole` permission is restricted to the controller
  and worker runtime roles.

The launch templates set `delete_on_termination=false` for root volumes. This is a
last-resort retention control, not a substitute for backups. A terminated instance
can therefore leave an unattached, billable volume that must be inventoried and
removed only after recovery is verified.

The default recovery-point objective is at most 24 hours. The recovery-time
objective is intentionally uncommitted until the first timed AWS restore drill.

## Enable and verify backups

Enable backups in the reviewed production variables only after both instances are
enabled:

```hcl
enable_ec2_instances = true
enable_node_backups   = true
```

After apply, record these outputs in the operational inventory:

```bash
tofu -chdir=tofu/environments/aws output node_backup_vault_arn
tofu -chdir=tofu/environments/aws output node_backup_plan_id
tofu -chdir=tofu/environments/aws output node_restore_service_role_arn
tofu -chdir=tofu/environments/aws output ec2_instance_ids
```

For each instance ARN, confirm a `COMPLETED` recovery point exists after the first
scheduled window:

```bash
aws backup list-recovery-points-by-resource \
  --region us-east-2 \
  --resource-arn arn:aws:ec2:us-east-2:ACCOUNT_ID:instance/i-INSTANCE_ID
```

Also check AWS Backup job status. A plan existing without successful jobs is not a
working backup:

```bash
aws backup list-backup-jobs \
  --region us-east-2 \
  --by-state FAILED
```

## Non-disruptive restore drill

Run this after the first recovery point, after material storage changes, and at least
quarterly. Use an isolated replacement; never overwrite or detach storage from the
running node during a drill.

1. In AWS Backup, select the latest `COMPLETED` EC2 recovery point for one node.
2. Start an EC2 restore with the `node_restore_service_role_arn` output.
3. Override restore metadata so the drill uses the intended VPC subnet and the
   role-specific security groups. Do not associate either production Elastic IP.
4. Wait for EC2 status checks and Systems Manager `Online` state.
5. Through Session Manager, verify `bootc status`, `getenforce`, `docker info`, disk
   mounts, and the expected persistent application data. For the controller, also
   verify the Coolify Compose services and `/data/coolify` bind mount.
6. Record recovery-point ARN, start and completion times, restored instance ID,
   validation results, and any manual correction required.
7. Terminate only the drill instance after collecting evidence. Confirm whether its
   restored volumes were deleted; remove only drill volumes that are explicitly
   identified and no longer needed.

Use the AWS Backup console for the first drill because it presents the recovery
point's service-generated restore metadata for review. After a successful drill,
capture that metadata with `get-recovery-point-restore-metadata` and automate the
same isolated restore through `start-restore-job`. Do not invent restore metadata or
test against the production Elastic IPs.

## Production recovery

1. Stop writes if the failed node is still reachable. Preserve logs and note the
   failure time.
2. Choose the newest `COMPLETED` recovery point from before the corruption or loss.
3. Restore a replacement with the dedicated restore role, known VPC placement, and
   the original role-specific security groups and instance profile.
4. Validate the replacement through Session Manager before exposing it.
5. For a controller, verify Coolify data, database health, Compose services, and
   private SSH management of the worker. For a worker, verify Docker volumes and a
   deployed test application before reconnecting it in Coolify.
6. Reassociate the node's existing Elastic IP only after validation. External DNS
   remains stable because it points at that Elastic IP.
7. Reconcile the restored instance with OpenTofu before the next apply. Review the
   plan until it does not propose deleting the recovered node or its retained data.
8. Retain the failed volume and recovery point through the incident review. Remove
   them only with explicit identifiers after recovery evidence is accepted.

If no usable recovery point exists, inspect the retained root volume from the failed
instance by attaching it read-only to an isolated recovery host. Never attach the
same writable filesystem to two instances.

## Known limits

- The daily plan permits up to 24 hours of data loss.
- EBS recovery points are crash-consistent; they do not replace database-native or
  Coolify application backups.
- Vault Lock is governance mode. Authorized IAM principals can change it, while
  ordinary deletion attempts remain constrained by retention.
- Cross-Region and cross-account copies are not enabled. They add cost and should be
  introduced only when the required failure model justifies them.
- Recovery is not declared production-proven until a timed controller drill and a
  timed worker drill both pass on AWS.
