#!/usr/bin/env bash
# Compare the production graph to a reviewed pre-migration git revision.
set -Eeuo pipefail
baseline_revision=${1:?usage: test-dendritic-parity.sh BASELINE_GIT_REVISION}
root=$(git rev-parse --show-toplevel)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/baseline"
git -C "$root" archive "$baseline_revision" | tar -x -C "$tmp/baseline"
expression='p: builtins.mapAttrs (_: x: x.drvPath) {
  inherit (p) awsConfig awsProductionVars awsTestVars
    host-manifest-controller host-manifest-worker
    bootc-context-controller bootc-context-worker;
}'
for source in baseline current; do
    directory=$root
    if [[ $source == baseline ]]; then directory=$tmp/baseline; fi
    nix eval --json "path:$directory#packages.x86_64-linux" \
        --apply "$expression" >"$tmp/$source.json"
done
diff -u "$tmp/baseline.json" "$tmp/current.json"
printf '%s\n' 'Legacy bootc, manifests, and Terranix derivations are unchanged.'
