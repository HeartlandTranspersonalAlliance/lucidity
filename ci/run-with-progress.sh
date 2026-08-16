#!/usr/bin/env bash
set -Eeuo pipefail

label=${1:?usage: run-with-progress.sh LABEL COMMAND [ARGUMENT...]}
shift
[[ $# -gt 0 ]] || { echo "a command is required" >&2; exit 2; }

interval=${LUCIDITY_PROGRESS_INTERVAL_SECONDS:-60}
[[ ${interval} =~ ^[1-9][0-9]*$ ]] || {
    echo "LUCIDITY_PROGRESS_INTERVAL_SECONDS must be a positive integer" >&2
    exit 2
}
[[ ${label} != *$'\n'* && ${label} != *$'\r'* ]] || {
    echo "the progress label must be a single line" >&2
    exit 2
}

started=${SECONDS}
echo "${label}: started"
"$@" &
child=$!

# Invoked indirectly by the signal trap below.
# shellcheck disable=SC2329
forward_signal() {
    kill -TERM "${child}" 2>/dev/null || true
    wait "${child}" 2>/dev/null || true
    exit 130
}
trap forward_signal INT TERM

next_report=${interval}
while kill -0 "${child}" 2>/dev/null; do
    sleep 1
    elapsed=$((SECONDS - started))
    if ((elapsed >= next_report)) && kill -0 "${child}" 2>/dev/null; then
        echo "${label}: still running (${elapsed}s elapsed)"
        next_report=$((next_report + interval))
    fi
done

if wait "${child}"; then
    status=0
else
    status=$?
fi
elapsed=$((SECONDS - started))
echo "${label}: finished with status ${status} (${elapsed}s elapsed)"
exit "${status}"
