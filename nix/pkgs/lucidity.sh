# shellcheck shell=bash
set -Eeuo pipefail

readonly LUCIDITY_RUNTIME_SCRIPTS="@lucidityRuntimeScripts@"
readonly LUCIDITY_SYFT_CONFIG="@luciditySyftConfig@"

usage() {
    cat <<'EOF'
Usage: lucidity COMMAND [ARGUMENTS]

  generate
  check
  build controller|worker [--validate-only]
  disk build controller|worker qcow2|ami
  disk validate ARTIFACT
  ami validate ARTIFACT
  vm test controller|worker|mesh|integration
  vm init|start|stop|validate controller|worker
  vm registry start|stop controller|worker
  vm validate-update controller|worker
  ci cache configure SCOPE
  ci cache cleanup
  ci build-tools-image
  ci ecr resolve ROLE REPOSITORY_URL IMAGE_TAG
  ci ecr push IMAGE_REF
  ci ecr verify IMAGE_REF REPOSITORY_NAME IMAGE_TAG
  ci ecr logout REGISTRY
  ci ami resolve|pull|validate-inputs
  ci benchmark resolve|verify-target
  ci audit-ami-resources
  ci validate-deployment
  infra plan [OpenTofu arguments]
  infra apply SAVED_PLAN [OpenTofu apply arguments]
  infra output [OpenTofu output arguments]
  infra show [OpenTofu show arguments]
  state plan [OpenTofu arguments]
  state apply SAVED_PLAN [OpenTofu apply arguments]
  state output [OpenTofu output arguments]
  state show [OpenTofu show arguments]
  state migrate BACKEND_CONFIG
  secrets set-admin-key [PUBLIC_KEY_FILE]
  secrets initialize-controller-runtime [SECRET_ID]
  secrets check PROFILE [PROVIDER]
  secrets set PROFILE KEY [PROVIDER]
  secrets run PROFILE [PROVIDER] -- COMMAND [ARGUMENTS]
  mesh init
  mesh request NAME DIRECTORY
  mesh sign PUBLIC_KEY CERTIFICATE NAME IP GROUPS
  mesh install DIRECTORY
  mesh revoke FINGERPRINT
  mesh rotate
  release local
  release prepare auto|patch|minor|major
  release image controller|worker REPOSITORY_URL RELEASE_TAG SOURCE_SHA
  release inventory RELEASE_TAG
  release manifest RELEASE_TAG VERSION SOURCE_SHA
  release publish RELEASE_TAG VERSION SOURCE_SHA
EOF
}

die() {
    echo "lucidity: $*" >&2
    exit 1
}

