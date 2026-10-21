#!/usr/bin/env bash
# Run one bounded command in a dedicated local DinD container.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"
load_config "$here/config.env"
name= workspace= output= seconds= env_file= own_workspace=false
usage() { echo 'Usage: local.sh --name NAME --workspace DIR --output NEW_DIR --timeout-seconds N [--env-file FILE] [--own-workspace] -- COMMAND [ARG...]' >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --own-workspace) own_workspace=true; shift;;
    --name|--workspace|--output|--timeout-seconds|--env-file)
      [ "$#" -ge 2 ] || usage
      case "$1" in
        --name) name="$2";; --workspace) workspace="$2";; --output) output="$2";;
        --timeout-seconds) seconds="$2";; --env-file) env_file="$2";;
      esac
      shift 2;;
    --) shift; break;;
    *) usage;;
  esac
done
[[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || usage
[[ "$seconds" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$workspace" = /* && -d "$workspace" && "$output" = /* && "$#" -gt 0 ]] || usage
[ -z "$env_file" ] || [[ "$env_file" = /* && -r "$env_file" ]] || usage
workspace="$(realpath "$workspace")"
output="$(realpath -m "$output")"
# Evidence is separate from the mounted source and must be new.
[[ "$output/" != "$workspace/"* ]] || { echo 'Output must be outside workspace' >&2; exit 2; }
mkdir -m 700 "$output"
image="${DIND_IMAGE:-gha-dind-runner:latest}"
network="${DIND_NET:-gha-dind-net}"
cache="${CACHE_DIR:-$here/cache}"
nix_volume="${NIX_VOLUME:-gha-dind-nix}"
container="gha-local-$name"
volume="gha-local-$name-docker"
container_id= volume_created=false log_pid=
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [ -n "$container_id" ]; then
    docker stop --time 10 "$container_id" >>"$output/lifecycle.log" 2>&1 || true
    docker rm "$container_id" >>"$output/lifecycle.log" 2>&1 || status=1
  fi
  if [ -n "$log_pid" ]; then wait "$log_pid" || status=1; fi
  if "$volume_created"; then docker volume rm "$volume" >>"$output/lifecycle.log" 2>&1 || status=1; fi
  printf '%s\n' "$status" > "$output/exit-status"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
docker image inspect "$image" >"$output/image.json" 2>"$output/lifecycle.log"
docker network inspect "$network" >"$output/network.json" 2>>"$output/lifecycle.log"
docker volume inspect "$nix_volume" >"$output/nix-volume.json" 2>>"$output/lifecycle.log"
if docker container inspect "$container" >/dev/null 2>&1 || docker volume inspect "$volume" >/dev/null 2>&1; then
  echo "Local name already exists: $name; refusing to replace it" >&2
  exit 1
fi
mkdir -p "$cache"/{go,gomod,gopath,npm,buildkit,dhall,agda}
mkdir -p "$cache/local-locks"
exec 8>"$cache/local-locks/$name.lock"
flock -n 8 || { echo "Local name is already running: $name" >&2; exit 1; }
# Recheck after taking the host-side name lock.
if docker container inspect "$container" >/dev/null 2>&1 || docker volume inspect "$volume" >/dev/null 2>&1; then
  echo "Local name already exists: $name; refusing to replace it" >&2
  exit 1
fi
docker volume create "$volume" >>"$output/lifecycle.log" 2>&1
volume_created=true
args=(--name "$container" --privileged --network "$network"
  --mount "type=volume,src=$volume,dst=/var/lib/docker"
  --mount "type=volume,src=$nix_volume,dst=/nix"
  --mount "type=bind,src=$workspace,dst=/workspace"
  --mount "type=bind,src=$output,dst=/evidence")
for kind in go gomod gopath npm buildkit dhall agda; do
  args+=(--mount "type=bind,src=$cache/$kind,dst=/cache/$kind")
done
if [ -n "$env_file" ]; then args+=(--env-file "$env_file"); fi
args+=(--env CI=true --env LOCAL_GO_VERSION --env LOCAL_NODE_VERSION
  --env "LOCAL_OWN_WORKSPACE=$own_workspace"
  --env "LOCAL_OUTPUT_UID=$(id -u)" --env "LOCAL_OUTPUT_GID=$(id -g)")
container_id="$(docker create "${args[@]}" --entrypoint /bin/bash "$image" /usr/local/bin/local-entry.sh "$@" 2>>"$output/lifecycle.log")"
printf '%s\n' "$container_id" > "$output/container-id"
docker start "$container_id" >>"$output/lifecycle.log" 2>&1
docker logs --follow "$container_id" >"$output/container.log" 2>&1 &
log_pid=$!
timeout --foreground --signal=TERM --kill-after=10s "${seconds}s" docker wait "$container_id" >"$output/container-exit-status" 2>>"$output/lifecycle.log"
status="$(cat "$output/container-exit-status")"
[[ "$status" =~ ^[0-9]+$ ]] || { echo 'Missing container exit status' >&2; exit 1; }
exit "$status"
