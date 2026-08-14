#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=$(mktemp -d)
trap 'rm -rf "${work_dir}"' EXIT

ssh-keygen -q -t ed25519 -N '' -C existing -f "${work_dir}/existing"
ssh-keygen -q -t ed25519 -N '' -C coolify -f "${work_dir}/coolify"

mkdir -p "${work_dir}/root/.ssh"
cp "${work_dir}/existing.pub" "${work_dir}/root/.ssh/authorized_keys"
cp "${work_dir}/coolify.pub" "${work_dir}/provisioned-keys"

"${repo_root}/scripts/bootstrap-worker.sh" \
    --authorized-key-file "${work_dir}/provisioned-keys" \
    --root-home "${work_dir}/root"

grep -Fqx -- "$(<"${work_dir}/existing.pub")" "${work_dir}/root/.ssh/authorized_keys"
grep -Fqx -- "$(<"${work_dir}/coolify.pub")" "${work_dir}/root/.ssh/authorized_keys"
[[ $(stat -c '%a' "${work_dir}/root/.ssh") == 700 ]]
[[ $(stat -c '%a' "${work_dir}/root/.ssh/authorized_keys") == 600 ]]

before_hash=$(sha256sum "${work_dir}/root/.ssh/authorized_keys")
"${repo_root}/scripts/bootstrap-worker.sh" \
    --authorized-key-file "${work_dir}/provisioned-keys" \
    --root-home "${work_dir}/root"
after_hash=$(sha256sum "${work_dir}/root/.ssh/authorized_keys")
[[ ${before_hash} == "${after_hash}" ]]
[[ $(grep -Fxc -- "$(<"${work_dir}/coolify.pub")" "${work_dir}/root/.ssh/authorized_keys") == 1 ]]

printf '%s\n' 'not-a-public-key' > "${work_dir}/invalid-keys"
if "${repo_root}/scripts/bootstrap-worker.sh" \
    --authorized-key-file "${work_dir}/invalid-keys" \
    --root-home "${work_dir}/root"; then
    echo "invalid public key was accepted" >&2
    exit 1
fi
[[ ${after_hash} == "$(sha256sum "${work_dir}/root/.ssh/authorized_keys")" ]]

echo "worker bootstrap assertions passed"
