#!/usr/bin/env bash
# Real Docker verification. Uses dedicated local containers and mock runner
# registration; never registers with GitHub or manipulates pool slots.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output="${1:?usage: smoke-local.sh NEW_ABSOLUTE_OUTPUT}"
[[ "$output" = /* ]] || exit 2
mkdir -m 700 "$output"
mkdir "$output/workspace"
prefix="smoke-$$"
image="${DIND_IMAGE:-gha-dind-runner:latest}"
network="${DIND_NET:-gha-dind-net}"
nix_volume="${NIX_VOLUME:-gha-dind-nix}"
export CACHE_DIR="${CACHE_DIR:-$output/cache}"
default_id= default_volume= log_pid=
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [ -n "$default_id" ]; then
    docker stop --time 10 "$default_id" >>"$output/default-lifecycle.log" 2>&1 || true
    docker rm "$default_id" >>"$output/default-lifecycle.log" 2>&1 || status=1
  fi
  if [ -n "$log_pid" ]; then wait "$log_pid" || status=1; fi
  if [ -n "$default_volume" ]; then docker volume rm "$default_volume" >>"$output/default-lifecycle.log" 2>&1 || status=1; fi
  printf '%s\n' "$status" > "$output/exit-status"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
bash "$here/local.sh" --name "$prefix-success" --workspace "$output/workspace" \
  --own-workspace --output "$output/success" --timeout-seconds 120 -- \
  bash -c 'set -euo pipefail; test "$CI" = true; test -z "${RUNNER_TOKEN:-}";
    go version; node --version; docker info --format "{{.ServerVersion}}";
    printf retained > /evidence/owned-output; printf retained > /workspace/owned-build-output'
test "$(cat "$output/success/owned-output")" = retained
test "$(stat -c %u "$output/success/owned-output")" = "$(id -u)"
test "$(stat -c %u "$output/workspace/owned-build-output")" = "$(id -u)"
for mode in failure timeout; do
  limit=120
  command=(bash -c 'exit 17')
  expected=17
  if [ "$mode" = timeout ]; then limit=3; command=(sleep 60); expected=124; fi
  set +e
  bash "$here/local.sh" --name "$prefix-$mode" --workspace "$output/workspace" \
    --own-workspace --output "$output/$mode" --timeout-seconds "$limit" -- "${command[@]}"
  status=$?
  set -e
  test "$status" = "$expected"
  test "$(cat "$output/$mode/exit-status")" = "$expected"
done

# Exercise the default entrypoint with harmless fixture implementations of
# config.sh/run.sh. Shared initialization is real, registration is not.
mkdir "$output/default"
cat > "$output/default/config.sh" <<'CONFIG'
#!/bin/bash
printf '%s\n' "$@" > /evidence/registration-args
CONFIG
cat > "$output/default/run.sh" <<'RUN'
#!/bin/bash
test "$RUNNER_ALLOW_RUNASROOT" = 1
test "$RUNNER_TOOL_CACHE" = /opt/hostedtoolcache
test -f .env
printf 'default runner command executed\n'
exit 23
RUN
chmod +x "$output/default/config.sh" "$output/default/run.sh"
volume="gha-local-$prefix-default-docker"
if docker volume inspect "$volume" >/dev/null 2>&1; then echo 'Smoke volume already exists' >&2; exit 1; fi
docker volume create "$volume" >"$output/default-lifecycle.log" 2>&1
default_volume="$volume"
default_id="$(docker create --name "gha-local-$prefix-default" --privileged --network "$network" \
  --env RUNNER_URL=https://example.invalid/fixture --env RUNNER_TOKEN=fixture-only \
  --env RUNNER_NAME=fixture-runner --env RUNNER_LABELS=fixture \
  --mount "type=volume,src=$volume,dst=/var/lib/docker" \
  --mount "type=volume,src=$nix_volume,dst=/nix" \
  --mount "type=bind,src=$output/default,dst=/evidence" \
  --mount "type=bind,src=$output/default/config.sh,dst=/actions-runner/config.sh,readonly" \
  --mount "type=bind,src=$output/default/run.sh,dst=/actions-runner/run.sh,readonly" \
  --entrypoint /bin/bash "$image" /usr/local/bin/runner-entry.sh 2>>"$output/default-lifecycle.log")"
docker start "$default_id" >>"$output/default-lifecycle.log" 2>&1
docker logs --follow "$default_id" >"$output/default/container.log" 2>&1 &
log_pid=$!
timeout --foreground 120s docker wait "$default_id" >"$output/default/container-exit-status"
test "$(cat "$output/default/container-exit-status")" = 23
args=$'\n'"$(cat "$output/default/registration-args")"$'\n'
[[ "$args" = *$'\n--ephemeral\n'* && "$args" = *$'\n--unattended\n'* ]]
for mode in success failure timeout; do
  if docker container inspect "gha-local-$prefix-$mode" >/dev/null 2>&1 || docker volume inspect "gha-local-$prefix-$mode-docker" >/dev/null 2>&1; then
    echo "Local resources leaked: $mode" >&2
    exit 1
  fi
done
echo 'Real local success, failure, timeout, ownership, cleanup and default-entry checks passed.'
