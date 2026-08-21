# Production observability

Lucidity ships a provider-neutral observability stack in the locked bootc images.
It creates no CloudWatch alarms, AWS Synthetics canaries, SNS monitoring topic, or
hosted dashboard. The controller is the metrics, log, dashboard, alert, and
notification node; the worker only exports its own telemetry over Nebula.

| Signal | Producer | Controller service | Retention |
| --- | --- | --- | --- |
| Host and Lucidity lifecycle metrics | node_exporter on both nodes | Prometheus | 30 days |
| systemd journal and Docker JSON logs | Grafana Alloy on both nodes | Loki | 7 days |
| Public HTTPS health | blackbox exporter on controller | Prometheus | 30 days |
| Dashboards and log search | Prometheus and Loki | Grafana | source retention |
| Alerts | Prometheus | Alertmanager to ntfy | ntfy cache policy |

All inter-node traffic uses the Nebula overlay. Prometheus, Alertmanager, and
Grafana listen on controller loopback. Loki listens only at `100.96.0.1:3100`;
Alloy and node_exporter listen only at each node's overlay address. Alloy reads
the journal and Docker JSON log files read-only and is not given the Docker
socket. Docker rotates files at 10 MiB with three files per container, journald
is limited to seven days and 1 GiB, and Loki rejects sustained ingestion above
2 MiB/s with a 4 MiB burst. These bounds are intentional for the small
controller.

Use an SSM port-forwarding session when an operator needs Grafana:

```bash
aws ssm start-session \
  --target CONTROLLER_INSTANCE_ID \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
```

Then open `http://127.0.0.1:3000`. Anonymous access is Viewer-only and is safe
only because Grafana is not exposed by an AWS security group, Coolify, or
Nebula.

## Signals and alerts

Prometheus scrapes node_exporter and Alloy on `100.96.0.1` and `100.96.0.2`,
plus Loki on the controller. A minute timer writes atomic textfile metrics for
the role, image version, required systemd services, unhealthy Docker containers,
backup configuration, and the last successful restic backup.

Blackbox exporter probes Coolify and Matrix over their public HTTPS endpoints.
This is an ordinary open-source process on the controller, not an AWS paid
canary. Alerts cover:

- node_exporter, Alloy, Loki, or a public HTTPS endpoint becoming unavailable;
- inactive role services, unhealthy Docker containers, or dropped log entries;
- a configured backup with no success for 30 hours;
- less than 15 percent free filesystem capacity, with an earlier 20 percent
  warning for the controller observability store;
- CPU above 85 percent for 15 minutes;
- controller/worker image-version drift; and
- a daily heartbeat whose absence detects failure of the self-hosted alert path.

The dashboard includes node and public endpoint health, filesystem capacity,
Alloy/Loki health, and recent controller/worker logs.

## Provision ntfy credentials

ntfy starts with `auth-default-access: deny-all`. Create distinct publish-only
tokens for Alertmanager and GitHub Actions. Do not reuse an administrator token
or put either token in OpenTofu, an image, logs, or repository files.

Store the Alertmanager token under the OpenBao `monitoring-controller` profile.
Put only a narrowly scoped OpenBao service token at
`/var/lib/openbao/monitoring-token`, owned by `root:root` with mode `0600`.
systemd exposes that token as a credential; SecretSpec resolves the publish token
into a private temporary file in memory-backed runtime storage. Neither token
appears on the command line. Restart `alertmanager-ntfy.service` after
provisioning.

Store the second token as the GitHub Actions secret `NTFY_CI_TOKEN`. The
`Report CI failures to ntfy` workflow checks out only `main`, reads failed job
and step names with the ephemeral GitHub token, and publishes to `lucidity-ci`.
Notification delivery is advisory and cannot replace required checks.

## Validate after deployment

```bash
systemctl --no-pager --full status \
  prometheus loki alloy prometheus-alertmanager \
  prometheus-blackbox-exporter prometheus-node-exporter grafana ntfy \
  alertmanager-ntfy
curl --fail http://127.0.0.1:9090/-/ready
curl --fail http://127.0.0.1:9093/-/ready
curl --fail http://100.96.0.1:3100/ready
curl --fail http://100.96.0.1:2586/v1/health
```

Confirm both Alloy targets, both node_exporter targets, Loki, and both HTTPS
probes are up in Prometheus. Query `{role=~"controller|worker"}` in Grafana
Explore and confirm both roles have recent logs. Subscribe a test client to both
ntfy topics, cause a reversible test alert, and confirm firing and resolved
messages.

## Failure and recovery boundary

The controller is a single observability and notification failure domain. A
total controller or network failure prevents Prometheus evaluation, log search,
and ntfy delivery. The daily heartbeat makes that limitation visible to an
operator who has subscribed on another device, but it does not provide an
independent availability guarantee.

Prometheus, Loki, Grafana, Alloy, and ntfy state are rebuildable telemetry and
are excluded from application backups. Seven-day Loki retention is for incident
diagnosis, not compliance or durable audit storage. Restore application state,
rebuild the controller image, and allow the observability stores to repopulate.
Add an external dead-man receiver only if this accepted singleton tradeoff
changes.
