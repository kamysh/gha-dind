#!/usr/bin/env bash
# Exercise real scheduler startup, health, persistence and restart without a campaign.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output="${1:?new absolute evidence directory required}"
[[ "$output" = /* ]] || exit 2
mkdir -m 700 "$output"
name="smoke-scheduled-$$"; container="gha-scheduled-$name"; created=
cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$created" ]; then
    docker logs "$container" >"$output/container.log" 2>&1 || status=1
    bash "$here/scheduled.sh" down --name "$name" >>"$output/lifecycle.log" 2>&1 || status=1
    docker volume rm "gha-scheduled-$name-state" "gha-scheduled-$name-docker" >>"$output/lifecycle.log" 2>&1 || status=1
  fi
  printf '%s\n' "$status" >"$output/exit-status"
  exit "$status"
}
trap cleanup EXIT
jq --arg name "$name" '.name=$name | .startDate="2099-01-01"' "$here/scheduled.example.json" >"$output/job.json"
printf 'GH_TOKEN=fixture-only\n' >"$output/private.env"
chmod 600 "$output/private.env"
bash "$here/scheduled.sh" up --name "$name" --config "$output/job.json" --env-file "$output/private.env" >"$output/lifecycle.log" 2>&1
created=yes
wait_ready() {
  for attempt in $(seq 1 90); do
    if docker exec "$container" bash /usr/local/bin/scheduled-entry.sh health >>"$output/health.log" 2>&1; then return; fi
    sleep 1
  done
  return 1
}
wait_ready
docker inspect "$container" >"$output/inspect.json"
jq -e '.[0].HostConfig.RestartPolicy.Name=="unless-stopped" and ([.[0].Mounts[] | select(.Destination=="/nix") | .Type]==["volume"]) and ([.[0].Mounts[] | select(.Destination=="/var/run/docker.sock")]|length==0)' "$output/inspect.json" >/dev/null
bash "$here/scheduled.sh" status --name "$name" >"$output/status-before.log" 2>&1
docker exec "$container" bash -c 'printf durable > /scheduled/restart-proof; test "$(docker info --format "{{.ServerVersion}}")" != ""'
docker restart --time 15 "$container" >>"$output/lifecycle.log" 2>&1
# Do not accept the pre-restart heartbeat as readiness.
docker exec "$container" rm -f /scheduled/heartbeat.json
wait_ready
test "$(docker exec "$container" cat /scheduled/restart-proof)" = durable
bash "$here/scheduled.sh" status --name "$name" >"$output/status-after.log" 2>&1
if docker exec "$container" test -d /scheduled/runs/2099-01-01; then echo 'Future campaign unexpectedly launched' >&2; exit 1; fi
echo 'Real scheduler startup, DinD, persistence, restart and owned cleanup passed.'
