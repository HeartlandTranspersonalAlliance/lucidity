# shellcheck shell=bash
set -Eeuo pipefail

usage() {
    echo "usage: lucidity-pr-validation SHARD_ID" >&2
    exit 2
}

contract=@plan@
nix_command=@nixCommand@
shard_id=${1:-}
[[ $# -eq 1 && $shard_id =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]] || usage

jq -e '
  type == "object" and
  (keys | sort) == ["schemaVersion", "shards"] and
  .schemaVersion == 1 and
  (.shards | type == "array" and length >= 1 and length <= 3) and
  ([.shards[].id] as $ids | ($ids | length) == ($ids | unique | length)) and
  all(.shards[];
    type == "object" and
    (keys | sort) == ["id", "mutableProfiles", "pureProfiles"] and
    (.id | type == "string" and test("^[a-z0-9]+([._-][a-z0-9]+)*$")) and
    (.pureProfiles | type == "array") and
    all(.pureProfiles[];
      type == "object" and
      (keys | sort) == ["attribute", "id"] and
      (.id | type == "string" and test("^[a-z0-9]+([._-][a-z0-9]+)*$")) and
      (.attribute | type == "string" and test("^checks\\.[a-z0-9_+.-]+\\.[a-z0-9]+([._-][a-z0-9]+)*$"))
    ) and
    (.mutableProfiles | type == "array") and
    all(.mutableProfiles[];
      type == "object" and
      (keys | sort) == ["id"] and
      (.id | type == "string" and test("^[a-z0-9]+([._-][a-z0-9]+)*$"))
    ) and
    (([.pureProfiles[].id] + [.mutableProfiles[].id]) as $profiles |
      ($profiles | length) == ($profiles | unique | length))
  ) and
  ([.shards[] | .pureProfiles[].attribute] as $attributes |
    ($attributes | length) == ($attributes | unique | length)) and
  ([.shards[] | (.pureProfiles + .mutableProfiles)[].id] as $profiles |
    ($profiles | length) == ($profiles | unique | length))
' "$contract" >/dev/null || {
    echo "PR validation contract is invalid" >&2
    exit 2
}

selected_count=$(jq --arg shard "$shard_id" '[.shards[] | select(.id == $shard)] | length' "$contract")
[[ $selected_count == 1 ]] || {
    echo "unknown PR validation shard: $shard_id" >&2
    exit 2
}

mutable_run_path() {
    case "$1" in
        # @runnerCases@
        *) return 1 ;;
    esac
}

mutable_cleanup_path() {
    case "$1" in
        # @cleanupCases@
        *) return 1 ;;
    esac
}

mapfile -t mutable_ids < <(
    jq -r --arg shard "$shard_id" '.shards[] | select(.id == $shard) | .mutableProfiles[].id' "$contract"
)
for profile_id in "${mutable_ids[@]}"; do
    if ! mutable_run_path "$profile_id" >/dev/null || ! mutable_cleanup_path "$profile_id" >/dev/null; then
        echo "mutable profile is not embedded in the validator: $profile_id" >&2
        exit 2
    fi
done

root=${LUCIDITY_REPOSITORY_ROOT:-}
if [[ -z $root ]]; then
    root=$(git rev-parse --show-toplevel)
fi
root=$(realpath "$root")
[[ -f $root/flake.nix ]] || {
    echo "PR validation requires a flake repository root" >&2
    exit 2
}

clean_environment() {
    local -a environment
    local variable
    environment=(
        "HOME=${HOME:?HOME is required}"
        "LUCIDITY_REPOSITORY_ROOT=$root"
        "PATH=$PATH"
        "TMPDIR=${TMPDIR:-/tmp}"
    )
    for variable in CI GITHUB_ACTIONS GITHUB_STEP_SUMMARY NIX_CONFIG NIX_REMOTE \
        NIX_SSL_CERT_FILE SSL_CERT_FILE XDG_CACHE_HOME XDG_CONFIG_HOME XDG_RUNTIME_DIR; do
        [[ -z ${!variable:-} ]] || environment+=("$variable=${!variable}")
    done
    env -i "${environment[@]}" "$@"
}

results=${PR_VALIDATION_RESULTS:-$PWD/pr-validation-results.json}
results=$(realpath -m "$results")
mkdir -p "$(dirname "$results")"
jq -n --arg shard "$shard_id" '{schemaVersion:1,shard:$shard,results:[]}' >"$results"

record_result() {
    local profile_id=$1
    local kind=$2
    local outcome=$3
    local temporary
    temporary=$(mktemp "$(dirname "$results")/.pr-validation-results.XXXXXX")
    jq --arg id "$profile_id" --arg kind "$kind" --arg outcome "$outcome" \
        '.results += [{id:$id,kind:$kind,outcome:$outcome}]' "$results" >"$temporary"
    mv "$temporary" "$results"
}

failed=false
mapfile -t pure_rows < <(
    jq -r --arg shard "$shard_id" \
        '.shards[] | select(.id == $shard) | .pureProfiles[] | [.id, .attribute] | @tsv' "$contract"
)
if ((${#pure_rows[@]} > 0)); then
    installables=()
    for row in "${pure_rows[@]}"; do
        IFS=$'\t' read -r _ attribute <<<"$row"
        installables+=("$root#$attribute")
    done
    if clean_environment "$nix_command" build --no-link --keep-going --print-build-logs "${installables[@]}"; then
        for row in "${pure_rows[@]}"; do
            IFS=$'\t' read -r profile_id _ <<<"$row"
            record_result "$profile_id" pure success
        done
    else
        for row in "${pure_rows[@]}"; do
            IFS=$'\t' read -r profile_id attribute <<<"$row"
            if clean_environment "$nix_command" build --no-link --print-build-logs "$root#$attribute"; then
                record_result "$profile_id" pure success
            else
                record_result "$profile_id" pure failure
                failed=true
            fi
        done
    fi
fi

active_profile=""
cleanup_active_profile() {
    local cleanup_path
    [[ -n $active_profile ]] || return 0
    cleanup_path=$(mutable_cleanup_path "$active_profile") || return 0
    clean_environment "$cleanup_path" || true
    active_profile=""
}
handle_signal() {
    local status=$1
    cleanup_active_profile
    trap - EXIT INT TERM
    exit "$status"
}
trap cleanup_active_profile EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

for profile_id in "${mutable_ids[@]}"; do
    active_profile=$profile_id
    run_path=$(mutable_run_path "$profile_id")
    cleanup_path=$(mutable_cleanup_path "$profile_id")
    profile_outcome=success
    if ! clean_environment "$run_path"; then
        profile_outcome=failure
        failed=true
    fi
    if ! clean_environment "$cleanup_path"; then
        profile_outcome=cleanup-failure
        failed=true
    fi
    active_profile=""
    record_result "$profile_id" mutable "$profile_outcome"
done
trap - EXIT INT TERM

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
        printf '### PR validation shard \x60%s\x60\n\n' "$shard_id"
        printf '| Profile | Kind | Outcome |\n'
        printf '| --- | --- | --- |\n'
        jq -r '.results[] | "| `\(.id)` | \(.kind) | `\(.outcome)` |"' "$results"
    } >>"$GITHUB_STEP_SUMMARY"
fi

[[ $failed == false ]]
