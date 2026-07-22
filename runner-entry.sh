#!/bin/bash
# runner-entry.sh — runs INSIDE the gha-dind-runner container. Brings up an inner
# docker daemon, then runs the REAL GitHub Actions runner agent as an EPHEMERAL
# runner: register with a per-job registration token, run exactly ONE job,
# self-deregister, exit. The host loop (runner.sh) then mints a fresh token and
# relaunches — the per-job cycle.
#
# PRE-BUILT IMAGE: the base deps (docker.io, git, curl, build-essential,
# ca-certificates, libicu74) AND the extracted runner agent (/actions-runner) are
# baked into gha-dind-runner:latest by the Dockerfile (build-image.sh) — installed
# ONCE, not per launch. This script therefore does NO apt install and NO tarball
# unpack; it starts in seconds. Rebuild the image only when deps/runner-version
# change.
#
# TOOLCHAIN: a plain Ubuntu runner. Workflows use actions/setup-go +
# actions/setup-node exactly as they would on a hosted runner; the image bakes
# those toolchains into the runner TOOL-CACHE (see the Dockerfile) so setup-*
# finds them and skips the per-job download. A version the image did not bake is
# simply downloaded by the job, as on a hosted runner. Beyond that the image only
# provides BASE deps that checkout + service-container jobs need.
#
# BASE = Ubuntu (glibc). The runner agent is a glibc .NET app and GitHub ships no
# musl build, so glibc runs it natively (Alpine needed shims; Ubuntu needs none).
#
# Container contract (set by runner.sh via docker run):
#   /cache/*              (rw)  persistent Go/npm caches (survive job + reboot)
#   env RUNNER_URL           https://github.com/<owner>/<repo>
#   env RUNNER_TOKEN         a FRESH registration token (minted by runner.sh)
#   env RUNNER_NAME          unique runner name
#   env RUNNER_LABELS        comma labels (e.g. dind)
#   privileged + own /var/lib/docker (host named volume) → inner dockerd, overlay2
set -eu

log() { echo "== runner-entry: $*"; }
echo "================ DinD GH-ACTIONS RUNNER (ubuntu) ================"

# 1) Inner docker daemon. /var/lib/docker is a HOST NAMED VOLUME (runner.sh mounts
#    gha-runner-<slot>-docker there) — a real ext4 fs — so dockerd auto-selects
#    overlay2 (fast). Job steps that `docker run` (postgres) use THIS daemon.
#    The volume is PERSISTENT across this slot's sequential jobs (it caches pulled
#    images so postgres isn't re-pulled every job), so it also carries CONTAINERS
#    from the previous job. A GitHub-hosted runner gets a fresh VM per job and
#    never sees that; ours must reset it — see the container sweep below.
log "starting inner dockerd ..."
dockerd >/var/log/dockerd.log 2>&1 &
i=0
until docker info >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -le 30 ] || { echo "FATAL: inner dockerd did not start" >&2; tail -40 /var/log/dockerd.log >&2 || true; exit 1; }
  sleep 1
done
log "inner dockerd up ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'))"

# 1a) Clean slate for THIS job: remove any containers/networks/volumes left in the
#     inner dockerd by the previous job on this slot. Without this, a job that does
#     `docker run --name postgres -p 5432:5432` collides with the prior job's
#     leftover postgres ("container name /postgres already in use", exit 125) or
#     its still-published :5432. IMAGES are deliberately NOT pruned — they are the
#     cache this persistent volume exists to keep (postgres-ai stays pulled). This
#     is the runner giving each job the clean docker state a hosted VM gets for
#     free; it must NOT live in the workflow (ci.yml shouldn't clean up after us).
log "resetting inner docker state (containers/networks/volumes; images kept) ..."
docker ps -aq | xargs -r docker rm -f >/dev/null 2>&1 || true
docker network prune -f >/dev/null 2>&1 || true
docker volume prune -f >/dev/null 2>&1 || true

# 2) Persistent caches for the toolchain (survive container removal + host reboot —
#    they're host dirs, mounted by runner.sh). setup-go/setup-node + the jobs point
#    at these via the runner's .env file (step 4) so warm caches are reused.
mkdir -p /cache/go /cache/gomod /cache/gopath /cache/npm

# The runner agent refuses to run as root unless RUNNER_ALLOW_RUNASROOT=1. We are
# root in this throwaway per-job container, so set the escape hatch.
export RUNNER_ALLOW_RUNASROOT=1

# Point the runner at the baked tool-cache so actions/setup-go + setup-node find
# the pre-installed go/node (baked at $TOOLCACHE/{go,node}/<ver>/x64 in the image)
# and SKIP the per-job download. Must match the Dockerfile's TOOLCACHE.
export RUNNER_TOOL_CACHE=/opt/hostedtoolcache
export AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache

# The runner agent is already extracted to /actions-runner in the image (baked by
# the Dockerfile) — no per-launch tarball unpack.
cd /actions-runner

# 3) Register EPHEMERAL + run ONE job. --ephemeral => GitHub guarantees at-most-one
#    job on this registration; after it, the agent self-deregisters and run.sh exits.
#    --unattended + --replace so a stale same-name registration is taken over cleanly.
log "configuring ephemeral runner name=$RUNNER_NAME labels=$RUNNER_LABELS"
./config.sh \
  --url "$RUNNER_URL" \
  --token "$RUNNER_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS" \
  --ephemeral \
  --unattended \
  --replace \
  --work /work

# 4) Per-job env for every step via the runner's .env file (literal key=value):
#    - the tool-cache dir, so setup-go/setup-node find the baked go/node and skip
#      the download (belt-and-suspenders with the exports above);
#    - persistent Go/npm caches pointed at host dirs so warm caches are reused.
log "writing .env (tool-cache + persistent Go/npm caches) ..."
{
  echo "RUNNER_TOOL_CACHE=/opt/hostedtoolcache"
  echo "AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache"
  echo "GOCACHE=/cache/go"
  echo "GOMODCACHE=/cache/gomod"
  echo "GOPATH=/cache/gopath"
  echo "npm_config_cache=/cache/npm"
} > .env

log "running one job (run.sh) ..."
exec ./run.sh
