# Worker workloads: Continuwuity and OOYE

The worker image supplies two complementary deployment contracts:

- a Coolify Compose template for a small federated Continuwuity Matrix server;
- a Nix-built, pinned OOYE 3.6.0 executable managed as a native hardened
  systemd service.

The image does not deploy either workload automatically. Matrix identity and
bridge tokens are difficult to change after initialization, so an operator must
review and provision them before the services become active.

## Continuwuity through Coolify

The template is installed at
`/usr/share/lucidity/workloads/continuwuity/compose.yaml`; its non-secret example
values are beside it in `env.example`. Import the Compose file into Coolify and
set:

```dotenv
MATRIX_SERVER_NAME=heartlandta.org
MATRIX_SERVICE_HOSTNAME=matrix.heartlandta.org
CONTINUWUITY_VERSION=v26.7.3
CONTINUWUITY_IMAGE_DIGEST=sha256:TESTED_REGISTRY_DIGEST
```

`MATRIX_SERVER_NAME` determines every user and room ID. Treat it as permanent
after the first deployment. Resolve the image digest for the exact reviewed tag
and keep both the human-readable version and immutable digest. The template
disables unrestricted registration and direct host publication, advertises
federation on HTTPS port 443, and uses the explicit
`lucidity-continuwuity-data` volume.

Assign `https://matrix.heartlandta.org:8008` to the Continuwuity service in
Coolify. The suffix is the internal container port; clients still use HTTPS
443. The template exposes port 8008 only to the Compose network.

Before creating the first account, verify the server-name discovery documents
at `https://heartlandta.org/.well-known/matrix/server` and
`https://heartlandta.org/.well-known/matrix/client`. Then use Continuwuity's
one-time initial registration token to create the administrator and leave
unrestricted registration disabled. Never copy the token into a command-line
argument, issue, log, or repository file.

## OpenBao trust for the worker

The controller OpenBao listener accepts TLS only on its Nebula address
`100.96.0.1:8200`. Install the controller CA certificate, not a private key, at
`/etc/lucidity/openbao-ca.crt` on the worker. Until that file exists, the worker
OpenBao Agent and OOYE services are skipped.

In OpenBao, enable AWS IAM auth, constrain a `lucidity-worker` role to the exact
production worker identity, and grant it read access only to the OOYE
registration field. The image's agent exchanges the worker instance identity
for a short-lived token and writes that token to `/run/openbao-agent/token` with
mode `0600`. SecretSpec uses `BAO_TOKEN_PATH` and resolves the registration only
at service start. No secret is placed in the Nix store, image, OpenTofu state,
service environment, process arguments, or journal.

Store the complete private OOYE registration document in OpenBao at the path and
field declared by the `ooye-worker` SecretSpec profile. It contains the Discord
token, Matrix application-service tokens, and public bridge configuration, so
treat the entire document as a secret.

## OOYE registration and routing

Generate the registration once with OOYE's reviewed setup flow. It must use:

- the permanent Matrix server name;
- a public HTTPS bridge hostname routed through Coolify to the worker host; and
- `http://host.docker.internal:6693` as the callback URL Continuwuity uses to
  reach OOYE.

Register the complete document in Continuwuity's administrator room with
`!admin appservices register`, then confirm it appears in
`!admin appservices list`. Docker's host gateway provides container-to-host
reachability; do not expose raw port 6693 to the public Internet.

After the CA, OpenBao auth role, and secret exist:

```bash
sudo systemctl enable --now openbao-agent-worker.service
sudo systemctl start ooye-registration.service
sudo systemctl enable --now ooye.service
systemctl --no-pager --full status \
  openbao-agent-worker ooye-registration ooye
```

OOYE runs as the unprivileged `ooye` user with an empty capability set and may
write only `/var/lib/ooye`. Its SQLite database and registration are persistent.
The pinned source revision is part of `flake.lock`; upgrades require a reviewed
flake input change and a successful package build.

## Acceptance and recovery

Before production traffic, verify:

1. Matrix client login and a low-volume static site both survive a worker
   reboot and unchanged Coolify redeploy.
2. Federation works with one remote homeserver through port 443 discovery.
3. Continuwuity can reach OOYE through `host.docker.internal:6693` while port
   6693 and container port 8008 remain unreachable from the public Internet.
4. A test message, edit, reaction, and small attachment bridge in both
   directions without sustained errors in Grafana logs.
5. The worker backup hook produces an application-consistent snapshot and an
   isolated restore recovers Matrix login, a room, OOYE mapping state, and the
   bridge registration.

Complete a 72-hour production-candidate soak before promotion. During the soak,
require both HTTPS probes and telemetry targets to remain up, zero Alloy dropped
log entries, no sustained CPU alert, at least 20 percent controller disk free,
and a successful daily backup. Record any alert or restart as evidence even if
the service recovered automatically.
