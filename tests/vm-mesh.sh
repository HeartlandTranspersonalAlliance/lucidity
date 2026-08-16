#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
nix build "$repo_root#checks.x86_64-linux.mesh-vm" --print-build-logs
