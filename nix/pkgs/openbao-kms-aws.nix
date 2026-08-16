{
  lib,
  buildGoModule,
  openbaoPluginsSrc,
}:
buildGoModule {
  pname = "openbao-plugin-kms-aws";
  version = "0-unstable-2026-08-15";
  src = openbaoPluginsSrc;
  vendorHash = "sha256-O9bJLRyepuz1zFp5o786UfMkzHKbglJbGhWSUmEoFis=";
  subPackages = ["kms/aws/cmd"];

  postInstall = ''
    mv "$out/bin/cmd" "$out/bin/openbao-plugin-kms-aws"
  '';

  meta = {
    description = "AWS KMS auto-unseal plugin for OpenBao";
    homepage = "https://github.com/openbao/openbao-plugins";
    license = lib.licenses.mpl20;
    mainProgram = "openbao-plugin-kms-aws";
    platforms = lib.platforms.linux;
  };
}
