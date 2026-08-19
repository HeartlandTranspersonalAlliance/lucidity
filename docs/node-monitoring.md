# Production observability

Lucidity ships a provider-neutral OpenMetrics stack in the locked bootc images. It
does not create CloudWatch alarms, an SNS notification topic, or a hosted monitoring
service.

The worker and controller each run node_exporter on their Nebula address only. The
controller runs Prometheus, Alertmanager, blackbox exporter, Grafana, ntfy, and the
Alertmanager-to-ntfy adapter. Prometheus and the dashboards are intentionally bound
to loopback. Use an SSM port-forwarding session when an operator needs Grafana:

```bash
aws ssm start-session \
  --target CONTROLLER_INSTANCE_ID \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
```

Then open `http://127.0.0.1:3000`. Anonymous access is Viewer-only and is safe only
because Grafana is not exposed by the security group, Coolify, or Nebula.

## Signals and alerts

Prometheus scrapes `100.96.0.1:9100` and `100.96.0.2:9100`. A minute timer writes
atomic textfile metrics for the role, image version, required systemd services,
unhealthy Docker containers, backup configuration, and the last successful restic
backup. node_exporter supplies CPU, filesystem, memory, and host metrics without
granting a container access to the Docker socket.

Blackbox exporter probes the controller's `/api/health` path and the worker's
`/_matrix/client/versions` path through `coolify.heartlandta.org` and
`matrix.heartlandta.org`. Alerts cover:

- an unreachable node exporter or failed public HTTPS probe;
- inactive role services or unhealthy Docker containers;
- a configured backup with no success for 30 hours;
- less than 15 percent free filesystem capacity;
- CPU above 85 percent for 15 minutes; and
- controller/worker image-version drift.

Alertmanager groups notifications and sends firing and resolved events to the local
adapter. The adapter publishes to the authenticated `lucidity-alerts` topic at
`https://ntfy.heartlandta.org`.

## Provision ntfy credentials

ntfy starts with `auth-default-access: deny-all`. Create distinct publish-only tokens
for Alertmanager and GitHub Actions. Do not reuse an administrator token and do not
put either token in OpenTofu, an image, logs, or repository files.

Store the Alertmanager token as `NTFY_ALERTMANAGER_TOKEN_FILE` under the OpenBao
`monitoring-controller` profile. Put only a narrowly scoped OpenBao service token at
`/var/lib/openbao/monitoring-token`, owned by `root:root` with mode `0600`. systemd
exposes that service token as a credential; SecretSpec materializes the ntfy token in
a private temporary file, and the wrapper constructs an authentication fragment under
`/run`. Neither token appears on the command line. Restart
`alertmanager-ntfy.service` after provisioning.

Store the second token as the GitHub Actions secret `NTFY_CI_TOKEN`. The
`Report CI failures to ntfy` workflow runs after critical workflows complete. It
checks out only `main`, reads failed job and step names with the ephemeral GitHub
token, and publishes to `lucidity-ci`. Missing ntfy configuration is a visible clean
skip; notification delivery is advisory and cannot replace required checks.

## Public ntfy route

OpenTofu creates the proxied `ntfy.heartlandta.org` DNS record when Cloudflare DNS is
enabled. The controller installs a deterministic Traefik dynamic configuration in
Coolify's persistent `proxy/dynamic` directory. The public route terminates TLS in the
existing Coolify proxy and forwards only to ntfy on the controller's Nebula address.
No new AWS ingress rule is required.

Validate after deployment:

```bash
systemctl --no-pager --full status \
  prometheus prometheus-alertmanager prometheus-blackbox-exporter \
  prometheus-node-exporter grafana ntfy alertmanager-ntfy
curl --fail http://127.0.0.1:9090/-/ready
curl --fail http://127.0.0.1:9093/-/ready
curl --fail http://100.96.0.1:2586/v1/health
```

Subscribe a test client to both topics, cause a reversible test alert, and confirm
the firing and resolved messages. Also dispatch a non-required test workflow that
fails and confirm the CI notification contains the failed job and step.

## Failure boundary

This design deliberately avoids another hosted dependency, but the controller is a
single observability and notification failure domain. A total controller or network
failure prevents Prometheus evaluation and ntfy delivery. The independent GitHub
workflow still detects CI failures, but it cannot deliver while the self-hosted ntfy
endpoint is down. Add an external dead-man receiver only if that availability tradeoff
becomes unacceptable.
