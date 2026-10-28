# Native NixOS foundation (opt-in)

This is the first, non-deploying migration slice. Existing controller and worker
bootc outputs and Terranix infrastructure remain unchanged. There are no new
hosts, AMIs, AWS resources, DNS records, or running NetBird services.

## Dendritic ownership

`flake.nix` is generated. Edit the relevant module, then run:

```console
nix run .#write-flake
nix build .#checks.x86_64-linux.check-flake-file
nix build .#checks.x86_64-linux.nixos-foundation
```

The entrypoint uses `import-tree ./modules`. Every file in that dedicated tree
is a flake-parts module. New feature files are discovered automatically; there
is no central list of feature imports. Do not switch this to `import-tree ./nix`:
that legacy tree also contains package functions and non-flake-parts modules.
`modules/legacy.nix` explicitly bridges the existing graph.

The composition follows the [pinned Den template](https://github.com/denful/den/blob/e8e8de1e32646456cfc613f152175a7a548508ec/templates/default/modules/dendritic.nix):
`flake-file.flakeModules.dendritic` and `den.flakeModules.dendritic`.
Each small feature owns a Den aspect; the foundation includes those aspects.
Exports use Den's documented `den.lib.aspects.resolve "nixos" aspect`, including
transitive aspect dependencies rather than copying only an aspect's `nixos`
attribute. See the pinned [aspect resolution documentation](https://github.com/denful/den/blob/e8e8de1e32646456cfc613f152175a7a548508ec/docs/src/content/docs/explanation/aspects.mdx).

Feature-owned external inputs live with their feature. Shared and legacy input
declarations live in `modules/dendritic.nix`. New inputs have immutable revisions
and Nix-generated hashes; existing locked input revisions are retained.

## Consume without provisioning a host

Another NixOS flake can import `inputs.lucidity.nixosModules.lucidity`, or select
`lucidity-tools`, `lucidity-quadlet`, and `lucidity-secretspec` individually.
Importing them alone is inert. Enable only the desired feature:

```nix
{
  imports = [ inputs.lucidity.nixosModules.lucidity ];
  lucidity.foundation.enable = true; # journald retention only
  lucidity.tools.enable = true;      # wrapped lucidity-curl and jq
  lucidity.secretspec.enable = true; # standalone operator CLI only
  # lucidity.quadlet.enable remains false
}
```

These modules do not choose users, SSH keys, firewall ports, disks, hostnames,
or `system.stateVersion`. The consuming host owns those decisions. Enabling the
foundation does not implicitly enable the other features.

The curl wrapper uses [lassulus/wrappers](https://github.com/lassulus/wrappers/tree/37d05efcab820ef96f083b251040ae2848445959)
with a declared CA bundle, HTTP failure reporting, and connection timeout.
It is not claimed to be a Den-provided wrapper recipe. New runtime programs
should likewise keep package, flags, environment, and dependencies feature-owned.

## Optional Quadlets

The adapter imports [SEIAROTg/quadlet-nix](https://github.com/SEIAROTg/quadlet-nix/tree/db3af9df6943692c78cf9a05e3bfeb7d82e94cf3)
`nixosModules.quadlet`. Its schema uses lower-case `containerConfig.image`, not
another Quadlet implementation's `Image` or `imagePackage` options.

```nix
{
  lucidity.quadlet.enable = true;
  virtualisation.quadlet.containers.example = {
    autoStart = false;
    containerConfig.image = "localhost/my-reviewed-image:local";
  };
}
```

Replace the example with a reviewed image, preferably digest-pinned, before use.
This documentation does not create or run a container. Upstream `autoStart`
defaults to true: explicitly set it false while preparing a workload. Lucidity
sets the adapter's default enablement to false even when objects are declared.
Directly overriding `virtualisation.quadlet.enable` is an explicit upstream
escape hatch. The enabled adapter turns on Podman, not Docker. Quomodo is not
installed; a later isolated optional aspect can use this interface.

## Development shell with devenv

The named `devenv` shell uses the supported [devenv flake-parts integration](https://devenv.sh/guides/using-with-flake-parts/).
The existing default shell is unchanged. From the repository root:

```console
env -u SECRETSPEC_SECRETS nix develop --impure .#devenv
secretspec --version
```

It supplies the standalone SecretSpec CLI, Alejandra, deadnix, jq, OpenTofu,
and shellcheck. `--impure` lets devenv determine the working directory using
`PWD`; it is not used to retrieve secrets. Pure flake evaluation uses the flake
source path only as a check-time root fallback. Do not enter this shell without
`--impure`, or use the immutable store fallback as a writable project directory.
Local state is kept in ignored `.devenv/`.

There are no shell-entry provider lookups, processes, or services. Unsetting
`SECRETSPEC_SECRETS` avoids accidentally activating devenv's unsupported
flake-time secret integration from an inherited environment. That integration
is imported by upstream devenv but is not enabled here; SecretSpec is only a
CLI package. Use synthetic fixtures for tests, never live credentials.

## SecretSpec boundary

The standalone SecretSpec CLI comes from the existing locked nixpkgs. It can
be used in a flake-built environment; devenv's evaluation-time SecretSpec
integration is not enabled or emulated. This feature installs the CLI only:
no provider is contacted, credentials rendered, manifest injected into a daemon,
or secret read during evaluation or build.

AWS-hosted runtime secrets must retain the repository's `asm-exec` dynamic
reference contract (`{{resolve:secretsmanager:secret-id:SecretString:json-key}}`).
Do not call Secrets Manager value APIs or substitute a direct SecretSpec AWS
provider lookup for that contract. A future daemon wrapper must fail closed
when its runtime references are absent. Operator OpenBao aliases with
`credentials.token = "local-keyring"` must not be reused as unattended daemon
aliases: they can override the daemon's intended token-file authentication.
Legacy runtime wiring is intentionally unchanged in this compatibility PR.

## Validation and next slices

`nixos-foundation` compares an imported-but-disabled configuration with plain
NixOS: no extra services, timers, ports, etc files, or Podman activation. It also
checks a declared-but-disabled Quadlet, an explicitly enabled Quadlet's generated
configuration with autostart off, journald settings, and the built curl wrapper.
`check-flake-file` checks generation reproducibility.

To compare the legacy production outputs against a reviewed git revision:

```console
bash tests/test-dendritic-parity.sh BASELINE_GIT_REVISION
```

This checks exact derivation identity for both bootc contexts, both host
manifests, AWS configuration, and production/test variable files. It evaluates
only and performs no cloud operations.

Do not add NixOS hosts to `den.hosts` yet. The legacy bootc schema currently
extends every host and Terranix enumerates every host as AWS facts. A later
host-integration PR must scope both before adding native hosts.

Subsequent reviewable slices will package native NetBird combined server/proxy
and dashboard, then connect runtime secret contracts and local Owner bootstrap.
Google login is deferred. Native deployment will consume official
DeterminateSystems/nixos-amis directly (vendor account `535002876703`, epoch 1,
region and x86_64 selection with a reviewed pin), not build or copy custom AMIs.
Cloudflare changes remain plan-only until separately authorized. Nothing here
is a production migration or authorizes an infrastructure apply.
