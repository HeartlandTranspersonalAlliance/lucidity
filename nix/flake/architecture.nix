{
  den,
  inputs,
  ...
}: {
  perSystem = {pkgs, ...}: let
    diagram = inputs.den-diagram.lib;
    renderContext = diagram.renderContext {inherit pkgs;};
    namespaceGraph = diagram.graph.ofNamespace {
      aspects = den.aspects or {};
    };
    namespaceSource = renderContext.renderDense.toMermaid namespaceGraph;
    architecture = pkgs.writeText "lucidity-aspect-namespace.mmd" namespaceSource;
    architectureApp = pkgs.writeShellApplication {
      name = "lucidity-architecture";
      runtimeInputs = [pkgs.coreutils];
      text = ''
        cat ${architecture}
      '';
    };
  in {
    packages.architecture = architecture;
    apps.architecture.program = "${architectureApp}/bin/lucidity-architecture";
    checks.architecture = pkgs.runCommand "lucidity-architecture-check" {} ''
      grep -Fq 'bootc-common' ${architecture}
      grep -Fq 'controller' ${architecture}
      grep -Fq 'worker' ${architecture}
      cp ${architecture} "$out"
    '';
  };
}
