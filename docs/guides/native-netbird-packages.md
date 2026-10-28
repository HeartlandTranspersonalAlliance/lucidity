# Native NetBird packages (opt-in, no deployment)

This increment supplies three headless native binaries from one upstream release:

| Flake package | Binary | Upstream source entrypoint |
| --- | --- | --- |
| `netbird-client` | `netbird` | `client` |
| `netbird-server` | `netbird-server` | `combined` |
| `netbird-proxy` | `netbird-proxy` | `proxy/cmd/proxy` |

Build and verify with the existing locked toolchain:

```sh
nix build .#netbird-client .#netbird-server .#netbird-proxy
nix build .#checks.x86_64-linux.netbird-packages-eval
nix build .#checks.x86_64-linux.netbird-packages-smoke
```

The smoke check builds all three Nix derivations, checks binary names, runs
client/proxy version and server/proxy help, and verifies Go entrypoint metadata.
Combined has no version command; evaluation assertions check its shared source
and version linker flag (Go omits linker flags from `-trimpath` build metadata). The existing hermetic CI graph (`nix flake check`) includes these
checks. This is packaging verification, not startup, authentication, or network
integration testing. Upstream network-dependent Go tests remain disabled, as in
the inherited nixpkgs packages.

## Den ownership and opt-in boundary

`modules/features/netbird.nix` owns the `lucidity-netbird-packages` Den aspect,
standalone NixOS module, package exports, and checks. Its plain package function
lives at `nix/pkgs/netbird.nix`, outside import-tree's `modules/` tree. No new flake
input or generated-flake edit is needed.

Import `nixosModules.lucidity-netbird-packages` and set
`lucidity.netbird.packages.enable = true` to install the binaries only. The feature
is not automatically included in the foundation or existing hosts. Evaluation
checks compare enabled and disabled system footprints: no new services, timers,
users, firewall ports, `/etc` files, or Podman activation. Legacy bootc outputs,
OCI pins, host manifests and Terranix are unchanged.

This package-only module does **not** enable the older nixpkgs NetBird server
service, start a client, configure DNS or AWS, create an account, generate keys,
read secrets, or deploy anything. The foundation's wrappers, standalone SecretSpec
CLI and named devenv shell remain unchanged. Runtime SecretSpec wiring belongs to
a later service increment, not package evaluation.

## Source provenance

All three binaries use [NetBird v0.81.5](https://github.com/netbirdio/netbird/releases/tag/v0.81.5),
commit `396976b8be081fbf0d3d959698352585e80618e3`:

- Source NAR SHA-256: `sha256-Ma5ngsTqcblG6uLCn7IcSvI9vUhbIs4gr2nD4ZBdTAo=`.
- Go proxy-vendor output: `sha256-TlW+Y4n3sImdBQ6qXQgfKndNftQDLwu8YsqucVCIfyY=`.
- Both hashes were measured from actual upstream content; the Go dependency
  fixed output was additionally validated by Nix/cache substitution.
- Upstream's cookie-group authorization fix
  [#7240](https://github.com/netbirdio/netbird/pull/7240), commit
  `c2b5d211d94b855a8b69c7b3f7e392ddce25019b`, is an ancestor of this release.
- Root nixpkgs stays at `279b4a8275f032c566576b3f181fa0f27197f588`.
  Its Go 1.26.5 satisfies upstream's documented minimum 1.26.2. `GOTOOLCHAIN=local`
  prevents silently switching to upstream's suggested Go 1.26.10.

The derivations reuse native nixpkgs packaging and client socket patches, disable
unused UI-only pnpm dependencies, and add the combined entrypoint with CGO for
SQLite. The proxy embeds its committed `proxy/web/dist` assets without an extra
frontend build. No container image or precompiled upstream binary is used.

## Explicitly deferred

The separate dashboard release is v2.96.0, not v0.81.5. It is not exported in this
increment: its npm dependency hash and full static build still need verification,
including the official IronRDP JS/WASM assets. No placeholder dependency hash or
incomplete dashboard package is shipped.

Follow-on service work must separately verify runtime-only per-service secret
injection, restrictive state/config permissions, frontend routing, setup access
control, embedded-IdP owner bootstrap, TOTP, persistence and authorization
regressions. Do not infer these properties from a successful help/version smoke
check. In particular, never pass a shared broad `NB_*` credential environment to
the combined server; upstream logs some unmasked variable names.