repository_root() {
    if [[ -n ${LUCIDITY_REPOSITORY_ROOT:-} ]]; then
        [[ -f $LUCIDITY_REPOSITORY_ROOT/flake.nix ]] ||
            die "LUCIDITY_REPOSITORY_ROOT does not contain flake.nix"
        realpath "$LUCIDITY_REPOSITORY_ROOT"
        return
    fi
    if [[ -f ./flake.nix ]]; then
        realpath .
        return
    fi
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

secrets_initialize_controller_runtime() {
    secret_id=${1:-lucidity/production/controller-runtime}
    [[ $# -le 1 && $secret_id =~ ^[A-Za-z0-9/_+=.@-]{1,512}$ ]] ||
        die "secrets initialize-controller-runtime accepts one valid Secrets Manager ID"
    region=${AWS_REGION:-us-east-2}

    # This metadata-only guard prevents accidental rotation. Secret values are
    # generated and uploaded without ever being printed or placed in argv.
    aws secretsmanager describe-secret --region "$region" --secret-id "$secret_id" \
        --query ARN --output text >/dev/null
    current_version=$(aws secretsmanager list-secret-version-ids \
        --region "$region" --secret-id "$secret_id" --max-results 100 \
        --query "Versions[?contains(VersionStages, 'AWSCURRENT')].VersionId | [0]" \
        --output text)
    if [[ $current_version != None && -n $current_version && ${LUCIDITY_ROTATE_RUNTIME_SECRET:-0} != 1 ]]; then
        die "the controller runtime secret already has AWSCURRENT; set LUCIDITY_ROTATE_RUNTIME_SECRET=1 only for an intentional coordinated rotation"
    fi

    base=/dev/shm
    [[ -d $base && -w $base ]] || die "a writable /dev/shm tmpfs is required for secret initialization"
    directory=$(mktemp -d "$base/lucidity-runtime-secret.XXXXXX")
    chmod 0700 "$directory"
    secret_file=$directory/controller-runtime.json
    trap 'find "$directory" -type f -exec shred -u {} + 2>/dev/null || true; rmdir "$directory" 2>/dev/null || true' EXIT

    app_id=$(openssl rand -hex 16)
    app_key="base64:$(openssl rand -base64 32 | tr -d '\n')"
    db_password=$(openssl rand -base64 32 | tr -d '\n')
    redis_password=$(openssl rand -base64 32 | tr -d '\n')
    pusher_app_id=$(openssl rand -hex 32)
    pusher_app_key=$(openssl rand -hex 32)
    pusher_app_secret=$(openssl rand -hex 32)
    umask 077
    printf '{"APP_ID":"%s","APP_KEY":"%s","DB_PASSWORD":"%s","REDIS_PASSWORD":"%s","PUSHER_APP_ID":"%s","PUSHER_APP_KEY":"%s","PUSHER_APP_SECRET":"%s"}\n' \
        "$app_id" "$app_key" "$db_password" "$redis_password" \
        "$pusher_app_id" "$pusher_app_key" "$pusher_app_secret" >"$secret_file"
    jq -e 'keys == ["APP_ID", "APP_KEY", "DB_PASSWORD", "PUSHER_APP_ID", "PUSHER_APP_KEY", "PUSHER_APP_SECRET", "REDIS_PASSWORD"] and all(.[]; type == "string" and length > 0)' \
        "$secret_file" >/dev/null
    aws secretsmanager put-secret-value --region "$region" --secret-id "$secret_id" \
        --secret-string "file://$secret_file" --query VersionId --output text >/dev/null
    echo "Initialized $secret_id with a complete runtime bundle; no secret values were printed or persisted outside tmpfs"
}

secrets_check() {
    profile=${1:-}
    provider=${2:-$(operator_provider)}
    [[ -n $profile && $# -le 2 ]] || die "secrets check requires PROFILE and optional PROVIDER"
    exec secretspec check --reason "validate lucidity secret contract" \
        --provider "$provider" --profile "$profile"
}

secrets_set() {
    profile=${1:-}
    key=${2:-}
    provider=${3:-$(operator_provider)}
    [[ -n $profile && -n $key && $# -le 3 ]] ||
        die "secrets set requires PROFILE KEY and optional PROVIDER"
    exec secretspec set --reason "update lucidity secret" \
        --provider "$provider" --profile "$profile" "$key"
}

secrets_run() {
    profile=${1:-}
    shift || true
    [[ -n $profile ]] || die "secrets run requires PROFILE"
    provider=$(operator_provider)
    if [[ ${1:-} != -- ]]; then
        provider=${1:-}
        shift || true
    fi
    [[ ${1:-} == -- ]] || die "secrets run requires -- before the command"
    shift
    [[ $# -gt 0 ]] || die "secrets run requires a command"
    exec secretspec run --reason "run lucidity command with scoped secrets" \
        --provider "$provider" --profile "$profile" -- "$@"
}

secrets_command() {
    case "${1:-}" in
        set-admin-key)
            shift
            secrets_set_admin_key "$@"
            ;;
        initialize-controller-runtime)
            shift
            secrets_initialize_controller_runtime "$@"
            ;;
        check)
            shift
            secrets_check "$@"
            ;;
        set)
            shift
            secrets_set "$@"
            ;;
        run)
            shift
            secrets_run "$@"
            ;;
        *) die "secrets requires set-admin-key, initialize-controller-runtime, check, set, or run" ;;
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
        system=$(nix eval --impure --raw --expr builtins.currentSystem)
        nix flake check "$root" --no-build --show-trace
        nix build --no-link \
            "$root#checks.$system.static" \
            "$root#checks.$system.treefmt" \
            --print-build-logs
        return
    fi
    nix flake check "$root" --show-trace --print-build-logs
}

build_role() {
    local role mode engine image root context image_version base_image arch
    local -a build_command build_args

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
    local role image engine actual_role

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

vm_test_cleanup() {
    local cleanup_role=$1

    invoke_repository_script vm-registry.sh stop "$cleanup_role" || true
    invoke_repository_script vm-stop.sh "$cleanup_role" || true
}

vm_test() {
    local root role base_image update_image engine system

    root=$(repository_root)
    case "${1:-}" in
        controller|worker)
            role=$1
            base_image=${VM_BASE_IMAGE:-localhost/coolify-bootc-$role:lifecycle-v1}
            update_image=${VM_UPDATE_IMAGE:-localhost/coolify-bootc-$role:lifecycle-v2}
            engine=${CONTAINER_ENGINE:-podman}
            export IMAGE_NAME=$base_image
            export IMAGE_VERSION=lifecycle-v1
            build_role "$role"
            "$engine" image inspect "$base_image" >/dev/null
            "$engine" run --rm --privileged --entrypoint bootc "$base_image" container lint
            echo "The generated $role bootc image passed container validation."
            if [[ ${LUCIDITY_FULL_GUEST_TEST:-0} == 1 ]]; then
                IMAGE_NAME=$base_image invoke_repository_script build-disk.sh "$role" qcow2
                VM_BASE_DISK="$root/image-output/$role/coolify-$role-qcow2.qcow2" \
                    invoke_repository_script vm-init.sh "$role"
                invoke_repository_script vm-start.sh "$role"
                # Expand the validated role now so EXIT cleanup does not depend on local scope.
                # shellcheck disable=SC2064
                trap "vm_test_cleanup $role" EXIT
                invoke_repository_script vm-validate.sh "$role"
                IMAGE_NAME=$update_image IMAGE_VERSION=lifecycle-v2 build_role "$role"
                VM_BASE_IMAGE=$base_image VM_UPDATE_IMAGE=$update_image \
                    invoke_repository_script vm-registry.sh start "$role"
                invoke_repository_script vm-validate-update.sh "$role"
                vm_test_cleanup "$role"
                trap - EXIT
            fi
            ;;
        mesh)
            system=$(nix eval --impure --raw --expr builtins.currentSystem)
            nix build --no-link "$root#checks.$system.mesh-vm" --print-build-logs
            ;;
        *) die "vm test requires controller, worker, or mesh" ;;
    esac
}

invoke_repository_script() {
    local script root

    script=$1
    shift
    root=$(repository_root)
    LUCIDITY_REPOSITORY_ROOT=$root "$LUCIDITY_RUNTIME_SCRIPTS/$script" "$@"
}

run_repository_script() {
    local script root

    script=$1
    shift
    root=$(repository_root)
    export LUCIDITY_REPOSITORY_ROOT=$root
    exec "$LUCIDITY_RUNTIME_SCRIPTS/$script" "$@"
}

disk_command() {
    action=${1:-}
    shift || true
    case "$action" in
        build) run_repository_script build-disk.sh "$@" ;;
        validate) run_repository_script validate-disk.sh "$@" ;;
        *) die "disk requires build or validate" ;;
    esac
}

ami_command() {
    [[ ${1:-} == validate ]] || die "ami requires validate"
    shift
    if [[ -z ${COLDSNAP_COMMAND:-} ]]; then
        root=$(repository_root)
        coldsnap_path=$(build_path "$root#coldsnap")
        export COLDSNAP_COMMAND="$coldsnap_path/bin/coldsnap"
    fi
    run_repository_script validate-ami-import.sh "$@"
}

vm_integration_test() {
    invoke_repository_script vm-init.sh controller
    invoke_repository_script vm-init.sh worker
    VM_HOST_FORWARD_PORT=8000 VM_GUEST_FORWARD_PORT=8000 \
        invoke_repository_script vm-start.sh controller
    VM_HOST_FORWARD_PORT=8081 VM_GUEST_FORWARD_PORT=8080 VM_MEMORY_MB=3072 \
        invoke_repository_script vm-start.sh worker
    integration_cleanup() {
        invoke_repository_script vm-stop.sh controller || true
        invoke_repository_script vm-stop.sh worker || true
    }
    trap integration_cleanup EXIT
    invoke_repository_script vm-validate.sh controller
    invoke_repository_script vm-validate.sh worker
    invoke_repository_script vm-integration.sh
}

vm_command() {
    action=${1:-}
    shift || true
    case "$action" in
        test)
            if [[ ${1:-} == integration ]]; then
                shift
                [[ $# -eq 0 ]] || die "vm test integration accepts no arguments"
                vm_integration_test
            else
                vm_test "$@"
            fi
            ;;
        init|start|stop|validate)
            run_repository_script "vm-$action.sh" "$@"
            ;;
        registry)
            run_repository_script vm-registry.sh "$@"
            ;;
        validate-update)
            run_repository_script vm-validate-update.sh "$@"
            ;;
        *) die "vm requires test, init, start, stop, validate, registry, or validate-update" ;;
    esac
}

