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
    qemu-utils
    ripgrep
    secretspec
    shellcheck
    syft
    xorriso
  ];
  text = builtins.readFile ./lucidity.sh;
}
