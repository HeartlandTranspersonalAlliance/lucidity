# Compare parsed declarations, not their formatting or fetched flake outputs.
expected: actual: let
  matchesExpected = builtins.all (name: let
    input = actual.${name} or null;
  in
    builtins.isAttrs input && (input.url or null) == expected.${name}) (builtins.attrNames expected);
  # Preserve the prohibition on upstream nixpkgs declarations under other names.
  noUpstreamNixpkgs = value:
    if builtins.isAttrs value
    then builtins.all noUpstreamNixpkgs (builtins.attrValues value)
    else !builtins.isString value || builtins.match ".*github:NixOS/nixpkgs.*" value == null;
in
  matchesExpected && noUpstreamNixpkgs actual
