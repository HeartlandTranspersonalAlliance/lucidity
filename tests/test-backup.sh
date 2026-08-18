#!/bin/bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

mkdir -p "$test_dir/bin" "$test_dir/data" "$test_dir/hooks" "$test_dir/state" "$test_dir/restore"
printf 'worker\n' >"$test_dir/role"
printf 'fixture data\n' >"$test_dir/data/workload.txt"
cat >"$test_dir/config" <<EOF
LUCIDITY_BACKUP_BACKEND=garage-s3
LUCIDITY_BACKUP_REPOSITORY=s3:https://garage.example.test/backups/lucidity/worker
LUCIDITY_BACKUP_PATHS=$test_dir/data
LUCIDITY_BACKUP_HOOK_DIRECTORY=$test_dir/hooks
EOF

cat >"$test_dir/bin/secretspec" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
printf 'secretspec' >>"$MOCK_BACKUP_LOG"
printf ' %s' "$@" >>"$MOCK_BACKUP_LOG"
printf '\n' >>"$MOCK_BACKUP_LOG"
while [[ ${1:-} != -- ]]; do shift; done
shift
exec "$@"
EOF
cat >"$test_dir/bin/restic" <<'EOF'
#!/bin/bash
set -Eeuo pipefail
printf 'restic' >>"$MOCK_BACKUP_LOG"
printf ' %s' "$@" >>"$MOCK_BACKUP_LOG"
printf '\n' >>"$MOCK_BACKUP_LOG"
if [[ ${1:-} == snapshots && ! -e $MOCK_REPOSITORY_INITIALIZED ]]; then
    exit 1
fi
if [[ ${1:-} == init ]]; then
    : >"$MOCK_REPOSITORY_INITIALIZED"
fi
EOF
cat >"$test_dir/hooks/database.sh" <<EOF
#!/bin/bash
set -Eeuo pipefail
printf 'database dump\n' >"\$1/database.sql"
EOF
chmod +x "$test_dir/bin/secretspec" "$test_dir/bin/restic" "$test_dir/hooks/database.sh"
sed -i "1c#!${BASH}" "$test_dir/bin/secretspec" "$test_dir/bin/restic" "$test_dir/hooks/database.sh"

run_backup() {
    PATH="$test_dir/bin:$PATH" \
    MOCK_BACKUP_LOG="$test_dir/log" \
    MOCK_REPOSITORY_INITIALIZED="$test_dir/initialized" \
    LUCIDITY_BACKUP_CONFIG="$test_dir/config" \
    LUCIDITY_RESTIC_BIN="$test_dir/bin/restic" \
    LUCIDITY_ROLE_FILE="$test_dir/role" \
    LUCIDITY_SECRETSPEC_BIN="$test_dir/bin/secretspec" \
    LUCIDITY_SECRETSPEC_FILE="$repo_root/secretspec.toml" \
    LUCIDITY_BACKUP_STATE_DIRECTORY="$test_dir/state" \
    LUCIDITY_RESTORE_DIRECTORY="$test_dir/restore" \
        bash "$repo_root/nix/den/aspects/common/files/backup.sh" "$@"
}

run_backup init >/dev/null
run_backup init >/dev/null
run_backup run >/dev/null
run_backup check >/dev/null
run_backup restore latest "$test_dir/restore/drill-1" >/dev/null

grep -Fq -- '--profile backup-worker-s3' "$test_dir/log"
grep -Fq -- '--scope backup-s3' "$test_dir/log"
grep -Fq 'restic backup' "$test_dir/log"
grep -Fq -- '--keep-daily 7' "$test_dir/log"
grep -Fq -- '--keep-weekly 4' "$test_dir/log"
grep -Fq -- '--keep-monthly 6' "$test_dir/log"
grep -Fq -- 'check --read-data-subset=5%' "$test_dir/log"
grep -Fq 'restore latest' "$test_dir/log"
test -s "$test_dir/state/staging/worker/database.sql"

set +e
unsafe_output=$(run_backup restore latest /var/lib/coolify 2>&1)
unsafe_status=$?
set -e
[[ $unsafe_status -eq 1 ]]
grep -Fq 'restore destination must be below' <<<"$unsafe_output"

echo "Backup and staged-restore assertions passed"
