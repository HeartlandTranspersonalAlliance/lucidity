#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
checker=${repo_root}/scripts/check-text-style.sh
test_root=$(mktemp -d)
trap 'rm -rf -- "${test_root}"' EXIT

test_repo=${test_root}/repo
git init --quiet "${test_repo}"

printf 'clean\n' > "${test_repo}/clean name.txt"
printf '\000\377' > "${test_repo}/binary.bin"
git -C "${test_repo}" add -- "clean name.txt" binary.bin
bash "${checker}" "${test_repo}"

printf 'untracked without newline' > "${test_repo}/untracked.txt"
bash "${checker}" "${test_repo}"

printf 'trailing space \n' > "${test_repo}/trailing.txt"
printf 'missing final newline' > "${test_repo}/missing-final-newline.txt"
printf 'CRLF\r\n' > "${test_repo}/crlf.txt"
git -C "${test_repo}" add -- trailing.txt missing-final-newline.txt crlf.txt

if bash "${checker}" "${test_repo}" > "${test_root}/diagnostics" 2>&1; then
  echo 'tracked text policy accepted invalid fixtures' >&2
  exit 1
fi

grep -Fq 'tracked text has trailing whitespace: trailing.txt' "${test_root}/diagnostics"
grep -Fq 'tracked text must end with a newline: missing-final-newline.txt' "${test_root}/diagnostics"
grep -Fq 'tracked text must use LF line endings: crlf.txt' "${test_root}/diagnostics"

echo 'tracked text style assertions passed'
