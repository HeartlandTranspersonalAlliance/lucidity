{inputs, ...}: {
  imports = [inputs.den.flakeModules.default];

  _module.args.inputs = inputs;

  den.systems = ["x86_64-linux"];
}
