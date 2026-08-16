#!/usr/bin/env bash
set -Eeuo pipefail

required=false
while IFS= read -r path; do
    case "${path}" in
        AGENTS.md|LICENSE|README.md|proposal.md|docs/*|image/README.md|tofu/*|flake.nix|flake.lock|roles/worker/*|scripts/bootstrap-worker.sh|tests/test-worker.sh|tests/test-image.sh|tests/test-ami-import.sh|tests/fixtures/aws|tests/fixtures/coldsnap|tests/fixtures/worker-*)
            ;;
        *)
            required=true
            break
            ;;
    esac
done

printf '%s\n' "${required}"
