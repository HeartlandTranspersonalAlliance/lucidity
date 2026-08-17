#!/usr/bin/env bash
set -Eeuo pipefail

aspect_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture_root=${LUCIDITY_CONTROLLER_TEST_FIXTURES:-${aspect_root}/tests/fixtures}
controller_root=${LUCIDITY_CONTROLLER_ROOT:-${aspect_root}/../../../../../generated/bootc/controller/rootfs}
work_dir=$(mktemp -d)
trap 'rm -rf "${work_dir}"' EXIT

mkdir -p "${work_dir}/bin" "${work_dir}/data" "${work_dir}/root/.ssh" "${work_dir}/state"
ln -s "${fixture_root}/curl" "${work_dir}/bin/curl"
ln -s "${fixture_root}/docker" "${work_dir}/bin/docker"
ln -s "${fixture_root}/mount" "${work_dir}/bin/mount"
ln -s "${fixture_root}/mountpoint" "${work_dir}/bin/mountpoint"
ln -s "${fixture_root}/openssl" "${work_dir}/bin/openssl"
ln -s "${fixture_root}/restorecon" "${work_dir}/bin/restorecon"
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC8YvlyN0Xy0ZOfHNqgFv3xwQv9RrLHEqgOZDPqP existing' \
    >"${work_dir}/root/.ssh/authorized_keys"

export CONTROLLER_TEST_STATE=${work_dir}/state
export COOLIFY_DATA_ROOT=${work_dir}/data
export COOLIFY_ROOT_HOME=${work_dir}/root
controller_test_owner="$(id -u):$(id -g)"
export COOLIFY_DATA_OWNER=${controller_test_owner}
export COOLIFY_CDN=https://fixtures.invalid/coolify
export PATH="${work_dir}/bin:${PATH}"

persistent_source=${work_dir}/persistent-source
persistent_target=${work_dir}/persistent-target
mkdir "${persistent_target}"
chmod 0555 "${persistent_target}"
COOLIFY_PERSISTENT_SOURCE=${persistent_source} \
COOLIFY_PERSISTENT_TARGET=${persistent_target} \
    "${controller_root}/usr/libexec/lucidity/prepare-controller-storage"
[[ $(stat -c %a "${persistent_source}") == 700 ]]
[[ $(stat -c %a "${persistent_target}") == 555 ]]
[[ $(wc -l <"${work_dir}/state/mount") == 1 ]]
COOLIFY_PERSISTENT_SOURCE=${persistent_source} \
COOLIFY_PERSISTENT_TARGET=${persistent_target} \
    "${controller_root}/usr/libexec/lucidity/prepare-controller-storage"
[[ $(wc -l <"${work_dir}/state/mount") == 1 ]]

"${controller_root}/usr/libexec/lucidity/bootstrap-controller"

env_file=${work_dir}/data/source/.env
key_file=${work_dir}/data/ssh/id.root@host.docker.internal
key_import_file=${work_dir}/data/ssh/keys/id.root@host.docker.internal
for key in APP_ID APP_KEY DB_PASSWORD REDIS_PASSWORD PUSHER_APP_ID PUSHER_APP_KEY PUSHER_APP_SECRET; do
    grep -Eq "^${key}=.+$" "${env_file}"
done
grep -Fqx 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC8YvlyN0Xy0ZOfHNqgFv3xwQv9RrLHEqgOZDPqP existing' \
    "${work_dir}/root/.ssh/authorized_keys"
grep -Fqx -- "$(<"${key_file}.pub")" "${work_dir}/root/.ssh/authorized_keys"
[[ $(wc -l <"${work_dir}/state/downloads") == 5 ]]
[[ $(wc -l <"${work_dir}/state/network-create") == 1 ]]
[[ $(wc -l <"${work_dir}/state/compose") == 1 ]]
[[ $(grep -Fc -- '--pull always' "${work_dir}/state/compose") == 1 ]]
[[ $(grep -Fc -- '--wait --wait-timeout 600' "${work_dir}/state/compose") == 1 ]]
[[ $(grep -Fc -- '--pull missing' "${work_dir}/state/compose") == 0 ]]
[[ $(wc -l <"${work_dir}/state/openssl") == 7 ]]
[[ -e ${work_dir}/data/.controller-bootstrap-complete ]]
[[ -s ${key_import_file} ]]

