{...}: {
  perSystem = {...}: {
    treefmt = {
      projectRootFile = "flake.nix";
      programs = {
        actionlint.enable = true;
        alejandra.enable = true;
        deadnix.enable = true;
        shellcheck.enable = true;
      };
      settings.formatter = {
        deadnix.priority = 1;
        alejandra.priority = 2;
      };
    };
  };
}
