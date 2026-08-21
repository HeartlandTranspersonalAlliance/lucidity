{
  lib,
  buildNpmPackage,
  makeWrapper,
  nodejs_22,
  ooyeSrc,
}:
buildNpmPackage {
  pname = "out-of-your-element";
  version = "3.6.0";
  src = ooyeSrc;

  npmDepsHash = "sha256-h1mmE0/+Y7SBwnI0vaYvV+KqRDJGzwJvDUOkigzHcOY=";
  nodejs = nodejs_22;
  dontNpmBuild = true;
  nativeBuildInputs = [makeWrapper];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/ooye" "$out/bin"
    cp -R . "$out/lib/ooye"
    makeWrapper ${nodejs_22}/bin/node "$out/bin/ooye" \
      --set OOYE_ROOT "$out/lib/ooye" \
      --add-flags "--enable-source-maps $out/lib/ooye/start.js"
    runHook postInstall
  '';

  meta = {
    description = "Matrix to Discord bridge";
    homepage = "https://gitdab.com/cadence/out-of-your-element";
    license = lib.licenses.agpl3Plus;
    mainProgram = "ooye";
    platforms = ["x86_64-linux"];
  };
}
