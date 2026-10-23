#!/usr/bin/env bash
# Framework-owned scheduled local DinD jobs. No host service/timer is needed.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"
load_config "$here/config.env"
mode="${1:-}"; [ "$#" -gt 0 ] && shift
name= config= env_file= output= date=
usage() { echo 'Usage: scheduled.sh up|status|down|export --name NAME [--config FILE --env-file FILE] [--date YYYY-MM-DD --output NEW_DIR]' >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --name) name="$2";; --config) config="$2";; --env-file) env_file="$2";; --output) output="$2";; --date) date="$2";; *) usage;;
  esac
  shift 2
done
[[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || usage
container="gha-scheduled-$name"
state="gha-scheduled-$name-state"
volume="gha-scheduled-$name-docker"
owned() {
  [ "$(docker inspect --format '{{ index .Config.Labels "gha-dind.scheduled" }}' "$container")" = "$name" ] || {
    echo 'Refusing to modify a container not owned by this scheduled job' >&2; exit 1;
  }
}
case "$mode" in
  up)
    [[ "$config" = /* && -f "$config" && "$env_file" = /* && -r "$env_file" ]] || usage
    [[ "$(stat -c %u "$env_file")" = "$(id -u)" ]] || { echo 'Credential file must belong to this user' >&2; exit 1; }
    permissions=$(stat -c %a "$env_file")
    (( (8#$permissions & 077) == 0 )) || { echo 'Credential file must not be accessible to group/other' >&2; exit 1; }
    # Validate without reading or echoing credential values.
    jq -e --arg name "$name" '.version == 1 and .name == $name' "$config" >/dev/null
    if docker container inspect "$container" >/dev/null 2>&1; then echo 'Scheduled container already exists; refusing replacement' >&2; exit 1; fi
    image="${DIND_IMAGE:-gha-dind-runner:latest}"
    network="${DIND_NET:-gha-dind-net}"
    nix_volume="${NIX_VOLUME:-gha-dind-nix}"
    cache="${CACHE_DIR:-$here/cache}"
    docker image inspect "$image" >/dev/null
    docker network inspect "$network" >/dev/null
    docker volume inspect "$nix_volume" >/dev/null
    mkdir -p "$cache"/{go,gomod,gopath,npm,buildkit,dhall,agda}
    for v in "$state" "$volume"; do docker volume create "$v" >/dev/null; done
    args=(--name "$container" --label "gha-dind.scheduled=$name" --privileged --init --restart unless-stopped --network "$network"
      --mount "type=volume,src=$state,dst=/scheduled" --mount "type=volume,src=$volume,dst=/var/lib/docker"
      --mount "type=volume,src=$nix_volume,dst=/nix" --env-file "$env_file"
      --health-cmd '/bin/bash /usr/local/bin/scheduled-entry.sh health' --health-interval 10s --health-timeout 5s --health-retries 6 --health-start-period 60s)
    for kind in go gomod gopath npm buildkit dhall agda; do args+=(--mount "type=bind,src=$cache/$kind,dst=/cache/$kind"); done
    id="$(docker create "${args[@]}" --entrypoint /bin/bash "$image" /usr/local/bin/scheduled-entry.sh run)"
    rollback() { local status=$?; trap - EXIT; if [ "$status" != 0 ]; then docker rm -f "$id" || true; fi; exit "$status"; }
    trap rollback EXIT
    # Configuration is copied into the owned state volume; no host config or
    # credential file is needed for container restart or machine reboot.
    docker cp "$config" "$id:/scheduled/job.json"
    docker start "$id" >/dev/null
    trap - EXIT
    echo "Started $container; retained state: $state"
    ;;
  status) owned; docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container"; docker exec "$container" /bin/bash /usr/local/bin/scheduled-entry.sh status;;
  down) owned; docker stop --time 30 "$container" >/dev/null; docker rm "$container" >/dev/null; echo 'Stopped owned scheduler; evidence volumes retained';;
  export)
    owned; [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$output" = /* ]] || usage
    mkdir -m 700 "$output"; docker cp "$container:/scheduled/runs/$date/." "$output";;
  *) usage;;
esac