ci_cache_configure() {
    cache_scope=${1:-}
    [[ $# -eq 1 && $cache_scope =~ ^[a-z0-9][a-z0-9._-]*$ ]] ||
        die "ci cache configure requires a lowercase cache scope"
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
    : "${GITHUB_ACTOR:?GITHUB_ACTOR is required}"
    : "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
    : "${GITHUB_ENV:?GITHUB_ENV is required}"

    cache_registry=${GHCR_CACHE_REGISTRY:-ghcr.io}
    cache_engine=${GHCR_CACHE_ENGINE:-docker}
    cache_repository=${GITHUB_REPOSITORY,,}-build-cache
    cache_from=""
    cache_to=""
    cache_hit=false
    builder_name=""
    registry_auth_file=""

    case "$cache_engine" in
        docker)
            docker_cmd=${DOCKER_COMMAND:-docker}
            cache_ref=$cache_registry/$cache_repository:$cache_scope
            builder_name=${BUILDX_BUILDER_NAME:-lucidity-ci}
            printf '%s' "$GITHUB_TOKEN" |
                "$docker_cmd" login "$cache_registry" --username "$GITHUB_ACTOR" --password-stdin
            if ! "$docker_cmd" buildx inspect "$builder_name" >/dev/null 2>&1; then
                "$docker_cmd" buildx create \
                    --driver docker-container \
                    --name "$builder_name" \
                    --use >/dev/null
            else
                "$docker_cmd" buildx use "$builder_name"
            fi
            "$docker_cmd" buildx inspect --bootstrap "$builder_name" >/dev/null
            if "$docker_cmd" buildx imagetools inspect "$cache_ref" >/dev/null 2>&1; then
                cache_from=$cache_ref
                cache_hit=true
                echo "Found existing GHCR cache: $cache_ref"
            else
                echo "No existing GHCR cache for $cache_scope; this build will seed it"
            fi
            ;;
        podman)
            : "${RUNNER_TEMP:?RUNNER_TEMP is required for Podman registry authentication}"
            cache_ref=$cache_registry/$cache_repository-$cache_scope
            registry_auth_file=${RUNNER_TEMP%/}/ghcr-$cache_scope-auth.json
            printf '%s' "$GITHUB_TOKEN" |
                sudo podman login \
                    --authfile "$registry_auth_file" \
                    "$cache_registry" \
                    --username "$GITHUB_ACTOR" \
                    --password-stdin
            if sudo skopeo list-tags \
                --authfile "$registry_auth_file" \
                "docker://$cache_ref" |
                jq -e '(.Tags // []) | length > 0' >/dev/null 2>&1; then
                cache_from=$cache_ref
                cache_hit=true
                echo "Found existing GHCR cache: $cache_ref"
            else
                echo "No existing GHCR cache for $cache_scope; this build will seed it"
            fi
            ;;
        *) die "unsupported GHCR cache engine '$cache_engine'" ;;
    esac

    if [[ ${GHCR_CACHE_WRITE:-false} == true ]]; then
        cache_to=$cache_ref
    fi

    {
        printf 'BUILD_CACHE_ENGINE=%s\n' "$cache_engine"
        printf 'BUILDX_BUILDER_NAME=%s\n' "$builder_name"
        printf 'BUILD_CACHE_FROM=%s\n' "$cache_from"
        printf 'BUILD_CACHE_TO=%s\n' "$cache_to"
        printf 'GHCR_CACHE_HIT=%s\n' "$cache_hit"
        printf 'GHCR_CACHE_REF=%s\n' "$cache_ref"
        printf 'GHCR_CACHE_REGISTRY=%s\n' "$cache_registry"
        printf 'REGISTRY_AUTH_FILE=%s\n' "$registry_auth_file"
    } >>"$GITHUB_ENV"
    if [[ -n ${GITHUB_OUTPUT:-} ]]; then
        {
            printf 'hit=%s\n' "$cache_hit"
            printf 'ref=%s\n' "$cache_ref"
        } >>"$GITHUB_OUTPUT"
    fi
}

ci_cache_cleanup() {
    cache_registry=${GHCR_CACHE_REGISTRY:-ghcr.io}
    case "${BUILD_CACHE_ENGINE:-docker}" in
        docker)
            docker_cmd=${DOCKER_COMMAND:-docker}
            "$docker_cmd" logout "$cache_registry" || true
            "$docker_cmd" buildx rm "${BUILDX_BUILDER_NAME:-lucidity-ci}" || true
            ;;
        podman)
            if [[ -n ${REGISTRY_AUTH_FILE:-} ]]; then
                sudo podman logout --authfile "$REGISTRY_AUTH_FILE" "$cache_registry" || true
                if [[ -n ${RUNNER_TEMP:-} && $REGISTRY_AUTH_FILE == "${RUNNER_TEMP%/}/"* ]]; then
                    sudo rm -f -- "$REGISTRY_AUTH_FILE"
                fi
            fi
            ;;
        *) die "unknown build cache engine: ${BUILD_CACHE_ENGINE}" ;;
    esac
}

ci_audit_ami_resources() {
    exec @lucidityAmiAudit@ "$@"
}

ci_validate_deployment() {
    exec @lucidityDeploymentValidation@ "$@"
}

ci_build_tools_image() {
    root=$(repository_root)
    # shellcheck disable=SC1091
    source "$root/image/image-builder.env"
    engine=${CONTAINER_ENGINE:-docker}
    image=${CI_TOOLS_IMAGE:-localhost/coolify-aws-ci-tools:dev}
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
    "${build_command[@]}" \
        --build-arg "IMAGE_BUILDER_IMAGE=$IMAGE_BUILDER_IMAGE" \
        --tag "$image" \
        --file "$root/ci/Containerfile" \
        "$root"
}

