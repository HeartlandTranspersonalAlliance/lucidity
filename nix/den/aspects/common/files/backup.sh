#!/bin/bash
# shellcheck shell=bash
set -Eeuo pipefail

readonly CONFIG_FILE="${LUCIDITY_BACKUP_CONFIG:-/etc/lucidity/backup-target.env}"
readonly ROLE_FILE="${LUCIDITY_ROLE_FILE:-/etc/lucidity/role}"
readonly SECRETSPEC_FILE="${LUCIDITY_SECRETSPEC_FILE:-/etc/lucidity/secretspec.toml}"
readonly RESTIC_BIN="${LUCIDITY_RESTIC_BIN:-restic}"
readonly SECRETSPEC_BIN="${LUCIDITY_SECRETSPEC_BIN:-secretspec}"
readonly STATE_DIRECTORY="${LUCIDITY_BACKUP_STATE_DIRECTORY:-/var/lib/lucidity-backup}"
readonly RESTORE_DIRECTORY="${LUCIDITY_RESTORE_DIRECTORY:-/var/lib/lucidity-restore}"

die() {
    echo "lucidity backup: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: lucidity backup init
       lucidity backup run
       lucidity backup check
       lucidity backup restore SNAPSHOT DESTINATION

Restore destinations must be new directories below /var/lib/lucidity-restore.
The command never replaces live data; promotion is a separate, reviewed step.
EOF
}

