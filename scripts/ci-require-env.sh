#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -gt 0 ]] || {
    echo "usage: ci-require-env NAME [NAME ...]" >&2
    exit 2
}

for name in "$@"; do
    [[ ${name} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        echo "invalid environment variable name: ${name}" >&2
        exit 2
    }
    [[ -n ${!name:-} ]] || {
        echo "::error::${name} is required for this workflow event" >&2
        exit 1
    }
done
