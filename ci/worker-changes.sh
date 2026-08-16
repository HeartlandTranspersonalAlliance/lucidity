#!/usr/bin/env bash
set -Eeuo pipefail

required=false
while IFS= read -r path; do
    case "${path}" in
        AGENTS.md|LICENSE|README.md|proposal.md|docs/*|image/README.md|tofu/*|flake.nix|flake.lock|mk/quality.mk|roles/controller/*|scripts/bootstrap-controller.sh|scripts/check-text-style.sh|tests/test-controller.sh|tests/test-image.sh|tests/test-ami-import.sh|tests/test-text-style.sh|tests/fixtures/aws|tests/fixtures/coldsnap|tests/fixtures/controller-*)
            ;;
        *)
            required=true
            break
            ;;
    esac
done

printf '%s\n' "${required}"
