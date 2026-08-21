#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/metrics" "$work_dir/backup"
printf 'controller\n' > "$work_dir/role"
printf '0.3.0\n' > "$work_dir/version"
touch -d '5 minutes ago' "$work_dir/backup/last-success"
touch "$work_dir/backup.env"

systemctl() {
    [[ $1 == is-active && $2 == --quiet ]]
    [[ $3 != grafana.service ]]
}
docker() {
    printf 'one\ntwo\n'
}
export -f systemctl docker

LUCIDITY_ROLE_FILE="$work_dir/role" \
LUCIDITY_VERSION_FILE="$work_dir/version" \
LUCIDITY_METRICS_DIRECTORY="$work_dir/metrics" \
LUCIDITY_BACKUP_CONFIG="$work_dir/backup.env" \
LUCIDITY_BACKUP_SUCCESS_FILE="$work_dir/backup/last-success" \
    bash "$repo_root/nix/den/classes/bootc/files/monitoring-collector.sh"

metrics=$work_dir/metrics/lucidity.prom
grep -Fq 'lucidity_release_info{role="controller",version="0.3.0"} 1' "$metrics"
grep -Fq 'lucidity_backup_configured{role="controller"} 1' "$metrics"
grep -Eq 'lucidity_backup_last_success_timestamp_seconds\{role="controller"\} [1-9][0-9]+' "$metrics"
grep -Fq 'lucidity_docker_unhealthy_containers{role="controller"} 2' "$metrics"
grep -Fq 'lucidity_role_service_active{role="controller",service="grafana.service"} 0' "$metrics"
[[ $(stat --format=%a "$metrics") == 644 ]]

printf 'invalid role\n' > "$work_dir/role"
if LUCIDITY_ROLE_FILE="$work_dir/role" bash "$repo_root/nix/den/classes/bootc/files/monitoring-collector.sh" 2>/dev/null; then
    echo 'collector accepted an invalid role' >&2
    exit 1
fi
