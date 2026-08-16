# Production node monitoring

The optional OpenTofu node-monitoring module creates a deliberately small alerting
surface for the controller and worker. It uses existing EC2 metrics and does not
install CloudWatch Agent, publish custom metrics, or create a paid dashboard.

Each node receives three standard metric alarms:

| Signal | Trigger | Evaluation |
|---|---|---|
| `StatusCheckFailed` | value at least 1 | 2 of 3 one-minute periods |
| `CPUUtilization` | at least 85 percent | 3 of 5 five-minute periods |
| `CPUCreditBalance` | at most 20 credits | 2 of 3 five-minute periods |

The launch templates use EC2 basic monitoring. Status-check metrics arrive every
minute, while CPU utilization and CPU-credit metrics arrive every five minutes. Those
intervals exactly match these alarms and provide the selected detection timing at the
basic-monitoring price. The `ec2_detailed_monitoring_enabled` OpenTofu output makes the
setting auditable for both roles.

Missing data remains `INSUFFICIENT_DATA`; it does not manufacture a failure or a
recovery event. Both `ALARM` and return-to-`OK` transitions publish to one encrypted
SNS topic.

## Enable notifications

Configure an actively monitored email address and enable the module with the
production instances:

```hcl
enable_node_monitoring        = true
node_alarm_notification_email = "operations@example.org"
```

Applying the stack sends an SNS confirmation message. The recipient must confirm it
before alarms can deliver email. Verify the subscription after confirmation:

```bash
tofu -chdir=tofu/environments/aws output node_alarm_notification_topic_arn
aws sns list-subscriptions-by-topic \
  --region us-east-2 \
  --topic-arn arn:aws:sns:us-east-2:ACCOUNT_ID:lucidity-production-node-alarms
```

The subscription ARN must not be `PendingConfirmation`.

The topic uses a dedicated customer-managed KMS key because the AWS-managed SNS key
does not permit CloudWatch alarms to use it. The topic policy restricts publish access
to this account's `lucidity-production-*` CloudWatch alarms. The dedicated key policy
allows only account administration plus the CloudWatch and SNS encryption operations
needed for delivery.

## Test delivery

After confirming the subscription, test one alarm and then return it to normal:

```bash
aws cloudwatch set-alarm-state \
  --region us-east-2 \
  --alarm-name lucidity-production-controller-status-check \
  --state-value ALARM \
  --state-reason "operator notification test"

aws cloudwatch set-alarm-state \
  --region us-east-2 \
  --alarm-name lucidity-production-controller-status-check \
  --state-value OK \
  --state-reason "operator notification test complete"
```

Confirm that both messages arrive and record the test. CloudWatch resumes metric-based
evaluation after the manual state change.

## Response

- Status check: inspect both EC2 status checks, console output, and Systems Manager.
  A system check suggests AWS host infrastructure; an instance check suggests the
  guest OS, network, or storage.
- High CPU: inspect workload processes and `CPUCreditBalance`. Tune the threshold only
  after collecting a baseline.
- Low CPU credit: reduce sustained load or move the affected T3a node to a
  fixed-performance family. The launch templates use standard credit mode, so surplus
  CPU charges are not silently accumulated.

These alarms do not measure filesystem capacity, Docker health, or application HTTPS
availability. Add CloudWatch Agent or a synthetic check only after the operational
value justifies its additional cost and maintenance.