ci_ecr_resolve() {
    role=${1:-}
    repository_url=${2:-}
    image_tag=${3:-}
    [[ $role =~ ^(controller|worker)$ && $# -eq 3 ]] ||
        die "ci ecr resolve requires ROLE REPOSITORY_URL IMAGE_TAG"
    [[ -n ${PUBLISH_ROLE_ARN:-} ]] || die "AWS_ECR_PUBLISH_ROLE_ARN repository variable is required"
    [[ $image_tag =~ ^sha-[0-9a-f]{40}$ ]] || die "image tag must contain the full Git commit SHA"
    [[ $repository_url =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9]+([._/-][a-z0-9]+)*$ ]] ||
        die "the $role repository URL is not a private commercial-region ECR repository"
    region=${AWS_REGION:-us-east-2}
    repository_name=${repository_url#*/}
    registry=${repository_url%%/*}
    image_ref=$repository_url:$image_tag
    existing_digest=$(aws ecr batch-get-image --region "$region" --repository-name "$repository_name" \
        --image-ids "imageTag=$image_tag" --query 'images[0].imageId.imageDigest' --output text)
    if [[ $existing_digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
        exists=true
        echo "$image_ref already exists as $existing_digest; retaining the immutable image"
    else
        exists=false
    fi
    aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$registry"
    [[ -n ${GITHUB_OUTPUT:-} ]] || die "GITHUB_OUTPUT is required"
    printf 'exists=%s\nimage_ref=%s\nregistry=%s\nrepository_name=%s\n' \
        "$exists" "$image_ref" "$registry" "$repository_name" >>"$GITHUB_OUTPUT"
}

ci_ecr_push() {
    image_ref=${1:-}
    [[ -n $image_ref && $# -eq 1 ]] || die "ci ecr push requires IMAGE_REF"
    docker push "$image_ref"
}

ci_ecr_verify() {
    image_ref=${1:-}
    repository_name=${2:-}
    image_tag=${3:-}
    [[ -n $image_ref && -n $repository_name && $image_tag =~ ^sha-[0-9a-f]{40}$ && $# -eq 3 ]] ||
        die "ci ecr verify requires IMAGE_REF REPOSITORY_NAME IMAGE_TAG"
    remote_digest=$(aws ecr batch-get-image --region "${AWS_REGION:-us-east-2}" \
        --repository-name "$repository_name" --image-ids "imageTag=$image_tag" \
        --query 'images[0].imageId.imageDigest' --output text)
    [[ $remote_digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "ECR did not return the immutable image digest"
    docker manifest inspect --verbose "$image_ref" |
        jq -e '.Descriptor.platform.os == "linux" and .Descriptor.platform.architecture == "amd64"' >/dev/null
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
        printf '%s published as %s\n' "$image_ref" "$remote_digest" >>"$GITHUB_STEP_SUMMARY"
    fi
}

ci_ecr_logout() {
    registry=${1:-}
    [[ -n $registry && $# -eq 1 ]] || die "ci ecr logout requires REGISTRY"
    docker logout "$registry"
}

ci_ami_resolve() {
    [[ $# -eq 0 ]] || die "ci ami resolve accepts no arguments"
    : "${GITHUB_ENV:?GITHUB_ENV is required}"
    case "${AMI_ROLE:-}" in
        controller)
            ecr_repository_url=${ECR_CONTROLLER_REPOSITORY_URL:-}
            test_instance_profile=${TEST_CONTROLLER_INSTANCE_PROFILE:-}
            test_security_group=${TEST_CONTROLLER_SECURITY_GROUP:-}
            ;;
        worker)
            ecr_repository_url=${ECR_WORKER_REPOSITORY_URL:-}
            test_instance_profile=${TEST_WORKER_INSTANCE_PROFILE:-}
            test_security_group=${TEST_WORKER_SECURITY_GROUP:-}
            ;;
        *) die "AMI_ROLE must be controller or worker" ;;
    esac
    lifecycle=${AMI_LIFECYCLE:-disposable}
    [[ $lifecycle == disposable || $lifecycle == retained ]] ||
        die "AMI_LIFECYCLE must be disposable or retained"
    if [[ $lifecycle == retained ]]; then
        [[ $ecr_repository_url =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9]+([._/-][a-z0-9]+)*$ ]] ||
            die "the $AMI_ROLE ECR repository URL must be configured for retained AMIs"
        if [[ -n ${RELEASE_VERSION:-} ]]; then
            image_ref=$ecr_repository_url:$RELEASE_VERSION
        else
            [[ ${GITHUB_SHA:-} =~ ^[0-9a-f]{40}$ ]] || die "GITHUB_SHA must be a full lowercase Git SHA"
            image_ref=$ecr_repository_url:sha-$GITHUB_SHA
        fi
    else
        image_ref=${IMAGE:-}
        [[ -n $image_ref ]] || die "IMAGE is required for a disposable AMI"
    fi
    {
        printf 'AMI_ARTIFACT=image-output/%s/coolify-%s-ami.raw\n' "$AMI_ROLE" "$AMI_ROLE"
        printf 'ECR_REPOSITORY_URL=%s\n' "$ecr_repository_url"
        printf 'IMAGE_REF=%s\n' "$image_ref"
        printf 'TEST_INSTANCE_PROFILE=%s\n' "$test_instance_profile"
        printf 'TEST_SECURITY_GROUP=%s\n' "$test_security_group"
    } >>"$GITHUB_ENV"
}

ci_ami_pull() {
    [[ $# -eq 0 ]] || die "ci ami pull accepts no arguments"
    [[ ${AMI_ROLE:-} =~ ^(controller|worker)$ ]] || die "AMI_ROLE must be controller or worker"
    [[ ${IMAGE_REF:-} =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9]+([._/-][a-z0-9]+)*:(sha-[0-9a-f]{40}|v[0-9]+\.[0-9]+\.[0-9]+)$ ]] ||
        die "IMAGE_REF must be an immutable private ECR role reference"
    registry=${IMAGE_REF%%/*}
    image_without_tag=${IMAGE_REF%:*}
    repository_name=${image_without_tag#*/}
    source_tag=${IMAGE_REF##*:}
    resolved_digest=$(aws ecr batch-get-image \
        --region "${AWS_REGION:-us-east-2}" \
        --repository-name "$repository_name" \
        --image-ids "imageTag=$source_tag" \
        --query 'images[0].imageId.imageDigest' \
        --output text)
    [[ $resolved_digest =~ ^sha256:[0-9a-f]{64}$ ]] ||
        die "retained $AMI_ROLE candidate did not resolve to an OCI digest"
    if [[ -n ${SOURCE_IMAGE_DIGEST:-} && $resolved_digest != "$SOURCE_IMAGE_DIGEST" ]]; then
        die "retained $AMI_ROLE candidate digest does not match the release manifest input"
    fi
    aws ecr get-login-password --region "${AWS_REGION:-us-east-2}" |
        sudo podman login --username AWS --password-stdin "$registry"
    sudo podman pull "$IMAGE_REF"
    sudo env PATH="$PATH" CONTAINER_ENGINE=podman IMAGE_NAME="$IMAGE_REF" \
        "$0" build "$AMI_ROLE" --validate-only
    [[ $(sudo podman image inspect --format '{{.Os}}/{{.Architecture}}' "$IMAGE_REF") == linux/amd64 ]] ||
        die "retained AMI source is not linux/amd64"
}

ci_ami_validate_inputs() {
    [[ $# -eq 0 ]] || die "ci ami validate-inputs accepts no arguments"
    run_validation=${RUN_AWS_VALIDATION:-false}
    run_launch=${RUN_AWS_LAUNCH:-false}
    lifecycle=${AMI_LIFECYCLE:-disposable}
    [[ $run_validation == true || $run_validation == false ]] || die "RUN_AWS_VALIDATION must be true or false"
    [[ $run_launch == true || $run_launch == false ]] || die "RUN_AWS_LAUNCH must be true or false"
    [[ $lifecycle == disposable || $lifecycle == retained ]] || die "AMI_LIFECYCLE must be disposable or retained"
    if [[ $run_launch == true && $run_validation != true ]]; then
        die "run_aws_launch requires run_aws_validation"
    fi
    if [[ $lifecycle == retained ]]; then
        [[ $run_validation == true ]] || die "retained AMI publication requires run_aws_validation"
        [[ $run_launch == true ]] || die "retained AMI publication requires the EC2 launch gate"
        [[ ${GITHUB_REF:-} == refs/heads/main ]] || die "retained AMIs may be published only from main"
        [[ -n ${ECR_REPOSITORY_URL:-} ]] || die "the ${AMI_ROLE:-selected} ECR repository URL is required for retained AMIs"
    fi
    if [[ -n ${RELEASE_VERSION:-} || -n ${SOURCE_IMAGE_DIGEST:-} || -n ${SBOM_SHA256:-} ]]; then
        [[ $lifecycle == retained ]] || die "release metadata is restricted to retained AMIs"
        [[ ${RELEASE_VERSION:-} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "release_version must be v-prefixed SemVer"
        [[ ${SOURCE_IMAGE_DIGEST:-} =~ ^sha256:[0-9a-f]{64}$ ]] || die "source_image_digest must be a lowercase OCI SHA-256 digest"
        [[ ${SBOM_SHA256:-} =~ ^[0-9a-f]{64}$ ]] || die "sbom_sha256 must be a lowercase SHA-256 digest"
    fi
    [[ $run_validation == true ]] || return 0
    [[ -n ${IMPORT_ROLE_ARN:-} ]] || die "AWS_AMI_IMPORT_ROLE_ARN repository variable is required"
    [[ -n ${SNAPSHOT_KMS_KEY_ARN:-} ]] || die "AWS_AMI_SNAPSHOT_KMS_KEY_ARN repository variable is required"
    if [[ $run_launch == true ]]; then
        [[ -n ${TEST_INSTANCE_PROFILE:-} ]] || die "the ${AMI_ROLE:-selected} AMI test instance-profile repository variable is required"
        [[ -n ${TEST_SECURITY_GROUP:-} ]] || die "the ${AMI_ROLE:-selected} AMI test security-group repository variable is required"
        [[ -n ${TEST_SUBNET:-} ]] || die "AWS_AMI_TEST_SUBNET_ID repository variable is required"
    fi
}

ci_benchmark_resolve() {
    [[ $# -eq 0 ]] || die "ci benchmark resolve accepts no arguments"
    : "${GITHUB_ENV:?GITHUB_ENV is required}"
    [[ -n ${AMI_ROLE_ARN:-} ]] || die "AWS_AMI_IMPORT_ROLE_ARN repository variable is required"
    [[ -n ${SNAPSHOT_KMS_KEY_ARN:-} ]] || die "AWS_AMI_SNAPSHOT_KMS_KEY_ARN repository variable is required"
    [[ -n ${TEST_INSTANCE_PROFILE:-} ]] || die "AWS_AMI_TEST_WORKER_INSTANCE_PROFILE_NAME repository variable is required"
    [[ -n ${TEST_SECURITY_GROUP:-} ]] || die "AWS_AMI_TEST_WORKER_SECURITY_GROUP_ID repository variable is required"
    [[ -n ${TEST_SUBNET:-} ]] || die "AWS_AMI_TEST_SUBNET_ID repository variable is required"
    [[ ${WORKER_REPOSITORY_URL:-} =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9]+([._/-][a-z0-9]+)*$ ]] ||
        die "AWS_ECR_WORKER_REPOSITORY_URL must be a private commercial-region ECR repository"
    [[ ${TARGET_REVISION:-} =~ ^[0-9a-f]{40}$ ]] || die "worker_revision must be a full lowercase Git commit SHA"
    printf 'WORKER_IMAGE_REF=%s:sha-%s\n' "$WORKER_REPOSITORY_URL" "$TARGET_REVISION" >>"$GITHUB_ENV"
}

ci_benchmark_verify_target() {
    [[ $# -eq 0 ]] || die "ci benchmark verify-target accepts no arguments"
    [[ ${WORKER_IMAGE_REF:-} =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9]+([._/-][a-z0-9]+)*:sha-[0-9a-f]{40}$ ]] ||
        die "WORKER_IMAGE_REF must be an immutable private ECR worker reference"
    image_without_tag=${WORKER_IMAGE_REF%:*}
    repository_name=${image_without_tag#*/}
    image_tag=${WORKER_IMAGE_REF##*:}
    image=$(aws ecr batch-get-image \
        --region "${AWS_REGION:-us-east-2}" \
        --repository-name "$repository_name" \
        --image-ids "imageTag=$image_tag" \
        --accepted-media-types application/vnd.docker.distribution.manifest.v2+json \
        --output json)
    jq -e '(.failures | length) == 0 and (.images | length) == 1' <<<"$image" >/dev/null
    printf 'Benchmark target digest: %s\n' "$(jq -r '.images[0].imageId.imageDigest' <<<"$image")"
}

ci_command() {
    case "${1:-}" in
        cache)
            shift
            case "${1:-}" in
                configure)
                    shift
                    ci_cache_configure "$@"
                    ;;
                cleanup)
                    shift
                    [[ $# -eq 0 ]] || die "ci cache cleanup accepts no arguments"
                    ci_cache_cleanup
                    ;;
                *) die "ci cache requires configure or cleanup" ;;
            esac
            ;;
        audit-ami-resources)
            shift
            ci_audit_ami_resources "$@"
            ;;
        validate-deployment)
            shift
            ci_validate_deployment "$@"
            ;;
        build-tools-image)
            shift
            [[ $# -eq 0 ]] || die "ci build-tools-image accepts no arguments"
            ci_build_tools_image
            ;;
        ecr)
            shift
            action=${1:-}
            shift || true
            case "$action" in
                resolve) ci_ecr_resolve "$@" ;;
                push) ci_ecr_push "$@" ;;
                verify) ci_ecr_verify "$@" ;;
                logout) ci_ecr_logout "$@" ;;
                *) die "ci ecr requires resolve, push, verify, or logout" ;;
            esac
            ;;
        ami)
            shift
            action=${1:-}
            shift || true
            case "$action" in
                resolve) ci_ami_resolve "$@" ;;
                pull) ci_ami_pull "$@" ;;
                validate-inputs) ci_ami_validate_inputs "$@" ;;
                *) die "ci ami requires resolve, pull, or validate-inputs" ;;
            esac
            ;;
        benchmark)
            shift
            action=${1:-}
            shift || true
            case "$action" in
                resolve) ci_benchmark_resolve "$@" ;;
                verify-target) ci_benchmark_verify_target "$@" ;;
                *) die "ci benchmark requires resolve or verify-target" ;;
            esac
            ;;
        *) die "ci requires cache, ecr, ami, benchmark, build-tools-image, audit-ami-resources, or validate-deployment" ;;
    esac
}

