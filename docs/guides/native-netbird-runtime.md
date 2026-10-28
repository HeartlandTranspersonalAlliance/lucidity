# Private native NetBird runtime (opt-in)

This is a runtime foundation, not a public or production deployment. Importing
either module changes no units, users, firewall rules, ports, or Podman settings.
No existing Lucidity host imports or enables these leaves. The legacy bootc host
schema and Terranix inventory are unchanged.

Exports:

- `nixosModules.lucidity-netbird-server`: combined management/signal/relay/STUN
  service, disabled by default.
- `nixosModules.lucidity-netbird-local-identity`: includes server options and adds
  explicit embedded local IdP configuration; creates no account and does not
  enable the server automatically.

Both `lucidity.netbird.server.enable` and
`lucidity.netbird.localIdentity.enable` must be selected for this first runtime.
`server.exposedAddress` is a bare HTTPS origin, optionally with a port, without
userinfo, trailing slash, path, query, or fragment. The identity leaf appends
`/oauth2` exactly once and derives dashboard callbacks, preserving the port.
There is no arbitrary secret-bearing settings passthrough.

## Runtime credential boundary

Set the three `lucidity.netbird.server.credentialFiles` options to external
absolute **strings**, never Nix path literals, derivations, or secret values:
`authSecret`, `encryptionKey`, and `sessionCookieEncryptionKey`. Files must
already exist when the unit starts. Systemd `LoadCredential` copies them into
its private credential directory. A dedicated metadata-only SecretSpec manifest
uses the `systemd-credential` provider and `as_path`, with a fixed profile/scope.
The genuine pinned `lassulus/wrappers` adapter starts the Python boundary.

- Relay `authSecret`: nonempty UTF-8, preserved exactly (including newlines and
  punctuation); use independently generated high-entropy material. NUL and
  oversized inputs are rejected.
- Both encryption keys: canonical standard base64 encoding of **32 independent
  random bytes**, with no trailing newline. This deliberately narrows the cookie
  key formats accepted upstream to one unambiguous convention.
- All three are mandatory before native server exec. No fallback generation.
  Preserve the datastore key with the persistent state and backups; do not
  regenerate it on restarts or assume replacing the file performs a migration.
- Inherited `SECRETSPEC_*` routing and provider credentials are discarded before
  SecretSpec. Fresh private HOME/XDG configuration directories prevent global
  provider aliases from overriding the dedicated builtin provider. The final server environment is another clean allowlist, removing
  every inherited `NB_*` variable, including `NB_PROXY_TOKEN`. Only afterward,
  it sets the fixed nonsecret `NB_DISABLE_GEOLOCATION=true`; inherited values
  cannot override this switch.
- Python reads private files, not secret argv. The renderer emits JSON (valid
  YAML), with no environment interpolation, using atomic replacement and mode
  `0600` inside the `0700` runtime directory. Errors do not print values.

This PR does not retrieve or provision credentials. AWS Secrets Manager delivery
must separately obey repository `asm-exec` policy; direct SecretSpec `awssm`
routing is deliberately not supported here. OpenBao delivery is also separate.
The standalone operator CLI/devenv workflow remains available, but evaluation
and builds never resolve runtime providers.

## Network and process boundaries

HTTP/gRPC/relay binds `127.0.0.1:8081`; health binds `127.0.0.1:9000`.
The native combined package carries a narrow v0.81.5 patch: preserve the full
configured management listen address (upstream discards its host) and disable
the unused legacy gRPC listener on port 33073. Standalone management retains
its unset-address default. The VM inventories every native TCP/UDP listener
and verifies the actual loopback sockets, independently of firewall rules.
Upstream `/health` actively dials the public origin over WSS: without the later
TLS ingress it returns HTTP 503 (`unhealthy`, `certificate_valid=false`). This
is expected here, not proof of a failed local startup. `/api/instance` verifies
local API readiness; the VM asserts the explicitly degraded health response.
Metrics is wildcard-bound upstream, so its default **9190** is protected by a
separate nftables `inet` input hook that drops non-loopback traffic to HTTP,
health, and metrics, adding defense in depth for the loopback-only listeners. STUN is also
wildcard-bound; its explicit, nonempty port list defaults to `[3478]` and is
blocked off-loopback unless `server.exposeStun = true`. Empty STUN lists are
rejected because upstream restores its default port. All ports must be distinct
and unprivileged. Neither metrics nor HTTP is opened by an exposure option.

An **already enabled nftables backend is required**. The module never flips the
host firewall backend. Its guard runs independently of trusted-interface and
broad allow rules, covers IPv4/IPv6, and the service requires, follows, and binds
to `nftables.service`. Explicit administrative changes to nftables remain the
administrator's responsibility.

SecretSpec supervises the native child, so systemd's default control-group
termination is retained: stopping the service kills both processes. The VM
checks that stopping nftables also stops the dependent service and that the
guard is installed before subsequent startup.

The unprivileged system user has no capabilities, TUN access or `NET_ADMIN`.
Systemd hardening restricts filesystem/device access. State persists under
`/var/lib/lucidity-netbird-server` across generations and restarts; generated
configuration lives under `/run/lucidity-netbird-server`. Anonymous metrics and
Geolite updates are disabled. Geolocation itself is also disabled with the fixed
upstream environment switch: `disableGeoliteUpdate` alone still downloads the
initial databases and cannot provide network-independent startup. Location-based
features are therefore unavailable in this private foundation. Upstream still
attempts a nonfatal version check; the isolated VM blocks that outbound request
rather than permitting external network access. Log level is fixed at **warn** because upstream
info-level configuration dumps reveal a relay-secret prefix; missing store keys
are rejected before upstream's warning-level generation fallback.

## Verification and remaining work

Fast Python tests cover exact bytes, strict key formats, invalid paths, atomic
permissions, clean process boundaries, and real SecretSpec 0.18 with only
synthetic local files and a non-daemon probe. Flake evaluation checks both leaves
and disabled/enabled footprints. `checks.x86_64-linux.netbird-runtime-vm` runs
actual service startup, health, `/api/instance`, restart state, and IPv4/IPv6
HTTP/health/metrics/STUN guards under an intentionally permissive firewall in isolated,
egress-blocked VMs. It is part of the required hermetic CI graph; it is not run
on the development host.

No dashboard/proxy/client service, public ingress, DNS, TLS issuance, OAuth
connection, owner account, setup key or deployment is included. Account email
is chosen later in a secured browser setup, not a code option. Browser login,
TOTP enrollment/recovery, and Google federation remain separate authorized
integration work; startup tests are not proof of those flows.
