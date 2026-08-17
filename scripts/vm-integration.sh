#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root

controller_vm_dir=${CONTROLLER_VM_DIR:-${repo_root}/image-output/vm-controller}
worker_vm_dir=${WORKER_VM_DIR:-${repo_root}/image-output/vm}
controller_ssh_port=${CONTROLLER_VM_SSH_PORT:-2223}
worker_ssh_port=${WORKER_VM_SSH_PORT:-2222}
worker_guest_address=${WORKER_GUEST_ADDRESS:-10.0.2.2}
controller_api_url=${CONTROLLER_API_URL:-http://127.0.0.1:8000/api/v1}
worker_probe_url=${WORKER_PROBE_URL:-http://127.0.0.1:8081}
wait_attempts=${INTEGRATION_WAIT_ATTEMPTS:-120}
wait_seconds=${INTEGRATION_WAIT_SECONDS:-5}

for command in curl jq ssh ssh-keygen base64; do
    command -v "${command}" >/dev/null 2>&1 || { echo "${command} is required" >&2; exit 1; }
done
for port_name in controller_ssh_port worker_ssh_port; do
    port_value=${!port_name}
    [[ ${port_value} =~ ^[0-9]+$ && ${port_value} -gt 0 && ${port_value} -le 65535 ]] || {
        echo "${port_name^^} must be an integer from 1 through 65535" >&2
        exit 2
    }
done
[[ ${wait_attempts} =~ ^[1-9][0-9]*$ ]] || { echo "INTEGRATION_WAIT_ATTEMPTS must be a positive integer" >&2; exit 2; }
[[ ${wait_seconds} =~ ^[0-9]+$ ]] || { echo "INTEGRATION_WAIT_SECONDS must be a non-negative integer" >&2; exit 2; }
[[ ${worker_guest_address} =~ ^[[:alnum:].:-]+$ ]] || { echo "WORKER_GUEST_ADDRESS is invalid" >&2; exit 2; }
[[ ${controller_api_url} =~ ^http://127\.0\.0\.1:[0-9]+/api/v1$ ]] || { echo "CONTROLLER_API_URL must use loopback HTTP and /api/v1" >&2; exit 2; }
[[ ${worker_probe_url} =~ ^http://127\.0\.0\.1:[0-9]+$ ]] || { echo "WORKER_PROBE_URL must use loopback HTTP" >&2; exit 2; }

controller_identity=${controller_vm_dir}/admin
worker_identity=${worker_vm_dir}/admin
[[ -f ${controller_identity} ]] || { echo "controller VM administrator identity is missing" >&2; exit 1; }
[[ -f ${worker_identity} ]] || { echo "worker VM administrator identity is missing" >&2; exit 1; }

ssh_base=(
    ssh
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
)
controller_ssh=("${ssh_base[@]}" -p "${controller_ssh_port}" -i "${controller_identity}" admin@127.0.0.1 sudo -n)
worker_ssh=("${ssh_base[@]}" -p "${worker_ssh_port}" -i "${worker_identity}" admin@127.0.0.1 sudo -n)

controller_public_key=$("${controller_ssh[@]}" cat /data/coolify/ssh/id.root@host.docker.internal.pub)
if ! ssh-keygen -lf /dev/stdin <<<"${controller_public_key}" >/dev/null; then
    echo "controller returned an invalid public key" >&2
    exit 1
fi
controller_public_key_base64=$(printf '%s\n' "${controller_public_key}" | base64 -w 0)
"${worker_ssh[@]}" bash -Eeuo pipefail -s -- "${controller_public_key_base64}" <<'REMOTE'
public_key_base64=$1
install -d -m 0700 /etc/coolify-worker
temporary=$(mktemp /etc/coolify-worker/.authorized_keys.XXXXXX)
trap 'rm -f "${temporary}"' EXIT
printf '%s' "${public_key_base64}" | base64 -d >"${temporary}"
chmod 0600 "${temporary}"
mv "${temporary}" /etc/coolify-worker/authorized_keys
trap - EXIT
systemctl restart coolify-worker-authorized-keys.service
REMOTE
unset controller_public_key controller_public_key_base64

"${controller_ssh[@]}" bash -Eeuo pipefail -s -- "${worker_guest_address}" "${worker_ssh_port}" <<'REMOTE'
worker_address=$1
worker_port=$2
known_hosts=$(mktemp)
trap 'rm -f "${known_hosts}"' EXIT
ssh-keyscan -T 5 -p "${worker_port}" "${worker_address}" >"${known_hosts}" 2>/dev/null
[[ -s ${known_hosts} ]]
ssh-keygen -lf "${known_hosts}" >/dev/null
ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="${known_hosts}" \
    -i /data/coolify/ssh/id.root@host.docker.internal \
    -p "${worker_port}" \
    "root@${worker_address}" \
    'systemctl is-active --quiet docker.service'
REMOTE
echo "Controller-to-worker SSH passed"

if ! token_output=$("${controller_ssh[@]}" bash -Eeuo pipefail -s <<'REMOTE'
php_program=$(cat <<'PHP'
$stage = "application bootstrap";
try {
    require '/var/www/html/vendor/autoload.php';
    $app = require '/var/www/html/bootstrap/app.php';
    $kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);
    $kernel->bootstrap();

    $stage = "instance settings";
    $settings = App\Models\InstanceSettings::findOrFail(0);
    $settings->is_api_enabled = true;
    $settings->save();

    $stage = "root user";
    $user = App\Models\User::find(0);
    if ($user === null) {
        $user = (new App\Models\User())->forceFill([
            "id" => 0,
            "name" => "Lucidity Integration",
            "email" => "integration@example.com",
            "password" => Illuminate\Support\Facades\Hash::make(
                Illuminate\Support\Str::random(64)
            ),
        ]);
        $user->save();
    }

    $stage = "root team";
    $team = $user->teams()->first();
    if ($team === null) {
        $team = $user->recreate_personal_team();
    }

    $stage = "controller private key";
    $privateKey = App\Models\PrivateKey::where("team_id", $team->id)->first();
    if ($privateKey === null) {
        $privateKeyPath = storage_path("app/ssh/id.root@host.docker.internal");
        $privateKeyMaterial = file_get_contents($privateKeyPath);
        if ($privateKeyMaterial === false || trim($privateKeyMaterial) === "") {
            throw new RuntimeException("controller private key is unavailable");
        }
        $privateKey = App\Models\PrivateKey::createAndStore([
            "name" => "lucidity-local-controller",
            "description" => "Disposable two-VM integration identity",
            "private_key" => $privateKeyMaterial,
            "is_git_related" => false,
            "team_id" => $team->id,
        ]);
        unset($privateKeyMaterial);
    }

    $stage = "default project";
    $project = App\Models\Project::where("team_id", $team->id)->first();
    if ($project === null) {
        $project = App\Models\Project::create([
            "name" => "Lucidity Integration",
            "description" => "Disposable controller-worker integration project",
            "team_id" => $team->id,
        ]);
    }

    $stage = "access token";
    $user->tokens()->where("name", "lucidity-local-integration")->delete();
    $entropy = Illuminate\Support\Str::random(40);
    $plain = $entropy.hash("crc32b", $entropy);
    $user->tokens()->create([
        "name" => "lucidity-local-integration",
        "token" => hash("sha256", $plain),
        "abilities" => ["read", "write", "deploy"],
        "expires_at" => now()->addHour(),
        "team_id" => $team->id,
    ]);
    fwrite(STDOUT, "LUCIDITY_TOKEN={$plain}\n");
    fwrite(STDOUT, "LUCIDITY_KEY_UUID={$privateKey->uuid}\n");
    fwrite(STDOUT, "LUCIDITY_PROJECT_UUID={$project->uuid}\n");
} catch (Throwable $error) {
    fwrite(STDERR, "Coolify token bootstrap failed during {$stage} (".get_class($error).")\n");
    exit(70);
}
PHP
)
docker exec coolify php -r "$php_program"
REMOTE
); then
    unset token_output
    echo "Coolify failed while creating the integration API token" >&2
    exit 1
fi
api_token=
private_key_uuid=
project_uuid=
token_output_length=${#token_output}
if [[ ${token_output} =~ LUCIDITY_TOKEN=([[:alnum:]]{48}) ]]; then
    api_token=${BASH_REMATCH[1]}
fi
if [[ ${token_output} =~ LUCIDITY_KEY_UUID=([[:alnum:]-]+) ]]; then
    private_key_uuid=${BASH_REMATCH[1]}
fi
if [[ ${token_output} =~ LUCIDITY_PROJECT_UUID=([[:alnum:]-]+) ]]; then
    project_uuid=${BASH_REMATCH[1]}
fi
if [[ -z ${api_token} ]]; then
    if [[ ${token_output} == *LUCIDITY_TOKEN=* ]]; then
        echo "Coolify returned a malformed integration API token marker (${token_output_length} captured bytes)" >&2
    else
        echo "Coolify returned no integration API token marker (${token_output_length} captured bytes)" >&2
    fi
fi
unset token_output
unset token_output_length
[[ ${api_token} =~ ^[[:alnum:]]{48}$ ]] || { echo "Coolify did not create the integration API token" >&2; exit 1; }
[[ ${private_key_uuid} =~ ^[[:alnum:]-]+$ ]] || { echo "Coolify did not bootstrap the controller private key" >&2; exit 1; }
[[ ${project_uuid} =~ ^[[:alnum:]-]+$ ]] || { echo "Coolify did not bootstrap the integration project" >&2; exit 1; }
echo "Coolify integration API token created"

api_request() {
    local method=$1
    local path=$2
    local body=${3:-}
    local arguments=(
        --fail-with-body
        --silent
        --show-error
        --request "${method}"
        --header "Authorization: Bearer ${api_token}"
        --header 'Accept: application/json'
    )
    if [[ -n ${body} ]]; then
        arguments+=(--header 'Content-Type: application/json' --data "${body}")
    fi
    curl "${arguments[@]}" "${controller_api_url}${path}"
}

api_json() {
    api_request "$@" | jq -c 'if type == "string" then fromjson else . end'
}

api_json GET /security/keys | jq -e --arg uuid "${private_key_uuid}" \
    'any(.[]; .uuid == $uuid)' >/dev/null || {
    echo "Coolify API did not return the bootstrapped controller private key" >&2
    exit 1
}
api_json GET /projects | jq -e --arg uuid "${project_uuid}" \
    'any(.[]; .uuid == $uuid)' >/dev/null || {
    echo "Coolify API did not return the bootstrapped integration project" >&2
    exit 1
}

server_request=$(jq -nc \
    --arg name lucidity-local-worker \
    --arg ip "${worker_guest_address}" \
    --arg key "${private_key_uuid}" \
    --argjson port "${worker_ssh_port}" \
    '{name:$name,description:"Disposable two-VM integration worker",ip:$ip,port:$port,user:"root",private_key_uuid:$key,is_build_server:false,instant_validate:true,proxy_type:"none"}')
server_uuid=$(api_json POST /servers "${server_request}" | jq -er '.uuid')

server_ready=false
for ((attempt = 1; attempt <= wait_attempts; attempt++)); do
    server=$(api_json GET "/servers/${server_uuid}")
    if jq -e '.settings.is_reachable == true and .settings.is_usable == true' <<<"${server}" >/dev/null; then
        server_ready=true
        break
    fi
    sleep "${wait_seconds}"
done
if [[ ${server_ready} != true ]]; then
    jq -r '.validation_logs // "Coolify returned no server validation log"' <<<"${server}" >&2
    echo "Coolify did not validate the worker" >&2
    exit 1
fi
echo "Coolify worker registration passed"

compose=$(base64 -w 0 <<'COMPOSE'
services:
  web:
    image: busybox:1.37.0-musl@sha256:fc6dddc4c44b1bfe37f41cae8e67d1693828e8f42a91862816d7953e2c9d3f23
    command:
      - sh
      - -c
      - mkdir -p /www && printf 'lucidity controller-worker integration passed\n' > /www/index.html && exec httpd -f -p 8080 -h /www
    ports:
      - '8080:8080'
COMPOSE
)
service_request=$(jq -nc \
    --arg project "${project_uuid}" \
    --arg server "${server_uuid}" \
    --arg compose "${compose}" \
    '{name:"lucidity-integration-app",description:"Disposable Milestone 5 probe",project_uuid:$project,environment_name:"production",server_uuid:$server,docker_compose_raw:$compose,instant_deploy:false}')
service_uuid=$(api_json POST /services "${service_request}" | jq -er '.uuid')
[[ ${service_uuid} =~ ^[[:alnum:]-]+$ ]] || { echo "Coolify returned an invalid service UUID" >&2; exit 1; }
api_json POST "/services/${service_uuid}/start" >/dev/null
echo "Coolify service deployment queued"

application_ready=false
for ((attempt = 1; attempt <= wait_attempts; attempt++)); do
    if response=$(curl --fail --silent --show-error --max-time 5 "${worker_probe_url}" 2>/dev/null) && \
        [[ ${response} == 'lucidity controller-worker integration passed' ]]; then
        application_ready=true
        break
    fi
    sleep "${wait_seconds}"
done
unset api_token
if [[ ${application_ready} != true ]]; then
    "${controller_ssh[@]}" bash -Eeuo pipefail -s -- "${service_uuid}" <<'REMOTE'
service_uuid=$1
php_program=$(cat <<'PHP'
$serviceUuid = $argv[1];

require '/var/www/html/vendor/autoload.php';
$app = require '/var/www/html/bootstrap/app.php';
$kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);
$kernel->bootstrap();

$activity = Spatie\Activitylog\Models\Activity::where(
    "properties->type_uuid",
    $serviceUuid
)->latest()->first();
$status = data_get($activity, "properties.status", "missing");
$exitCode = data_get($activity, "properties.exitCode", "unknown");
fwrite(STDERR, "Coolify service activity status: {$status} (exit {$exitCode})\n");

$error = trim(remove_iip((string) data_get($activity, "properties.stderr", "")));
$error = preg_replace('/\s+/', ' ', $error);
if ($error !== "") {
    fwrite(STDERR, "Coolify service activity error: ".substr($error, 0, 400)."\n");
}

$failedJob = Illuminate\Support\Facades\DB::table("failed_jobs")
    ->latest("id")
    ->first();
if ($failedJob !== null) {
    $payload = json_decode($failedJob->payload, true);
    $jobName = basename(str_replace("\\", "/", data_get($payload, "displayName", "unknown")));
    $exception = trim(remove_iip((string) $failedJob->exception));
    $firstLine = strtok($exception, "\n") ?: "unknown";
    fwrite(STDERR, "Latest failed Coolify job: {$jobName}: ".substr($firstLine, 0, 400)."\n");
}
PHP
)
docker exec coolify php -r "$php_program" "${service_uuid}"
REMOTE
    "${worker_ssh[@]}" docker ps --all >&2 || true
    echo "Coolify did not deploy the integration application to the worker" >&2
    exit 1
fi

"${worker_ssh[@]}" docker ps --filter label=coolify.managed=true --format '{{.Names}}' | grep -q .
echo "Coolify deployed and served the application from the worker"
