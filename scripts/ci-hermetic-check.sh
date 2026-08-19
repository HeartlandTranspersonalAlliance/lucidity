#!/usr/bin/env bash
set -Eeuo pipefail

baseline=${HERMETIC_BASELINE_SECONDS:-510}
[[ ${baseline} =~ ^[0-9]+$ ]] || {
    echo "HERMETIC_BASELINE_SECONDS must be a non-negative integer" >&2
    exit 2
}

started_at=$(date +%s)
set +e
nix flake check --show-trace --print-build-logs
status=$?
set -e
finished_at=$(date +%s)
elapsed=$((finished_at - started_at))
difference=$((baseline - elapsed))
if ((difference >= 0)); then
    comparison="${difference}s faster"
else
    comparison="$((-difference))s slower"
fi
if ((status == 0)); then
    outcome=success
else
    outcome=failure
fi

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
        echo '### Hermetic Nix graph cache performance'
        echo
        echo "- Outcome: \`${outcome}\`"
        echo "- Observed: ${elapsed}s"
        echo "- Pre-cache baseline: ${baseline}s (8m30s)"
        echo "- Difference: ${comparison}"
    } >>"${GITHUB_STEP_SUMMARY}"
fi

exit "${status}"
