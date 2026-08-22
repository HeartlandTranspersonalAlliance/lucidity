{
  lib,
  buildGoModule,
  openbaoPluginsSrc,
}:
buildGoModule {
  pname = "openbao-plugin-auth-aws";
  version = "0-unstable-2026-08-15";
  src = openbaoPluginsSrc;
  vendorHash = "sha256-O9bJLRyepuz1zFp5o786UfMkzHKbglJbGhWSUmEoFis=";
  subPackages = ["auth/aws/cmd"];

  postInstall = ''
    mv "$out/bin/cmd" "$out/bin/openbao-plugin-auth-aws"
    sha256sum "$out/bin/openbao-plugin-auth-aws" > "$out/bin/openbao-plugin-auth-aws.sha256"
  '';

  meta = {
    description = "External AWS authentication plugin for OpenBao";
    homepage = "https://github.com/openbao/openbao-plugins";
    license = lib.licenses.mpl20;
    mainProgram = "openbao-plugin-auth-aws";
    platforms = lib.platforms.linux;
  };
}
