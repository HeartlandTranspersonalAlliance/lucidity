#!/usr/bin/env bash
set -Eeuo pipefail

repo=${1:-.}
failures=0

while IFS= read -r -d '' file; do
  path=${repo}/${file}
  [[ -f ${path} && ! -L ${path} && -s ${path} ]] || continue

  # Git's binary heuristic keeps generated and binary artifacts out of text policy.
  LC_ALL=C grep -Iq '' -- "${path}" || continue

  if LC_ALL=C grep -qE '[[:blank:]]+$' -- "${path}"; then
    printf 'tracked text has trailing whitespace: %s\n' "${file}" >&2
    failures=1
  fi

  if LC_ALL=C grep -q $'\r' -- "${path}"; then
    printf 'tracked text must use LF line endings: %s\n' "${file}" >&2
    failures=1
  fi

  last_byte=$(tail -c 1 -- "${path}" | od -An -tuC)
  last_byte=${last_byte//[[:space:]]/}
  if [[ ${last_byte} != 10 ]]; then
    printf 'tracked text must end with a newline: %s\n' "${file}" >&2
    failures=1
  fi
done < <(git -C "${repo}" ls-files -z)

exit "${failures}"
