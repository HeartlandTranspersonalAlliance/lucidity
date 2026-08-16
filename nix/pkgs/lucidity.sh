# shellcheck shell=bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: lucidity COMMAND [ARGUMENTS]

  generate
  check
  build controller|worker [--validate-only]
  vm test controller|worker|mesh
  infra plan [OpenTofu arguments]
  infra apply SAVED_PLAN [OpenTofu apply arguments]
  secrets set-admin-key [PUBLIC_KEY_FILE]
  mesh init
  mesh request NAME DIRECTORY
  mesh sign PUBLIC_KEY CERTIFICATE NAME IP GROUPS
  mesh install DIRECTORY
  mesh revoke FINGERPRINT
  mesh rotate
  release
EOF
}

die() {
    echo "lucidity: $*" >&2
    exit 1
}

repository_root() {
    git rev-parse --show-toplevel 2>/dev/null || die "run this command from the lucidity repository"
}

build_path() {
    nix build --no-link --print-out-paths "$1"
}

operator_provider() {
    printf '%s\n' "${LUCIDITY_OPERATOR_PROVIDER:-keyring://lucidity}"
}

secrets_set_admin_key() {
    root=$(repository_root)
    public_key_file=${1:-${HOME}/.ssh/id_ed25519.pub}
    [[ -s $public_key_file ]] || die "public key file does not exist: $public_key_file"
    actual_fingerprint=$(ssh-keygen -lf "$public_key_file" | awk '{print $2}')
    manifest=$(build_path "$root#host-manifest-controller")
    expected_fingerprint=$(jq -r '.admin.sshFingerprint' "$manifest")
    [[ $actual_fingerprint == "$expected_fingerprint" ]] ||
        die "public key fingerprint $actual_fingerprint does not match Den registry fingerprint $expected_fingerprint"
    public_key=$(<"$public_key_file")
    secretspec set --reason "register lucidity administrator public key" \
        --provider "$(operator_provider)" --profile ssh ADMIN_SSH_PUBLIC_KEY "$public_key"
    echo "Stored ADMIN_SSH_PUBLIC_KEY in $(operator_provider); no key material was written to the repository"
}

secrets_command() {
    case "${1:-}" in
        set-admin-key)
            shift
            secrets_set_admin_key "$@"
            ;;
        *) die "secrets requires set-admin-key" ;;
    esac
}

generate() {
    root=$(repository_root)
    generated="$root/generated"
    mkdir -p "$generated/bootc" "$generated/tofu/aws" "$generated/tofu/state"
    for role in controller worker; do
        context=$(build_path "$root#bootc-context-$role")
        destination="$generated/bootc/$role"
        find "$destination" -mindepth 1 -delete 2>/dev/null || true
        mkdir -p "$destination"
        cp -RL "$context"/. "$destination"/
    done
    tofu_json=$(build_path "$root#awsConfig")
    install -m 0644 "$tofu_json" "$generated/tofu/aws/config.tf.json"
    state_json=$(build_path "$root#state.config")
    install -m 0644 "$state_json" "$generated/tofu/state.tf.json"
    echo "Generated bootc and OpenTofu artifacts under $generated"
}

check() {
    root=$(repository_root)
    if [[ ${LUCIDITY_SKIP_VM_CHECKS:-0} == 1 ]]; then
        nix flake check "$root" --no-build --show-trace
    else
        nix flake check "$root" --show-trace
    fi
    "$root/tests/run.sh"
}

