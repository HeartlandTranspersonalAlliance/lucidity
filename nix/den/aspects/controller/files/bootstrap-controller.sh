#!/usr/bin/env bash
set -Eeuo pipefail

data_root=${COOLIFY_DATA_ROOT:-/data/coolify}
root_home=${COOLIFY_ROOT_HOME:-/root}
cdn=${COOLIFY_CDN:-https://cdn.coollabs.io/coolify}
owner=${COOLIFY_DATA_OWNER:-9999:root}
source_dir=${data_root}/source
env_file=${source_dir}/.env
key_file=${data_root}/ssh/id.root@host.docker.internal
key_import_file=${data_root}/ssh/keys/id.root@host.docker.internal
bootstrap_marker=${data_root}/.controller-bootstrap-complete
curl_bin=${COOLIFY_CURL_BIN:-curl}

pull_policy=missing
if [[ ! -e ${bootstrap_marker} ]]; then
    pull_policy=always
fi

required_directories=(
    source
    ssh
    ssh/keys
    ssh/mux
    applications
    databases
    backups
    services
    proxy
    proxy/dynamic
    sentinel
)

for directory in "${required_directories[@]}"; do
    install -d -m 0700 "${data_root}/${directory}"
done
install -d -m 0700 "${root_home}/.ssh"
touch "${root_home}/.ssh/authorized_keys"
chmod 0600 "${root_home}/.ssh/authorized_keys"

download_once() {
    local remote_name=$1
    local local_name=$2
    local mode=$3
    local destination=${source_dir}/${local_name}
    local temporary

    [[ -s ${destination} ]] && return 0
    temporary=$(mktemp "${source_dir}/.${local_name}.XXXXXX")
    trap 'rm -f "${temporary}"' RETURN
    "${curl_bin}" --fail --location --silent --show-error \
        --output "${temporary}" "${cdn}/${remote_name}"
    chmod "${mode}" "${temporary}"
    mv "${temporary}" "${destination}"
    trap - RETURN
}

download_once docker-compose.yml docker-compose.yml 0600
download_once docker-compose.prod.yml docker-compose.prod.yml 0600
download_once .env.production .env.production 0600
download_once upgrade.sh upgrade.sh 0700
download_once upgrade-postgres.sh upgrade-postgres.sh 0700

if [[ ! -e ${env_file} ]]; then
    cp "${source_dir}/.env.production" "${env_file}"
    chmod 0600 "${env_file}"
fi

set_env_if_empty() {
    local key=$1
    local value=$2
    local line
    local found=false
    local temporary

    if [[ ${value} == *$'\n'* || ${value} == *$'\r'* ]]; then
        echo "Coolify secret ${key} must be a single-line value" >&2
        return 1
    fi

    temporary=$(mktemp "${source_dir}/.env.XXXXXX")
    while IFS= read -r line || [[ -n ${line} ]]; do
        if [[ ${line} == "${key}=" ]]; then
            printf '%s=%s\n' "${key}" "${value}" >>"${temporary}"
            found=true
        else
            printf '%s\n' "${line}" >>"${temporary}"
            [[ ${line} == "${key}="* ]] && found=true
        fi
    done <"${env_file}"
    if [[ ${found} == false ]]; then
        printf '%s=%s\n' "${key}" "${value}" >>"${temporary}"
    fi
    chmod 0600 "${temporary}"
    mv "${temporary}" "${env_file}"
}

grep -Eq '^APP_ID=.+$' "${env_file}" || \
    set_env_if_empty APP_ID "${COOLIFY_APP_ID:-$(openssl rand -hex 16)}"
grep -Eq '^APP_KEY=.+$' "${env_file}" || \
    set_env_if_empty APP_KEY "${COOLIFY_APP_KEY:-base64:$(openssl rand -base64 32)}"
grep -Eq '^DB_PASSWORD=.+$' "${env_file}" || \
    set_env_if_empty DB_PASSWORD "${COOLIFY_DB_PASSWORD:-$(openssl rand -base64 32)}"
grep -Eq '^REDIS_PASSWORD=.+$' "${env_file}" || \
    set_env_if_empty REDIS_PASSWORD "${COOLIFY_REDIS_PASSWORD:-$(openssl rand -base64 32)}"
grep -Eq '^PUSHER_APP_ID=.+$' "${env_file}" || \
    set_env_if_empty PUSHER_APP_ID "${COOLIFY_PUSHER_APP_ID:-$(openssl rand -hex 32)}"
grep -Eq '^PUSHER_APP_KEY=.+$' "${env_file}" || \
    set_env_if_empty PUSHER_APP_KEY "${COOLIFY_PUSHER_APP_KEY:-$(openssl rand -hex 32)}"
grep -Eq '^PUSHER_APP_SECRET=.+$' "${env_file}" || \
    set_env_if_empty PUSHER_APP_SECRET "${COOLIFY_PUSHER_APP_SECRET:-$(openssl rand -hex 32)}"

if [[ ! -s ${key_file} ]]; then
    ssh-keygen -q -t ed25519 -a 100 -N '' -C coolify -f "${key_file}"
fi
if [[ ! -s ${key_file}.pub ]]; then
    temporary_public_key=$(mktemp "${data_root}/ssh/.id.root.pub.XXXXXX")
    public_key_material=$(ssh-keygen -y -f "${key_file}")
    printf '%s\n' "${public_key_material}" >"${temporary_public_key}"
    chmod 0600 "${temporary_public_key}"
    mv "${temporary_public_key}" "${key_file}.pub"
fi

public_key=$(<"${key_file}.pub")
if ! grep -Fqx -- "${public_key}" "${root_home}/.ssh/authorized_keys"; then
    printf '%s\n' "${public_key}" >>"${root_home}/.ssh/authorized_keys"
fi

# Coolify consumes files from ssh/keys as an import inbox. Keep the canonical
# host identity outside that managed directory and stage the same identity
# until the first bootstrap completes.
if [[ ! -e ${bootstrap_marker} ]]; then
    install -m 0600 "${key_file}" "${key_import_file}"
    install -m 0600 "${key_file}.pub" "${key_import_file}.pub"
fi

chown -R "${owner}" "${data_root}"
chmod -R u=rwX,go= "${data_root}"
restorecon -RF "${data_root}"

if ! docker network inspect coolify >/dev/null 2>&1; then
    docker network create --attachable coolify >/dev/null
fi

compose=(
    docker compose
    --env-file "${env_file}"
    --file "${source_dir}/docker-compose.yml"
    --file "${source_dir}/docker-compose.prod.yml"
)
if [[ -s ${source_dir}/docker-compose.custom.yml ]]; then
    compose+=(--file "${source_dir}/docker-compose.custom.yml")
fi
compose+=(up -d --wait --wait-timeout 600 --pull "${pull_policy}" --remove-orphans)
"${compose[@]}"

touch "${bootstrap_marker}"
chown "${owner}" "${bootstrap_marker}"
chmod 0600 "${bootstrap_marker}"

echo "Coolify controller bootstrap complete"