read_config() {
    [[ -r $CONFIG_FILE ]] || die "configuration is unavailable: $CONFIG_FILE"
    while IFS='=' read -r key value; do
        [[ -z $key || $key == \#* ]] && continue
        case "$key" in
            LUCIDITY_BACKUP_BACKEND) BACKEND=$value ;;
            LUCIDITY_BACKUP_REPOSITORY) REPOSITORY=$value ;;
            LUCIDITY_BACKUP_PATHS) BACKUP_PATHS=$value ;;
            LUCIDITY_BACKUP_HOOK_DIRECTORY) HOOK_DIRECTORY=$value ;;
            *) die "unsupported configuration key: $key" ;;
        esac
    done <"$CONFIG_FILE"

    [[ ${BACKEND:-} =~ ^(aws-s3|b2-s3|rustfs-s3|garage-s3)$ ]] ||
        die "LUCIDITY_BACKUP_BACKEND must be aws-s3, b2-s3, rustfs-s3, or garage-s3"
    [[ ${REPOSITORY:-} == s3:* ]] || die "the restic repository must use the S3 backend"
    if [[ $REPOSITORY != s3:https://* && $REPOSITORY != s3:s3.*.amazonaws.com/* ]]; then
        [[ ${LUCIDITY_BACKUP_ALLOW_INSECURE_TEST:-0} == 1 ]] ||
            die "the S3-compatible repository must use HTTPS"
    fi
    [[ -r $ROLE_FILE ]] || die "node role is unavailable: $ROLE_FILE"
    IFS= read -r ROLE <"$ROLE_FILE"
    [[ $ROLE == controller || $ROLE == worker ]] || die "invalid node role: $ROLE"
    [[ $REPOSITORY == */"$ROLE" || $REPOSITORY == */"$ROLE"/ ]] ||
        die "the repository must end in the isolated $ROLE prefix"

    HOOK_DIRECTORY=${HOOK_DIRECTORY:-/etc/lucidity/backup.d}
    BACKUP_PATHS=${BACKUP_PATHS:-}
    if [[ -z $BACKUP_PATHS ]]; then
        if [[ $ROLE == controller ]]; then
            BACKUP_PATHS=/var/lib/coolify:/var/lib/nebula:/var/lib/openbao/snapshots
        else
            BACKUP_PATHS=/var/lib/coolify:/var/lib/nebula
        fi
    fi
    IFS=':' read -r -a PATHS <<<"$BACKUP_PATHS"
    ((${#PATHS[@]} > 0)) || die "at least one backup path is required"
    for path in "${PATHS[@]}"; do
        [[ $path == /* && $path != / && $path != /var/lib/docker && $path != /var/lib/nix ]] ||
            die "unsafe backup path: $path"
    done

    if [[ $BACKEND == aws-s3 ]]; then
        PROFILE="backup-$ROLE-aws"
        SCOPE=backup-aws
    else
        PROFILE="backup-$ROLE-s3"
        SCOPE=backup-s3
    fi
}

run_restic() {
    local reason=$1
    shift
    local -a environment=(
        -u AWS_ACCESS_KEY_ID
        -u AWS_SECRET_ACCESS_KEY
        -u AWS_SESSION_TOKEN
        RESTIC_REPOSITORY="$REPOSITORY"
    )
    if [[ $ROLE == controller ]]; then
        environment+=(
            BAO_ADDR=https://127.0.0.1:8200
            BAO_CACERT=/var/lib/openbao/tls/server.crt
        )
        if [[ -n ${CREDENTIALS_DIRECTORY:-} && -s $CREDENTIALS_DIRECTORY/bao-token ]]; then
            environment+=(BAO_TOKEN_PATH="$CREDENTIALS_DIRECTORY/bao-token")
        fi
    fi
    env "${environment[@]}" "$SECRETSPEC_BIN" run \
        --file "$SECRETSPEC_FILE" \
        --profile "$PROFILE" \
        --scope "$SCOPE" \
        --reason "$reason" \
        -- "$RESTIC_BIN" "$@"
}

run_hooks() {
    [[ -d $HOOK_DIRECTORY ]] || return 0
    local hook
    while IFS= read -r -d '' hook; do
        [[ -x $hook ]] || die "backup hook is not executable: $hook"
        "$hook" "$STATE_DIRECTORY/staging/$ROLE"
    done < <(find "$HOOK_DIRECTORY" -maxdepth 1 -type f -name '*.sh' -print0 | sort -z)
}

initialize() {
    if run_restic "inspect the $ROLE backup repository" snapshots >/dev/null 2>&1; then
        echo "The $ROLE restic repository is already initialized."
        return
    fi
    run_restic "initialize the $ROLE backup repository" init
}

backup_run() {
    install -d -m 0700 "$STATE_DIRECTORY" "$STATE_DIRECTORY/staging" "$STATE_DIRECTORY/staging/$ROLE"
    exec 9>"$STATE_DIRECTORY/backup.lock"
    flock -n 9 || die "another backup operation is already running"
    if [[ $ROLE == controller && -e /run/systemd/system ]]; then
        systemctl start openbao-snapshot.service
    fi
    run_hooks
    local -a existing_paths=()
    local path
    for path in "${PATHS[@]}"; do
        if [[ -e $path ]]; then
            existing_paths+=("$path")
        else
            echo "lucidity backup: skipping absent path: $path" >&2
        fi
    done
    existing_paths+=("$STATE_DIRECTORY/staging/$ROLE")
    run_restic "back up $ROLE application data" backup \
        --host "lucidity-$ROLE" --tag lucidity --tag "$ROLE" --one-file-system \
        "${existing_paths[@]}"
    run_restic "apply the $ROLE backup retention policy" forget \
        --host "lucidity-$ROLE" --tag lucidity --tag "$ROLE" \
        --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
    touch "$STATE_DIRECTORY/last-success"
}

check_repository() {
    run_restic "verify the $ROLE backup repository" check --read-data-subset=5%
}

restore_snapshot() {
    local snapshot=${1:-}
    local destination=${2:-}
    [[ -n $snapshot && -n $destination && $# -eq 2 ]] || die "restore requires SNAPSHOT and DESTINATION"
    [[ $snapshot =~ ^(latest|[0-9a-f]{8,64})$ ]] || die "invalid snapshot identifier"
    [[ $destination == "$RESTORE_DIRECTORY"/* && $destination != "$RESTORE_DIRECTORY"/ ]] ||
        die "restore destination must be below $RESTORE_DIRECTORY"
    [[ ! -e $destination ]] || die "restore destination already exists"
    install -d -m 0700 "$RESTORE_DIRECTORY" "$destination"
    run_restic "stage the $ROLE restore" restore "$snapshot" --target "$destination"
    echo "Restore staged at $destination. Live data was not modified."
}

read_config
case "${1:-}" in
    init) [[ $# -eq 1 ]] || die "init accepts no arguments"; initialize ;;
    run) [[ $# -eq 1 ]] || die "run accepts no arguments"; backup_run ;;
    check) [[ $# -eq 1 ]] || die "check accepts no arguments"; check_repository ;;
    restore) shift; restore_snapshot "$@" ;;
    -h|--help|help|"") usage ;;
    *) usage >&2; exit 2 ;;
esac
