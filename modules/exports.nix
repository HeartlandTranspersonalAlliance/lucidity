{den, ...}: {
  # Resolve the include graph without creating hosts or AWS facts. The legacy
  # bootc schema and Terranix host enumeration remain isolated and unchanged.
  flake.nixosModules = {
    lucidity = den.lib.aspects.resolve "nixos" den.aspects.lucidity-foundation;
    lucidity-tools = den.lib.aspects.resolve "nixos" den.aspects.lucidity-tools;
    lucidity-quadlet = den.lib.aspects.resolve "nixos" den.aspects.lucidity-quadlet;
    lucidity-secretspec = den.lib.aspects.resolve "nixos" den.aspects.lucidity-secretspec;
  };
}
