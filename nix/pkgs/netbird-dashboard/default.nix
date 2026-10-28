# Native static export. No service enablement or deployment settings.
{pkgs}: let
  version = "2.96.0";
  ironRdpVersion = "0.0.2";
  clientVersion = "0.81.3";
  # GitHub release asset digest agrees with the official release checksums file.
  client = pkgs.fetchurl {
    url = "https://github.com/netbirdio/netbird/releases/download/v${clientVersion}/netbird_${clientVersion}.wasm";
    sha256 = "7823ff6ed813387cebb4f0337da4acd81f09d0c5cd40ed99f069340aa38140a0";
  };
  clientLicense = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/netbirdio/netbird/v${clientVersion}/LICENSE";
    sha256 = "8343fe949e32a30e2261c4f0967365271d08c4644e879dec5b998d1af666fdb3";
  };
  goLicense = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/golang/go/go1.26.7/LICENSE";
    sha256 = "911f8f5782931320f5b8d1160a76365b83aea6447ee6c04fa6d5591467db9dad";
  };
  assetHashes = {
    "ironrdp_web.d.ts" = "a7818512bb18bd5cc3f237d616e6a203742c7152a60aaffca336b8f12dc67678";
    "ironrdp_web.js" = "d325a35d6c86d7a83f0ca48079898323ec03d96c6f93ba2f824317476bcda207";
    "ironrdp_web_bg.wasm" = "7f83df3fdd07985e90e74f932aa9a0ad4fa3debb07d36b3430004f1b2c20ae33";
    "ironrdp_web_bg.wasm.d.ts" = "df61fad9d7c70c9b4f850be687efb699f10676da3b6dd989e384985c8d387fa1";
  };
  assets = pkgs.lib.mapAttrs (name: sha256:
    pkgs.fetchurl {
      inherit name sha256;
      url = "https://github.com/netbirdio/IronRDP/releases/download/v${ironRdpVersion}/${name}";
    })
  assetHashes;
  licenseHashes = {
    "LICENSE-MIT" = "23f18e03dc49df91622fe2a76176497404e46ced8a715d9d2b67a7446571cca3";
    "LICENSE-APACHE" = "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30";
  };
  licenses = pkgs.lib.mapAttrs (name: sha256:
    pkgs.fetchurl {
      inherit sha256;
      name = "IronRDP-${name}";
      url = "https://raw.githubusercontent.com/netbirdio/IronRDP/v${ironRdpVersion}/${name}";
    })
  licenseHashes;
in
  pkgs.buildNpmPackage rec {
    pname = "netbird-dashboard";
    inherit version;
    src = pkgs.fetchFromGitHub {
      owner = "netbirdio";
      repo = "dashboard";
      tag = "v${version}";
      hash = "sha256-pQ876Thp4om6RmLpJAAJUX8J2gcXwjV8WIxjyuzkri0=";
    };
    # Measured with root-pinned prefetch-npm-deps, unmodified upstream lockfile.
    npmDepsHash = "sha256-PiRXoYa/TQ/jTSw9E6V8HYM6t2Hl20fuPu6zx6s9WpM=";
    npmDepsFetcherVersion = 1;
    # Construct dependencies from this source, never the root's older dashboard.
    npmDeps = pkgs.fetchNpmDeps {
      inherit src;
      name = "netbird-dashboard-${version}-npm-deps";
      hash = npmDepsHash;
      fetcherVersion = 1;
    };
    npmFlags = ["--legacy-peer-deps"];
    env = {
      CYPRESS_INSTALL_BINARY = "0";
      NEXT_PUBLIC_DASHBOARD_VERSION = version;
      NEXT_TELEMETRY_DISABLED = "1";
    };
    postPatch = ''
      substituteInPlace src/utils/config.ts \
        --replace-fail 'https://pkgs.netbird.io/wasm/client/v0.81.3' '/netbird-client.wasm'
    '';
    preBuild = ''
      echo '{}' > .local-config.json
      cp ${client} public/netbird-client.wasm
      mkdir -p public/ironrdp-pkg
      ${pkgs.lib.concatStringsSep "\n" (pkgs.lib.mapAttrsToList (name: asset: "cp ${asset} public/ironrdp-pkg/${name}") assets)}
    '';
    postBuild = ''
      mkdir -p out/licenses
      cp ${clientLicense} out/licenses/netbird-client-LICENSE
      cp ${goLicense} out/licenses/Go-LICENSE
      cp LICENSE out/licenses/netbird-dashboard-LICENSE
      cp src/assets/fonts/OFL.txt out/licenses/Inter-OFL.txt
      node docker/third-party-licenses.mjs > out/licenses/THIRD-PARTY-LICENSES.txt
      ${pkgs.lib.concatStringsSep "\n" (pkgs.lib.mapAttrsToList (name: license: "cp ${license} out/licenses/IronRDP-${name}") licenses)}
      printf '%s\n' \
        'Dashboard source: https://github.com/netbirdio/dashboard/tree/v${version}' \
        'Browser client source: https://github.com/netbirdio/netbird/tree/v${clientVersion}' \
        'Go runtime source: https://github.com/golang/go/tree/go1.26.7' \
        'IronRDP source: https://github.com/netbirdio/IronRDP/tree/v${ironRdpVersion}' \
        > out/licenses/SOURCES.txt
      test -f out/index.html
      test -d out/_next/static
      test -s out/ironrdp-pkg/ironrdp_web_bg.wasm
      test -f out/OidcTrustedDomains.js.tmpl
    '';
    installPhase = ''
      runHook preInstall
      cp -R out "$out"
      runHook postInstall
    '';
    meta = {
      description = "NetBird management dashboard static export";
      homepage = "https://github.com/netbirdio/dashboard";
      platforms = pkgs.lib.platforms.linux;
      # v2.96.0 changed from the BSD license inherited by older nixpkgs versions.
      license = pkgs.lib.licenses.agpl3Only;
    };
  }