build_role() {
    [[ ${1:-} == controller || ${1:-} == worker ]] || die "build requires controller or worker"
    role=$1
    mode=${2:-build}
    [[ $# -le 2 ]] || die "build accepts only a role and optional --validate-only"
    [[ $mode == build || $mode == --validate-only ]] || die "unknown build option: $mode"
    engine=${CONTAINER_ENGINE:-podman}
    image=${IMAGE_NAME:-localhost/lucidity-$role:dev}
    command -v "$engine" >/dev/null 2>&1 || die "container engine is unavailable: $engine"
    if [[ $mode == --validate-only ]]; then
        validate_role_image "$role" "$image" "$engine"
        return
    fi

    root=$(repository_root)
    context=$(build_path "$root#bootc-context-$role")
    image_version=${IMAGE_VERSION:-dev}
    base_image=${BASE_IMAGE:-quay.io/almalinuxorg/almalinux-bootc:10}
    case "${ARCH:-$(uname -m)}" in
        aarch64|arm64) arch=arm64 ;;
        x86_64|amd64) arch=amd64 ;;
        *) die "unsupported architecture: ${ARCH:-$(uname -m)}" ;;
    esac

    build_command=("$engine" build)
    if [[ -n ${BUILD_CACHE_FROM:-} || -n ${BUILD_CACHE_TO:-} ]]; then
        case "$engine" in
            docker)
                docker buildx version >/dev/null
                build_command=(docker buildx build --load)
                if [[ -n ${BUILDX_BUILDER_NAME:-} ]]; then
                    build_command+=(--builder "$BUILDX_BUILDER_NAME")
                fi
                [[ -z ${BUILD_CACHE_FROM:-} ]] || build_command+=(--cache-from "type=registry,ref=$BUILD_CACHE_FROM")
                [[ -z ${BUILD_CACHE_TO:-} ]] || build_command+=(--cache-to "type=registry,ref=$BUILD_CACHE_TO,mode=max,image-manifest=true,oci-mediatypes=true")
                ;;
            podman)
                build_command=(podman build --layers)
                [[ -z ${BUILD_CACHE_FROM:-} ]] || build_command+=(--cache-from "$BUILD_CACHE_FROM" --cache-ttl 168h)
                [[ -z ${BUILD_CACHE_TO:-} ]] || build_command+=(--cache-to "$BUILD_CACHE_TO")
                ;;
            *) die "registry build caching requires Docker or Podman" ;;
        esac
    fi

    build_args=(
        --pull
        --platform "linux/$arch"
        --build-arg "BASE_IMAGE=$base_image"
        --build-arg "IMAGE_VERSION=$image_version"
        --tag "$image"
        --file "$context/Containerfile"
    )
    if [[ -n ${LUCIDITY_BUILD_NETWORK:-} ]]; then
        build_args+=(--network "$LUCIDITY_BUILD_NETWORK")
    fi
    "${build_command[@]}" "${build_args[@]}" "$context"
    validate_role_image "$role" "$image" "$engine"
}

validate_role_image() {
    role=$1
    image=$2
    engine=$3
    actual_role=$("$engine" image inspect --format '{{ index .Config.Labels "io.lucidity.role" }}' "$image")
    [[ $actual_role == "$role" ]] || die "image role is ${actual_role:-unset}, expected $role"
    "$engine" run --rm "$image" bootc container lint
    # Expanded by Bash inside the built image.
    # shellcheck disable=SC2016
    "$engine" run --rm --entrypoint /bin/bash "$image" -Eeuo pipefail -c '
        rpm -q amazon-ssm-agent bootc cloud-init container-selinux docker-ce openssh-server selinux-policy-targeted
        systemctl is-enabled --quiet amazon-ssm-agent.service
        systemctl is-enabled --quiet bootc-fetch-apply-updates.timer
        systemctl is-enabled --quiet determinate-nix-install.service
        systemctl is-enabled --quiet lucidity-nix-profile.service
        systemctl is-enabled --quiet lucidity-admin-authorized-key.service
        systemctl is-enabled --quiet docker.service
        systemctl is-enabled --quiet sshd.service
        grep -Eq "^SELINUX=enforcing$" /etc/selinux/config
        grep -Eq "^SELINUXTYPE=targeted$" /etc/selinux/config
        test -s /usr/lib/lucidity/nix-seed/registration
        test -n "$(find /usr/lib/lucidity/nix-seed/store -mindepth 1 -maxdepth 1 -print -quit)"
        test -x /usr/libexec/lucidity/nix-installer
        test -x /usr/libexec/lucidity/install-determinate-nix
        test -x /usr/libexec/lucidity/install-admin-authorized-key
        systemd-analyze verify \
            /usr/lib/systemd/system/determinate-nix-install.service \
            /usr/lib/systemd/system/lucidity-nix-profile.service \
            /usr/lib/systemd/system/lucidity-admin-authorized-key.service
        ssh-keygen -A
        sshd -t
    '
    if [[ $role == worker ]]; then
        "$engine" run --rm --entrypoint /bin/bash "$image" -Eeuo pipefail -c '
            test -x /usr/libexec/lucidity/prepare-worker-storage
            test -x /usr/libexec/lucidity/bootstrap-worker
            systemctl is-enabled --quiet coolify-worker-storage.service
            systemctl is-enabled --quiet coolify-worker-authorized-keys.service
            systemd-analyze verify \
                /usr/lib/systemd/system/coolify-worker-storage.service \
                /usr/lib/systemd/system/coolify-worker-authorized-keys.service
            semanage fcontext --list | grep -E "^/data/coolify\(/\.\*\)\?.*container_file_t" >/dev/null
        '
        return
    fi
    "$engine" run --rm --entrypoint /bin/bash "$image" -Eeuo pipefail -c '
        test -x /usr/libexec/lucidity/prepare-controller-storage
        test -x /usr/libexec/lucidity/bootstrap-controller-with-secrets
        test -x /usr/libexec/lucidity/prepare-openbao
        systemctl is-enabled --quiet coolify-controller-storage.service
        systemctl is-enabled --quiet coolify-controller-bootstrap.service
        systemctl is-enabled --quiet openbao.service
        systemctl is-enabled --quiet openbao-snapshot.timer
        systemctl is-enabled --quiet aws-workload-credentials-provider-token.service
        systemctl is-enabled --quiet aws-workload-credentials-provider-sm.service
        grep -Fq "/bin/aws-workload-credentials-provider sm start" \
            /usr/lib/systemd/system/aws-workload-credentials-provider-sm.service
        systemd-analyze verify \
            /usr/lib/systemd/system/coolify-controller-storage.service \
            /usr/lib/systemd/system/coolify-controller-bootstrap.service \
            /usr/lib/systemd/system/openbao-snapshot.service \
            /usr/lib/systemd/system/openbao-snapshot.timer
        grep -Fq "address = \"127.0.0.1:8200\"" /etc/openbao/openbao.hcl.in
        semanage fcontext --list | grep -E "^/data/coolify\(/\.\*\)\?.*container_file_t" >/dev/null
    '
}