prepare_infra() {
    root=$(repository_root)
    workdir="$root/.lucidity/tofu/aws"
    mkdir -p "$workdir"
    config=$(build_path "$root#awsConfig")
    production_vars=$(build_path "$root#awsProductionVars")
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
    ln -sfn "$production_vars" "$workdir/production.auto.tfvars.json"
}

ses_plan_none() {
    aws sesv2 put-account-pricing-attributes --pricing-plan NONE
    current=$(aws sesv2 get-account --query 'PricingAttributes.CurrentPlan' --output text)
    [[ $current == NONE ]] || die "SES pricing plan verification returned $current"
}

infra() {
    action=${1:-}
    shift || true
    [[ $action =~ ^(plan|apply|output|show)$ ]] || die "infra requires plan, apply, output, or show"
    if [[ $action == apply ]]; then
        saved_plan=${1:-}
        [[ -f $saved_plan ]] || die "infra apply requires an existing saved plan as its first argument"
        saved_plan=$(realpath "$saved_plan")
        shift
    fi
    prepare_infra
    if [[ $action == show ]]; then
        tofu -chdir="$workdir" show "$@"
        return
    fi
    if [[ $action == apply && $remote_backend != true ]]; then
        die "infra apply requires the production remote-backend input"
    fi
    tofu -chdir="$workdir" init -reconfigure "${backend_args[@]}"
    if [[ $action == plan ]]; then
        tofu -chdir="$workdir" plan "$@"
        return
    fi
    if [[ $action == output ]]; then
        tofu -chdir="$workdir" output "$@"
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

prepare_state() {
    root=$(repository_root)
    workdir="$root/.lucidity/tofu/state"
    mkdir -p "$workdir"
    config=$(build_path "$root#state.config")
    state_backend_config=${LUCIDITY_STATE_BACKEND_CONFIG:-$root/.lucidity/backend.state.s3.tfbackend}
    if [[ -f $state_backend_config ]]; then
        ln -sfn "$config" "$workdir/config.tf.json"
        backend_args=(-backend-config="$state_backend_config")
    elif [[ -n ${LUCIDITY_STATE_BACKEND_CONFIG:-} ]]; then
        die "LUCIDITY_STATE_BACKEND_CONFIG does not exist: $LUCIDITY_STATE_BACKEND_CONFIG"
    else
        rm -f "$workdir/config.tf.json"
        jq 'del(.terraform.backend)' "$config" >"$workdir/config.tf.json"
        backend_args=(-backend=false)
    fi
}

state() {
    action=${1:-}
    shift || true
    [[ $action =~ ^(plan|apply|output|show|migrate)$ ]] ||
        die "state requires plan, apply, output, show, or migrate"
    if [[ $action == migrate ]]; then
        backend_config=${1:-}
        [[ -f $backend_config && $# -eq 1 ]] || die "state migrate requires one existing backend configuration"
        export LUCIDITY_STATE_BACKEND_CONFIG
        LUCIDITY_STATE_BACKEND_CONFIG=$(realpath "$backend_config")
        prepare_state
        tofu -chdir="$workdir" init -migrate-state -force-copy "${backend_args[@]}"
        return
    fi
    if [[ $action == apply ]]; then
        saved_plan=${1:-}
        [[ -f $saved_plan ]] || die "state apply requires an existing saved plan as its first argument"
        saved_plan=$(realpath "$saved_plan")
        shift
    fi
    prepare_state
    if [[ $action == show ]]; then
        tofu -chdir="$workdir" show "$@"
        return
    fi
    tofu -chdir="$workdir" init -reconfigure "${backend_args[@]}"
    if [[ $action == plan ]]; then
        tofu -chdir="$workdir" plan "$@"
        return
    fi
    if [[ $action == output ]]; then
        tofu -chdir="$workdir" output "$@"
        return
    fi
    plan_json=$(mktemp "$workdir/plan.XXXXXX.json")
    trap 'rm -f "$plan_json"' RETURN
    tofu -chdir="$workdir" show -json "$saved_plan" >"$plan_json"
    unsafe_changes=$(jq '[.resource_changes[].change.actions | select(index("delete"))] | length' "$plan_json")
    ((unsafe_changes == 0)) || die "refusing a state-bootstrap plan containing $unsafe_changes destructive change(s)"
    tofu -chdir="$workdir" apply "$@" "$saved_plan"
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

release_local() {
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

release_prepare() {
    requested_bump=${1:-}
    [[ $requested_bump =~ ^(auto|patch|minor|major)$ && $# -eq 1 ]] ||
        die "release prepare requires auto, patch, minor, or major"
    root=$(repository_root)
    [[ ${GITHUB_REF:-refs/heads/main} == refs/heads/main ]] || die "releases may run only from main"
    seed_version=$(<"$root/VERSION")
    [[ $seed_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must contain X.Y.Z"
    source_sha=$(git -C "$root" rev-parse HEAD)
    if [[ -n ${GITHUB_SHA:-} && $source_sha != "$GITHUB_SHA" ]]; then
        die "checkout does not match the dispatched commit"
    fi

    last_tag=$(git -C "$root" tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname |
        grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)
    if [[ -z $last_tag ]]; then
        version=$seed_version
        selected_bump=initial
    else
        [[ $(git -C "$root" rev-list --count "$last_tag..HEAD") -gt 0 ]] ||
            die "no commits exist after $last_tag"
        git -C "$root" merge-base --is-ancestor "$last_tag" HEAD ||
            die "latest release tag $last_tag is not an ancestor of main"
        base_version=${last_tag#v}
        IFS=. read -r major minor patch <<<"$base_version"
        selected_bump=$requested_bump
        if [[ $selected_bump == auto ]]; then
            release_log=$(git -C "$root" log "$last_tag..HEAD" --format='%s%n%b')
            if grep -Eq '(^[[:alnum:]-]+(\([^)]*\))?!:)|(^BREAKING[ -]CHANGE:)' <<<"$release_log"; then
                selected_bump="major"
            elif grep -Eq '^feat(\([^)]*\))?:' <<<"$release_log"; then
                selected_bump="minor"
            else
                selected_bump="patch"
            fi
        fi
        case "$selected_bump" in
            major) version="$((major + 1)).0.0" ;;
            minor) version="${major}.$((minor + 1)).0" ;;
            patch) version="${major}.${minor}.$((patch + 1))" ;;
            *) die "unsupported release bump: $selected_bump" ;;
        esac
    fi
    tag=v$version
    tag_commit=$(git -C "$root" rev-parse --verify --quiet "refs/tags/$tag^{commit}" || true)
    if release_state=$(gh release view "$tag" --json isDraft,targetCommitish 2>/dev/null); then
        [[ $(jq -r .isDraft <<<"$release_state") == true ]] || die "published GitHub release $tag already exists"
        [[ $(jq -r .targetCommitish <<<"$release_state") == "$source_sha" ]] || die "draft $tag targets a different commit"
        [[ -z $tag_commit || $tag_commit == "$source_sha" ]] || die "draft $tag has a conflicting Git tag"
    elif [[ -n $tag_commit ]]; then
        die "Git tag $tag already exists without a resumable draft release"
    fi
    if [[ -n ${GITHUB_OUTPUT:-} ]]; then
        printf 'source_sha=%s\ntag=%s\nversion=%s\n' "$source_sha" "$tag" "$version" >>"$GITHUB_OUTPUT"
    fi
    printf 'Selected %s with a %s bump from %s\n' "$tag" "$selected_bump" "${last_tag:-VERSION seed}"
}

release_image() {
    role=${1:-}
    repository_url=${2:-}
    release_tag=${3:-}
    source_sha=${4:-}
    [[ $role =~ ^(controller|worker)$ && $# -eq 4 ]] ||
        die "release image requires ROLE REPOSITORY_URL RELEASE_TAG SOURCE_SHA"
    [[ $source_sha =~ ^[0-9a-f]{40}$ ]] || die "source SHA must be a full lowercase Git SHA"
    [[ $release_tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "release tag must be v-prefixed SemVer"
    [[ $repository_url =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9]+([._/-][a-z0-9]+)*$ ]] ||
        die "the $role ECR repository URL is missing or invalid"
    region=${AWS_REGION:-us-east-2}
    repository_name=${repository_url#*/}
    source_tag=sha-$source_sha
    source_response=$(aws ecr batch-get-image --region "$region" --repository-name "$repository_name" \
        --image-ids "imageTag=$source_tag" --accepted-media-types \
        application/vnd.oci.image.manifest.v1+json \
        application/vnd.docker.distribution.manifest.v2+json --output json)
    source_digest=$(jq -r '.images[0].imageId.imageDigest // empty' <<<"$source_response")
    image_manifest=$(jq -r '.images[0].imageManifest // empty' <<<"$source_response")
    media_type=$(jq -r '.images[0].imageManifestMediaType // empty' <<<"$source_response")
    [[ $source_digest =~ ^sha256:[0-9a-f]{64}$ && -n $image_manifest && -n $media_type ]] ||
        die "immutable candidate $repository_url:$source_tag is unavailable"
    release_digest=$(aws ecr batch-get-image --region "$region" --repository-name "$repository_name" \
        --image-ids "imageTag=$release_tag" --query 'images[0].imageId.imageDigest' --output text)
    if [[ -n $release_digest && $release_digest != None ]]; then
        [[ $release_digest == "$source_digest" ]] || die "immutable $release_tag already refers to a different digest"
    else
        aws ecr put-image --region "$region" --repository-name "$repository_name" \
            --image-tag "$release_tag" --image-manifest "$image_manifest" \
            --image-manifest-media-type "$media_type" >/dev/null
    fi
    verified_digest=$(aws ecr batch-get-image --region "$region" --repository-name "$repository_name" \
        --image-ids "imageTag=$release_tag" --query 'images[0].imageId.imageDigest' --output text)
    [[ $verified_digest == "$source_digest" ]] || die "release digest verification failed"

    registry=${repository_url%%/*}
    aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$registry"
    trap 'docker logout "$registry" >/dev/null 2>&1 || true' RETURN
    immutable_image=$repository_url@$source_digest
    docker pull "$immutable_image"
    release_dir=${LUCIDITY_RELEASE_DIR:-release}
    install -d -m 0755 "$release_dir"
    sbom_path=$release_dir/$role.sbom.spdx.json
    syft scan "$immutable_image" --config "$LUCIDITY_SYFT_CONFIG" \
        --exclude './nix/store/**' --source-name "$repository_url" --source-version "$source_digest" \
        --output spdx-json | jq -c '
          .packages |= map(
            if has("externalRefs") then
              .externalRefs |= map(select(.referenceType != "cpe23Type")) |
              if (.externalRefs | length) == 0 then del(.externalRefs) else . end
            else . end
          )
        ' >"$sbom_path"
    jq -e 'type == "object" and (.spdxVersion | startswith("SPDX-")) and (.packages | type == "array")' "$sbom_path" >/dev/null
    sbom_sha256=$(sha256sum "$sbom_path" | cut -d' ' -f1)
    asset=lucidity-$role-$release_tag.spdx.json.gz
    gzip -9c "$sbom_path" >"$release_dir/$asset"
    (cd "$release_dir" && sha256sum "$asset" >"$asset.sha256")
    asset_sha256=$(sha256sum "$release_dir/$asset" | cut -d' ' -f1)
    jq -n --arg role "$role" --arg repository "$repository_url" --arg source_tag "$source_tag" \
        --arg release_tag "$release_tag" --arg digest "$source_digest" --arg sbom_asset "$asset" \
        --arg sbom_sha256 "$sbom_sha256" --arg sbom_asset_sha256 "$asset_sha256" \
        '{role:$role,repository:$repository,source_tag:$source_tag,release_tag:$release_tag,digest:$digest,sbom_asset:$sbom_asset,sbom_sha256:$sbom_sha256,sbom_asset_sha256:$sbom_asset_sha256}' \
        >"$release_dir/$role.metadata.json"
    if [[ -n ${GITHUB_OUTPUT:-} ]]; then
        printf 'digest=%s\npath=%s\nrepository_name=%s\n' "$source_digest" "$sbom_path" "$repository_name" >>"$GITHUB_OUTPUT"
    fi
}

release_inventory() {
    release_tag=${1:-}
    [[ $release_tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && $# -eq 1 ]] || die "release inventory requires RELEASE_TAG"
    release_dir=${LUCIDITY_RELEASE_DIR:-release}
    mapfile -t metadata_files < <(find "$release_dir" -maxdepth 1 -type f -name '*.metadata.json' -print | sort)
    [[ ${#metadata_files[@]} -eq 2 ]] || die "expected controller and worker release inventories"
    jq -s -e --arg release_tag "$release_tag" '
      length == 2 and ([.[].role] | sort == ["controller","worker"]) and
      all(.[]; (.digest | test("^sha256:[0-9a-f]{64}$"))) and
      all(.[]; (.sbom_sha256 | test("^[0-9a-f]{64}$"))) and
      all(.[]; .release_tag == $release_tag)
    ' "${metadata_files[@]}" >/dev/null
    for role in controller worker; do
        metadata=$(jq -c --arg role "$role" 'select(.role == $role)' "${metadata_files[@]}")
        if [[ -n ${GITHUB_OUTPUT:-} ]]; then
            printf '%s_digest=%s\n%s_sbom_sha256=%s\n' "$role" "$(jq -r .digest <<<"$metadata")" \
                "$role" "$(jq -r .sbom_sha256 <<<"$metadata")" >>"$GITHUB_OUTPUT"
        fi
    done
}

release_manifest() {
    release_tag=${1:-}
    version=${2:-}
    source_sha=${3:-}
    [[ $release_tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $source_sha =~ ^[0-9a-f]{40}$ && $# -eq 3 ]] ||
        die "release manifest requires RELEASE_TAG VERSION SOURCE_SHA"
    release_dir=${LUCIDITY_RELEASE_DIR:-release}
    region=${AWS_REGION:-us-east-2}
    images=$(jq -s 'sort_by(.role)' "$release_dir"/*.metadata.json)
    amis='{}'
    for role in controller worker; do
        image_digest=$(jq -r --arg role "$role" '.[] | select(.role == $role) | .digest' <<<"$images")
        sbom_sha256=$(jq -r --arg role "$role" '.[] | select(.role == $role) | .sbom_sha256' <<<"$images")
        ami_response=$(aws ec2 describe-images --region "$region" --owners self --filters \
            'Name=tag:Project,Values=lucidity' 'Name=tag:Purpose,Values=ami-release' \
            "Name=tag:Role,Values=$role" "Name=tag:SourceRevision,Values=$source_sha" \
            "Name=tag:ReleaseVersion,Values=$release_tag" "Name=tag:SourceImageDigest,Values=$image_digest" \
            "Name=tag:SbomSha256,Values=$sbom_sha256" 'Name=tag:ReleaseStatus,Values=validated' --output json)
        [[ $(jq '.Images | length' <<<"$ami_response") -eq 1 ]] || die "expected exactly one validated retained $role release AMI"
        ami_id=$(jq -r '.Images[0].ImageId' <<<"$ami_response")
        snapshot_id=$(jq -r '.Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' <<<"$ami_response")
        snapshot_response=$(aws ec2 describe-snapshots --region "$region" --snapshot-ids "$snapshot_id" --output json)
        [[ $(jq -r '.Snapshots[0].Encrypted' <<<"$snapshot_response") == true ]] || die "$role snapshot is not encrypted"
        kms_arn=$(jq -r '.Snapshots[0].KmsKeyId // empty' <<<"$snapshot_response")
        volume_size=$(jq -r '.Snapshots[0].VolumeSize // empty' <<<"$snapshot_response")
        [[ $ami_id =~ ^ami-[0-9a-f]+$ && $snapshot_id =~ ^snap-[0-9a-f]+$ && $kms_arn =~ ^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-f-]+$ && $volume_size =~ ^[1-9][0-9]*$ ]] ||
            die "$role AMI metadata is invalid"
        ami_record=$(jq -n --arg ami_id "$ami_id" --arg name "$(jq -r '.Images[0].Name // empty' <<<"$ami_response")" \
            --arg created_at "$(jq -r '.Images[0].CreationDate // empty' <<<"$ami_response")" --arg snapshot_id "$snapshot_id" \
            --arg snapshot_kms_key_arn "$kms_arn" --argjson snapshot_volume_size_gib "$volume_size" \
            --arg source_image_digest "$image_digest" --arg sbom_sha256 "$sbom_sha256" \
            --arg validation_run "https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}" \
            '{ami_id:$ami_id,name:$name,created_at:$created_at,snapshot_id:$snapshot_id,snapshot_kms_key_arn:$snapshot_kms_key_arn,snapshot_volume_size_gib:$snapshot_volume_size_gib,source_image_digest:$source_image_digest,sbom_sha256:$sbom_sha256,validation_run:$validation_run}')
        amis=$(jq -cn --argjson current "$amis" --arg role "$role" --argjson record "$ami_record" '$current + {($role):$record}')
    done
    jq -n --argjson schema_version 2 --arg version "$version" --arg tag "$release_tag" --arg source_commit "$source_sha" \
        --arg created_at "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" --arg region "$region" \
        --arg repository "$GITHUB_REPOSITORY" --arg release_run "https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}" \
        --argjson images "$images" --argjson amis "$amis" \
        '{schema_version:$schema_version,version:$version,tag:$tag,source_commit:$source_commit,created_at:$created_at,repository:$repository,release_run:$release_run,images:$images,aws:{region:$region,amis:$amis}}' \
        >"$release_dir/release-manifest.json"
    (cd "$release_dir" && sha256sum release-manifest.json >release-manifest.json.sha256)
}

release_publish() {
    release_tag=${1:-}
    version=${2:-}
    source_sha=${3:-}
    [[ $release_tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $source_sha =~ ^[0-9a-f]{40}$ && $# -eq 3 ]] ||
        die "release publish requires RELEASE_TAG VERSION SOURCE_SHA"
    release_dir=${LUCIDITY_RELEASE_DIR:-release}
    mapfile -t assets < <(find "$release_dir" -maxdepth 1 -type f \
        \( -name '*.spdx.json.gz' -o -name '*.spdx.json.gz.sha256' -o -name 'release-manifest.json' -o -name 'release-manifest.json.sha256' \) -print | sort)
    [[ ${#assets[@]} -eq 6 ]] || die "expected two SBOMs, their checksums, and the release manifest pair"
    if release_state=$(gh release view "$release_tag" --json isDraft,targetCommitish 2>/dev/null); then
        [[ $(jq -r .isDraft <<<"$release_state") == true && $(jq -r .targetCommitish <<<"$release_state") == "$source_sha" ]] ||
            die "existing release is not the expected resumable draft"
        gh release upload "$release_tag" "${assets[@]}" --clobber
    else
        gh release create "$release_tag" "${assets[@]}" --draft --generate-notes --target "$source_sha" --title "Lucidity $version"
    fi
    mapfile -t expected_names < <(printf '%s\n' "${assets[@]##*/}" | sort)
    mapfile -t actual_names < <(gh release view "$release_tag" --json assets --jq '.assets[].name' | sort)
    [[ ${expected_names[*]} == "${actual_names[*]}" ]] || die "draft release asset set does not match the verified release inventory"
    gh release edit "$release_tag" --draft=false
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
        printf '## Immutable Lucidity release %s\n\nPublished tested ECR digests, SPDX SBOMs, checksums, and both retained EBS Direct AMIs without rebuilding the images.\n' \
            "$release_tag" >>"$GITHUB_STEP_SUMMARY"
    fi
}

release_command() {
    action=${1:-}
    shift || true
    case "$action" in
        local) [[ $# -eq 0 ]] || die "release local accepts no arguments"; release_local ;;
        prepare) release_prepare "$@" ;;
        image) release_image "$@" ;;
        inventory) release_inventory "$@" ;;
        manifest) release_manifest "$@" ;;
        publish) release_publish "$@" ;;
        *) die "release requires local, prepare, image, inventory, manifest, or publish" ;;
    esac
}

command=${1:-}
shift || true
case "$command" in
    generate) generate "$@" ;;
    check) check "$@" ;;
    build) build_role "$@" ;;
    disk) disk_command "$@" ;;
    ami) ami_command "$@" ;;
    vm) vm_command "$@" ;;
    ci) ci_command "$@" ;;
    infra) infra "$@" ;;
    state) state "$@" ;;
    secrets) secrets_command "$@" ;;
    mesh) mesh "$@" ;;
    release) release_command "$@" ;;
    -h|--help|help|"") usage ;;
    *) usage >&2; exit 2 ;;
esac
