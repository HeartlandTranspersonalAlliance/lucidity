# Native NetBird dashboard package

This increment builds **dashboard 2.96.0** as a native Nix static export. It does
not start a server, configure authentication, create users, open ports, change the
bootc controller, or deploy anything. It is independent of the native headless
server package. Existing root inputs, legacy packages and hosts remain unchanged.

```console
nix build .#netbird-dashboard
nix build .#checks.x86_64-linux.netbird-dashboard-module
nix build .#checks.x86_64-linux.netbird-dashboard-source
nix build .#checks.x86_64-linux.netbird-dashboard-static
```

The last check depends on the **real package build**, verifies every bundled asset
and public placeholder in the actual export, and runs in the existing hermetic
`nix flake check` CI graph. It does not run a web server or authenticate users.
An evaluated derivation or successful dry-run is not a successful Next.js build.

## Optional NixOS package installation

Import `inputs.lucidity.nixosModules.lucidity-netbird-dashboard`, then opt in:

```nix
lucidity.netbird.dashboard.enable = true;
```

Disabled imports have no effect. Enabled imports add only the static package to
`environment.systemPackages`, not a service. Files are at the package output root
(`index.html`, `_next/static`, assets and licenses); there is no Node runtime or
executable. A future serving module should reference the package output directly.
It is intentionally not included in the foundation feature or any host.

## Reproducibility and licenses

- Dashboard source: [v2.96.0](https://github.com/netbirdio/dashboard/tree/v2.96.0),
  commit `d8b0aa3af0dd2ae23d0a59b7dd1446299b6510af`, **AGPL-3.0-only**, not the BSD
  metadata of the older root package.
- `npmDepsHash` was measured with the root-pinned `prefetch-npm-deps`, cache format
  1, against the unmodified upstream lockfile. This package constructs its own
  dependencies from its own source; it does not inherit older npm dependencies.
  Recompute with `prefetch-npm-deps package-lock.json` when updating source.
- Inter is the upstream committed local font, with its SIL OFL license. No Google
  Fonts build fetch is needed. Next telemetry is disabled.
- The four [IronRDP v0.0.2 release assets](https://github.com/netbirdio/IronRDP/releases/tag/v0.0.2)
  keep their exact upstream filenames under `/ironrdp-pkg/`. SHA256 pins match the
  official release asset digests. MIT and Apache license texts are included.
- Browser networking WASM is the official
  [NetBird v0.81.3 release](https://github.com/netbirdio/netbird/releases/tag/v0.81.3)
  `netbird_0.81.3.wasm` (60,406,765 bytes), whose GitHub digest agrees with
  `netbird_0.81.3_checksums.txt`. It is bundled at `/netbird-client.wasm`; only the
  upstream remote fallback is patched to this same-origin path. It is deliberately
  **not** bumped to the headless server's version. Client code is BSD3 under the
  upstream root license's directory exceptions.
- Committed `/wasm_exec.js` exactly matches Go 1.26.7's runtime, the client release's
  pinned build toolchain. Its bytes are checked; Go's BSD license is included.
- `licenses/` includes the dashboard, font, IronRDP, browser client and Go licenses,
  upstream's generated third-party license report, and source references. When
  distributing modified AGPL software, separately satisfy applicable corresponding
  source obligations; including license text alone is not sufficient.

## Runtime boundary: not a configured UI

The immutable export intentionally retains all **27 public configuration
placeholders**, enumerated in
[`runtime-placeholders.json`](../../nix/pkgs/netbird-dashboard/runtime-placeholders.json).
There are no secret values. A future service must render all fields with correct
JSON/JavaScript escaping into a separate served tree, and render the API endpoint
in `OidcTrustedDomains.js.tmpl`; do not use unescaped shell substitutions.

`AUTH_CLIENT_SECRET` must be empty for this public browser client. Mandatory
API/OIDC settings must be validated, not silently replaced with empty defaults.
Unused analytics, announcement and HubSpot values should be empty and boolean
settings explicitly false. The manifest's defaults are guidance, not a deployed
configuration. Local administrator setup and Google federation are deferred.

`NETBIRD_WASM_PATH` remains a public override; rendering it empty selects the
bundled same-origin browser client. A configured external URL deliberately
reintroduces an external runtime dependency. The assets are locally bundled, but
this does **not** mean an offline application: configured management, OIDC, relay
and user-selected remote-access destinations still require networking.
Serve WASM as `application/wasm` and support static `uri`/`uri.html` routes.
Require cache revalidation for `/netbird-client.wasm` and `/wasm_exec.js` on
upgrades so browsers do not mix different client and Go runtime versions.
Browser SSH/RDP, login, interrupted sessions and live backend compatibility need
later integration tests; static asset checks do not establish those behaviors.

## Verification boundary for this draft

Local checks cover source contracts, Nix evaluation, formatting and the build
plan. A full npm/Next build is deferred to mandatory CI because the development
workspace has only about 3 GiB free and must preserve a 2 GiB floor. Do not mark
this increment merge-ready until the real static build check passes. No backend,
UI listener, accounts, authentication, AWS or DNS were used for this increment.