vm_test() {
    root=$(repository_root)
    case "${1:-}" in
        controller|worker)
            "$root/tests/vm-role.sh" "$1"
            ;;
        mesh)
            "$root/tests/vm-mesh.sh"
            ;;
        *) die "vm test requires controller, worker, or mesh" ;;
    esac
}

prepare_infra() {
    root=$(repository_root)
    workdir="$root/.lucidity/tofu/aws"
    mkdir -p "$workdir"
    config=$(build_path "$root#awsConfig")
    backend_config=${LUCIDITY_BACKEND_CONFIG:-$root/.lucidity/backend.aws.s3.tfbackend}
    remote_backend=false
    if [[ -f $backend_config ]]; then
        ln -sfn "$config" "$workdir/config.tf.json"
        backend_args=(-backend-config="$backend_config")
        remote_backend=true
    elif [[ -n ${LUCIDITY_BACKEND_CONFIG:-} ]]; then
        die "LUCIDITY_BACKEND_CONFIG does not exist: $LUCIDITY_BACKEND_CONFIG"
    else
        rm -f "$workdir/config.tf.json"
        jq 'del(.terraform.backend)' "$config" >"$workdir/config.tf.json"
        backend_args=(-backend=false)
    fi
}

ses_plan_none() {
    aws sesv2 put-account-pricing-attributes --pricing-plan NONE
    current=$(aws sesv2 get-account --query 'PricingAttributes.CurrentPlan' --output text)
    [[ $current == NONE ]] || die "SES pricing plan verification returned $current"
}

infra() {
    action=${1:-}
    shift || true
    [[ $action == plan || $action == apply ]] || die "infra requires plan or apply"
    if [[ $action == apply ]]; then
        saved_plan=${1:-}
        [[ -f $saved_plan ]] || die "infra apply requires an existing saved plan as its first argument"
        saved_plan=$(realpath "$saved_plan")
        shift
    fi
    prepare_infra
    if [[ $action == apply && $remote_backend != true ]]; then
        die "infra apply requires the production remote-backend input"
    fi
    tofu -chdir="$workdir" init -reconfigure "${backend_args[@]}"
    if [[ $action == plan ]]; then
        tofu -chdir="$workdir" plan "$@"
        return
    fi

    plan_json=$(mktemp "$workdir/plan.XXXXXX.json")
    trap 'rm -f "$plan_json"' RETURN
    tofu -chdir="$workdir" show -json "$saved_plan" >"$plan_json"
    replacements=$(jq '[.resource_changes[].change.actions | select(. == ["delete", "create"] or . == ["create", "delete"])] | length' "$plan_json")
    deletions=$(jq '[.resource_changes[].change.actions | select(. == ["delete"])] | length' "$plan_json")
    ((replacements == 0)) || die "refusing a plan containing $replacements resource replacement(s)"
    if ((deletions > 0)) && [[ ${LUCIDITY_ALLOW_DELETIONS:-0} != 1 ]]; then
        die "plan contains $deletions deletion(s); review the mesh and ingress cutover, then set LUCIDITY_ALLOW_DELETIONS=1"
    fi
    tofu -chdir="$workdir" apply "$@" "$saved_plan"
    ses_plan_none
}

