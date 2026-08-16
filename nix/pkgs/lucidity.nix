{pkgs}:
pkgs.writeShellApplication {
  name = "lucidity";
  runtimeInputs = with pkgs; [
    awscli2
    coreutils
    findutils
    gawk
    git
    gnugrep
    gnused
    jq
    nix
    nebula
    openbao
    openssh
    opentofu
    podman
    ripgrep
    secretspec
    shellcheck
    syft
  ];
  text = builtins.readFile ./lucidity.sh;
}