before_env=$(sha256sum "${env_file}")
before_key=$(sha256sum "${key_file}")
before_authorized_keys=$(sha256sum "${work_dir}/root/.ssh/authorized_keys")
expected_public_key=$(<"${key_file}.pub")
rm "${key_file}.pub" "${key_import_file}" "${key_import_file}.pub"
"${controller_root}/usr/libexec/lucidity/bootstrap-controller"
[[ ${before_env} == "$(sha256sum "${env_file}")" ]]
[[ ${before_key} == "$(sha256sum "${key_file}")" ]]
[[ ${before_authorized_keys} == "$(sha256sum "${work_dir}/root/.ssh/authorized_keys")" ]]
[[ $(wc -l <"${work_dir}/state/downloads") == 5 ]]
[[ $(wc -l <"${work_dir}/state/network-create") == 1 ]]
[[ $(wc -l <"${work_dir}/state/compose") == 2 ]]
[[ $(grep -Fc -- '--pull always' "${work_dir}/state/compose") == 1 ]]
[[ $(grep -Fc -- '--pull missing' "${work_dir}/state/compose") == 1 ]]
[[ $(grep -Fc -- '--wait --wait-timeout 600' "${work_dir}/state/compose") == 2 ]]
[[ $(wc -l <"${work_dir}/state/openssl") == 7 ]]
[[ ${expected_public_key} == "$(<"${key_file}.pub")" ]]
[[ $(grep -Fxc -- "${expected_public_key}" "${work_dir}/root/.ssh/authorized_keys") == 1 ]]
[[ ! -e ${key_import_file} ]]

secret_file=${work_dir}/runtime-secrets.env
for variable in \
    COOLIFY_APP_ID \
    COOLIFY_APP_KEY \
    COOLIFY_DB_PASSWORD \
    COOLIFY_REDIS_PASSWORD \
    COOLIFY_PUSHER_APP_ID \
    COOLIFY_PUSHER_APP_KEY \
    COOLIFY_PUSHER_APP_SECRET; do
    printf '%s={{resolve:secretsmanager:lucidity/production/controller-runtime:SecretString:%s}}\n' \
        "${variable}" "${variable#COOLIFY_}" >>"${secret_file}"
done
printf '%s\n' token-for-test >"${work_dir}/awssmatoken"
set -a
# shellcheck disable=SC1090,SC1091
source "${secret_file}"
set +a
COOLIFY_RUNTIME_SECRETS_FILE=${secret_file} \
COOLIFY_BOOTSTRAP_BIN=${fixture_root}/bootstrap-probe \
AWS_WCP_TOKEN_FILE=${work_dir}/awssmatoken \
ASM_EXEC_BIN=${fixture_root}/asm-exec \
    "${controller_root}/usr/libexec/lucidity/bootstrap-controller-with-secrets"
[[ -e ${work_dir}/state/secret-probe-complete ]]

sed 's/{{resolve:secretsmanager:[^}]*}}/plaintext-secret/' "${secret_file}" >"${work_dir}/plaintext.env"
set -a
# shellcheck disable=SC1090,SC1091
source "${work_dir}/plaintext.env"
set +a
if COOLIFY_RUNTIME_SECRETS_FILE=${work_dir}/plaintext.env \
    COOLIFY_BOOTSTRAP_BIN=/bin/true \
    AWS_WCP_TOKEN_FILE=${work_dir}/awssmatoken \
    ASM_EXEC_BIN=${fixture_root}/asm-exec \
    "${controller_root}/usr/libexec/lucidity/bootstrap-controller-with-secrets"; then
    echo "controller secret wrapper accepted plaintext values" >&2
    exit 1
fi

echo "controller bootstrap assertions passed"