private_tmpfs() {
    base=/dev/shm
    [[ -d $base && -w $base ]] || die "a writable /dev/shm tmpfs is required for CA operations"
    directory=$(mktemp -d "$base/lucidity-mesh.XXXXXX")
    chmod 0700 "$directory"
    trap 'find "$directory" -type f -exec shred -u {} + 2>/dev/null || true; rmdir "$directory" 2>/dev/null || true' EXIT
}

require_ca_passphrase() {
    [[ -n ${NEBULA_CA_PASSPHRASE:-} ]] || die "resolve NEBULA_CA_PASSPHRASE with SecretSpec before running this command"
}

mesh_with_secretspec() {
    profile=$1
    shift
    LUCIDITY_SECRETSPEC_ACTIVE=1 secretspec run \
        --reason "lucidity mesh operation" \
        --provider "$(operator_provider)" \
        --profile "$profile" -- "$0" mesh "$@"
}

mesh_init() {
    require_ca_passphrase
    private_tmpfs
    (
        cd "$directory"
        printf '%s\n%s\n' "$NEBULA_CA_PASSPHRASE" "$NEBULA_CA_PASSPHRASE" |
            nebula-cert ca -name "Lucidity production CA" -duration 26280h -encrypt
    )
    BAO_ADDR=${BAO_ADDR:-https://127.0.0.1:8200} \
        bao kv put -mount=secret nebula/ca \
        encrypted_key=@"$directory/ca.key" certificate=@"$directory/ca.crt" >/dev/null
    install -m 0644 "$directory/ca.crt" ./lucidity-nebula-ca.crt
    echo "Stored the encrypted CA key in OpenBao; wrote only the public CA certificate locally"
}

mesh_request() {
    name=${1:-}
    destination=${2:-}
    [[ -n $name && -n $destination ]] || die "mesh request requires NAME DIRECTORY"
    mkdir -p "$destination"
    umask 077
    nebula-cert keygen -out-key "$destination/host.key" -out-pub "$destination/$name.pub"
    chmod 0600 "$destination/host.key"
    chmod 0644 "$destination/$name.pub"
    echo "Private key retained at $destination/host.key; send only $destination/$name.pub for signing"
}

mesh_sign() {
    public_key=${1:-}
    certificate=${2:-}
    name=${3:-}
    ip=${4:-}
    groups=${5:-}
    [[ -f $public_key && -n $certificate && -n $name && -n $ip && -n $groups ]] ||
        die "mesh sign requires PUBLIC_KEY CERTIFICATE NAME IP GROUPS"
    require_ca_passphrase
    private_tmpfs
    BAO_ADDR=${BAO_ADDR:-https://127.0.0.1:8200} bao kv get -mount=secret -field=encrypted_key nebula/ca > "$directory/ca.key"
    BAO_ADDR=${BAO_ADDR:-https://127.0.0.1:8200} bao kv get -mount=secret -field=certificate nebula/ca > "$directory/ca.crt"
    chmod 0600 "$directory/ca.key"
    printf '%s\n' "$NEBULA_CA_PASSPHRASE" | nebula-cert sign \
        -ca-key "$directory/ca.key" -ca-crt "$directory/ca.crt" \
        -in-pub "$public_key" -out-crt "$certificate" \
        -name "$name" -networks "$ip/16" -groups "$groups" -duration 8760h
    chmod 0644 "$certificate"
}

mesh_install() {
    source_directory=${1:-}
    [[ -d $source_directory ]] || die "mesh install requires a directory containing ca.crt, host.crt, and host.key"
    if ((EUID != 0)); then
        [[ -x /usr/bin/sudo ]] || die "mesh installation requires root and /usr/bin/sudo is unavailable"
        exec /usr/bin/sudo \
            --preserve-env=ADMIN_SSH_PUBLIC_KEY,LUCIDITY_SECRETSPEC_ACTIVE \
            "$0" mesh install "$source_directory"
    fi
    for file in ca.crt host.crt host.key; do
        [[ -s $source_directory/$file ]] || die "$source_directory/$file is missing"
    done
    install -d -m 0700 /var/lib/nebula
    install -m 0644 "$source_directory/ca.crt" /var/lib/nebula/ca.crt
    install -m 0644 "$source_directory/host.crt" /var/lib/nebula/host.crt
    install -m 0600 "$source_directory/host.key" /var/lib/nebula/host.key
    if [[ -n ${ADMIN_SSH_PUBLIC_KEY:-} ]]; then
        key_file=$(mktemp)
        printf '%s\n' "$ADMIN_SSH_PUBLIC_KEY" > "$key_file"
        actual_fingerprint=$(ssh-keygen -lf "$key_file" | awk '{print $2}')
        expected_fingerprint=SHA256:azw3+qLpmhaHpAcVRQnZHYyBBlEtzCAf2svZ+DhvtAk
        if [[ $actual_fingerprint != "$expected_fingerprint" ]]; then
            rm -f "$key_file"
            die "ADMIN_SSH_PUBLIC_KEY fingerprint does not match the Den registry"
        fi
        install -d -m 0700 /etc/lucidity
        install -o root -g root -m 0600 "$key_file" /etc/lucidity/admin-authorized-key
        rm -f "$key_file"
        systemctl restart lucidity-admin-authorized-key.service
    fi
    if [[ -s $source_directory/controller-ssh.pub ]]; then
        [[ $(< /etc/lucidity/role) == worker ]] ||
            die "controller-ssh.pub may only be installed on the worker"
        ssh-keygen -lf "$source_directory/controller-ssh.pub" >/dev/null ||
            die "controller-ssh.pub is not a valid OpenSSH public key"
        install -d -o root -g root -m 0700 /root/.ssh
        install -o root -g root -m 0600 "$source_directory/controller-ssh.pub" /root/.ssh/authorized_keys
        restorecon -RF /root/.ssh
    fi
    systemctl restart nebula.service
}

mesh_revoke() {
    fingerprint=${1:-}
    [[ $fingerprint =~ ^[0-9a-f]{64}$ ]] || die "mesh revoke requires a 64-character certificate fingerprint"
    install -d -m 0700 /var/lib/nebula
    touch /var/lib/nebula/blocklist
    chmod 0600 /var/lib/nebula/blocklist
    grep -Fqx "$fingerprint" /var/lib/nebula/blocklist || echo "$fingerprint" >> /var/lib/nebula/blocklist
    systemctl reload-or-restart nebula.service
}

mesh_rotate() {
    echo "Create the new encrypted CA with 'lucidity mesh init', concatenate old and new CA certificates into ca.crt, reissue every host, then remove the old CA after all peers have migrated."
}

mesh() {
    action=${1:-}
    shift || true
    if [[ -z ${LUCIDITY_SECRETSPEC_ACTIVE:-} ]]; then
        case "$action" in
            init|sign)
                [[ -n ${NEBULA_CA_PASSPHRASE:-} ]] || {
                    mesh_with_secretspec ca "$action" "$@"
                    return
                }
                ;;
            install)
                [[ -n ${ADMIN_SSH_PUBLIC_KEY:-} ]] || {
                    mesh_with_secretspec ssh "$action" "$@"
                    return
                }
                ;;
        esac
    fi
    case "$action" in
        init) mesh_init "$@" ;;
        request) mesh_request "$@" ;;
        sign) mesh_sign "$@" ;;
        install) mesh_install "$@" ;;
        revoke) mesh_revoke "$@" ;;
        rotate) mesh_rotate "$@" ;;
        *) die "mesh requires init, request, sign, install, revoke, or rotate" ;;
    esac
}

release() {
    root=$(repository_root)
    generate
    mkdir -p "$root/generated/release"
    for role in controller worker; do
        build_role "$role"
        image=${IMAGE_NAME:-localhost/lucidity-$role:dev}
        syft "$image" -o cyclonedx-json="$root/generated/release/$role.sbom.cdx.json"
    done
    nix flake metadata "$root" --json > "$root/generated/release/flake-metadata.json"
    echo "Release artifacts are under $root/generated/release"
}

command=${1:-}
shift || true
case "$command" in
    generate) generate "$@" ;;
    check) check "$@" ;;
    build) build_role "$@" ;;
    vm)
        [[ ${1:-} == test ]] || die "vm requires test"
        shift
        vm_test "$@"
        ;;
    infra) infra "$@" ;;
    secrets) secrets_command "$@" ;;
    mesh) mesh "$@" ;;
    release) release "$@" ;;
    -h|--help|help|"") usage ;;
    *) usage >&2; exit 2 ;;
esac
