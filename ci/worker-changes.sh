#!/usr/bin/env bash
set -Eeuo pipefail

required=false
while IFS= read -r path; do
    case "${path}" in
        AGENTS.md|LICENSE|README.md|proposal.md|docs/*|image/README.md|tofu/*|flake.nix|flake.lock|mk/quality.mk|.github/workflows/ami-switch-benchmark.yml|.github/workflows/integration.yml|.github/workflows/validate-deployment.yml|roles/controller/*|scripts/bootstrap-controller.sh|scripts/check-text-style.sh|scripts/validate-ami-import.sh|scripts/validate-deployment.sh|scripts/vm-integration.sh|tests/test-controller.sh|tests/test-image.sh|tests/test-ami-import.sh|tests/test-text-style.sh|tests/test-deployment-validation.sh|tests/fixtures/aws|tests/fixtures/aws-deployment-validation|tests/fixtures/coldsnap|tests/fixtures/controller-*)
            ;;
        *)
            required=true
            break
            ;;
    esac
done

printf '%s\n' "${required}"
