# Plain package function: deliberately outside the automatic modules/ import tree.
{pkgs}: let
  version = "0.81.5";
  src = pkgs.fetchFromGitHub {
    owner = "netbirdio";
    repo = "netbird";
    tag = "v${version}";
    hash = "sha256-Ma5ngsTqcblG6uLCn7IcSvI9vUhbIs4gr2nD4ZBdTAo=";
  };
  update = old: {
    inherit version src;
    vendorHash = "sha256-TlW+Y4n3sImdBQ6qXQgfKndNftQDLwu8YsqucVCIfyY=";
    # The inherited monorepo derivation otherwise fetches unused UI dependencies.
    pnpmDeps = null;
    # Also apply to module fetching; use the locked Go, never download a toolchain.
    env = (old.env or {}) // {GOTOOLCHAIN = "local";};
    ldflags = [
      "-s"
      "-w"
      "-X github.com/netbirdio/netbird/version.version=${version}"
      "-X main.builtBy=nix"
    ];
    # Do not advertise inherited tests of the older nixpkgs component set.
    passthru = (old.passthru or {}) // {tests = {};};
  };
in {
  client = pkgs.netbird.overrideAttrs update;
  proxy = pkgs.netbird-proxy.overrideAttrs (old:
    (update old)
    // {
      env =
        (old.env or {})
        // {
          GOTOOLCHAIN = "local";
          CGO_ENABLED = 0;
        };
      ldflags = (update old).ldflags ++ ["-X main.Version=${version}"];
    });
  server = pkgs.netbird-management.overrideAttrs (old:
    (update old)
    // {
      pname = "netbird-server";
      # v0.81.5 discards the configured host and opens legacy :33073 otherwise.
      patches = (old.patches or []) ++ [./netbird-combined-listen-address.patch];
      subPackages = ["combined"];
      env =
        (old.env or {})
        // {
          GOTOOLCHAIN = "local";
          CGO_ENABLED = 1;
        };
      postInstall = "mv $out/bin/combined $out/bin/netbird-server";
      # Combined has --help but no --version; the feature checks verify its entrypoint and version flags.
      nativeInstallCheckInputs = [];
      doInstallCheck = false;
      meta =
        old.meta
        // {
          description = "NetBird combined management, signal, relay and embedded IdP server";
          mainProgram = "netbird-server";
        };
    });
}
