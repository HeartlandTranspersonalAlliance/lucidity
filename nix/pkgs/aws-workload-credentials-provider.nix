{
  lib,
  rustPlatform,
  fetchFromGitHub,
}: let
  version = "3.1.1";
in
  rustPlatform.buildRustPackage {
    pname = "aws-workload-credentials-provider";
    inherit version;

    src = fetchFromGitHub {
      owner = "aws";
      repo = "aws-workload-credentials-provider";
      rev = "v${version}";
      hash = "sha256-LgeYFIoqDk5CpQd3RsDkMzY/8c2o1KX3ILqG005UVrA=";
    };

    cargoHash = "sha256-cUOELRpWVWPeYnmUtO0i+qUUIHTN/GvKkb1aDuPAae4=";
    cargoBuildFlags = [
      "--package"
      "aws_workload_credentials_provider"
    ];
    doCheck = false;

    meta = {
      description = "AWS Workload Credentials Provider";
      homepage = "https://github.com/aws/aws-workload-credentials-provider";
      license = lib.licenses.asl20;
      mainProgram = "aws-workload-credentials-provider";
      platforms = lib.platforms.linux;
    };
  }
