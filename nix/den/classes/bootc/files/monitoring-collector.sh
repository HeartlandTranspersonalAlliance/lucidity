#!/usr/bin/env bash
set -Eeuo pipefail

role_file=${LUCIDITY_ROLE_FILE:-/etc/lucidity/role}
version_file=${LUCIDITY_VERSION_FILE:-/usr/lib/lucidity/image-version}
output_directory=${LUCIDITY_METRICS_DIRECTORY:-/var/lib/lucidity-monitoring/textfile}
backup_config=${LUCIDITY_BACKUP_CONFIG:-/etc/lucidity/backup-target.env}
backup_success=${LUCIDITY_BACKUP_SUCCESS_FILE:-/var/lib/lucidity-backup/last-success}

[[ -r $role_file ]] || { echo "role file is unavailable" >&2; exit 1; }
IFS= read -r role < "$role_file"
[[ $role == controller || $role == worker ]] || { echo "invalid role: $role" >&2; exit 1; }

version=dev
if [[ -r $version_file ]]; then
    IFS= read -r version < "$version_file"
fi
[[ $version =~ ^[0-9A-Za-z._+-]+$ ]] || version=unknown

install -d -m 0755 "$output_directory"
temporary=$(mktemp "$output_directory/.lucidity.prom.XXXXXX")
trap 'rm -f "$temporary"' EXIT

metric() {
    printf '%s\n' "$*" >> "$temporary"
}

metric '# HELP lucidity_release_info Immutable bootc image release identity.'
metric '# TYPE lucidity_release_info gauge'
metric "lucidity_release_info{role=\"$role\",version=\"$version\"} 1"

backup_configured=0
[[ -e $backup_config ]] && backup_configured=1
backup_timestamp=0
if [[ -e $backup_success ]]; then
    backup_timestamp=$(stat --format=%Y "$backup_success")
fi
metric '# HELP lucidity_backup_configured Whether application backup is configured.'
metric '# TYPE lucidity_backup_configured gauge'
metric "lucidity_backup_configured{role=\"$role\"} $backup_configured"
metric '# HELP lucidity_backup_last_success_timestamp_seconds Unix timestamp of the last successful application backup.'
metric '# TYPE lucidity_backup_last_success_timestamp_seconds gauge'
metric "lucidity_backup_last_success_timestamp_seconds{role=\"$role\"} $backup_timestamp"

unhealthy=0
if systemctl is-active --quiet docker.service; then
    unhealthy=$(docker ps --quiet --filter health=unhealthy 2>/dev/null | wc -l)
fi
metric '# HELP lucidity_docker_unhealthy_containers Number of unhealthy Docker containers.'
metric '# TYPE lucidity_docker_unhealthy_containers gauge'
metric "lucidity_docker_unhealthy_containers{role=\"$role\"} $unhealthy"

common_services=(docker.service nebula.service lucidity-backup.timer)
if [[ $role == controller ]]; then
    role_services=(openbao.service coolify-controller-bootstrap.service prometheus.service prometheus-alertmanager.service prometheus-blackbox-exporter.service grafana.service ntfy.service)
else
    role_services=(coolify-worker-storage.service coolify-worker-authorized-keys.service)
fi
metric '# HELP lucidity_role_service_active Whether a required role service is active.'
metric '# TYPE lucidity_role_service_active gauge'
for service in "${common_services[@]}" "${role_services[@]}"; do
    active=0
    systemctl is-active --quiet "$service" && active=1
    metric "lucidity_role_service_active{role=\"$role\",service=\"$service\"} $active"
done

chmod 0644 "$temporary"
mv "$temporary" "$output_directory/lucidity.prom"
trap - EXIT
