#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEFAULT_KEY_FILE=/etc/coolify-worker/authorized_keys
key_file="${DEFAULT_KEY_FILE}"
root_home=/root

usage() {
    cat <<'EOF'
Usage: bootstrap-worker.sh [--authorized-key-file PATH] [--root-home PATH]

Append plain SSH public keys to root's authorized_keys file without removing or
duplicating existing entries. --root-home exists to support isolated tests.
EOF
}

while (($# > 0)); do
    case "$1" in
        --authorized-key-file)
            [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; exit 2; }
            key_file=$2
            shift 2
            ;;
        --root-home)
            [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; exit 2; }
            root_home=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ ${key_file} = /* ]] || { echo "authorized key file must be an absolute path" >&2; exit 2; }
[[ ${root_home} = /* ]] || { echo "root home must be an absolute path" >&2; exit 2; }
[[ -f ${key_file} ]] || { echo "authorized key file not found: ${key_file}" >&2; exit 1; }

ssh_dir="${root_home}/.ssh"
authorized_keys="${ssh_dir}/authorized_keys"
validation_file=$(mktemp)
candidate_file=$(mktemp)
trap 'rm -f "${validation_file}" "${candidate_file}"' EXIT

# Validate the entire input before touching the destination. Provisioning accepts
# ordinary public keys, not authorized_keys command/environment options.
valid_key_count=0
while IFS= read -r line || [[ -n ${line} ]]; do
    [[ -z ${line} || ${line} =~ ^[[:space:]]*# ]] && continue
    if [[ ! ${line} =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]].*)?$ ]]; then
        echo "invalid or unsupported SSH public key in ${key_file}" >&2
        exit 1
    fi
    printf '%s\n' "${line}" > "${validation_file}"
    if ! ssh-keygen -l -f "${validation_file}" >/dev/null 2>&1; then
        echo "invalid SSH public key in ${key_file}" >&2
        exit 1
    fi
    ((valid_key_count += 1))
done < "${key_file}"

((valid_key_count > 0)) || { echo "no SSH public keys found in ${key_file}" >&2; exit 1; }

install -d -m 0700 "${ssh_dir}"
if [[ -f ${authorized_keys} ]]; then
    cp -- "${authorized_keys}" "${candidate_file}"
else
    : > "${candidate_file}"
fi

while IFS= read -r line || [[ -n ${line} ]]; do
    [[ -z ${line} || ${line} =~ ^[[:space:]]*# ]] && continue
    grep -Fqx -- "${line}" "${candidate_file}" || printf '%s\n' "${line}" >> "${candidate_file}"
done < "${key_file}"

install -m 0600 "${candidate_file}" "${authorized_keys}"
if [[ $(id -u) -eq 0 ]]; then
    chown root:root "${ssh_dir}" "${authorized_keys}"
fi

echo "Coolify worker SSH authorization is configured"
