{
  awscli2,
  fetchurl,
  lib,
  makeWrapper,
  python3,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "asm-exec";
  version = "0-unstable-2026-08-15";

  src = fetchurl {
    url = "https://raw.githubusercontent.com/aws/agent-toolkit-for-aws/957cf377ea1dffccf1f8a54ded2be8666b6db41c/plugins/aws-core/skills/aws-secrets-manager/references/asm-exec";
    hash = "sha256-1V6zitM6W3b1hMoYD2M+zBIM85uP0pQn/74RqPvxlVY=";
  };

  nativeBuildInputs = [makeWrapper];
  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -D -m 0644 "$src" "$out/libexec/asm-exec.py"
    makeWrapper ${python3}/bin/python "$out/bin/asm-exec" \
      --add-flags "$out/libexec/asm-exec.py" \
      --prefix PATH : ${lib.makeBinPath [awscli2]}
    runHook postInstall
  '';

  meta = {
    description = "Runtime resolver for AWS Secrets Manager dynamic references";
    homepage = "https://github.com/aws/agent-toolkit-for-aws";
    license = lib.licenses.asl20;
    mainProgram = "asm-exec";
    platforms = lib.platforms.linux;
  };
}
