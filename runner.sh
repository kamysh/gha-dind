#!/usr/bin/env bash
# runner.sh — one host-side EPHEMERAL runner slot. Loops forever: mint a FRESH
# per-job registration token from the fine-grained PAT, launch a DinD runner
# container that registers + runs exactly ONE job + self-deregisters + exits,
# then repeat. This is the per-job-registration cycle for one "slot"; run N of
# these (via pool.sh) for real matrix parallelism.
#
# Usage: ./runner.sh <slot-index>
#   slot-index — 0,1,2,… ; drives the runner name (gha-dind-<host>-<i>).
#
# Prerequisites (host):
#   - config.env      : at minimum REPO=<owner>/<repo> (see config.env.example).
#   - secrets/gh-pat  : a fine-grained PAT with repo Administration: read/write on
#                       that repo (used ONLY to mint registration tokens).
#   - the runner bridge trusted in the host firewall (see README).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

# shellcheck source=lib.sh
. "$here/lib.sh"
load_config "$here/config.env"

SLOT="${1:?usage: runner.sh <slot-index>}"

# --- config (config.env, overridable by env) ---
require_var REPO "the repository to serve, as <owner>/<repo>"
RUNNER_URL="https://github.com/${REPO}"
RUNNER_LABELS="${RUNNER_LABELS:-dind}"
DIND_IMAGE="${DIND_IMAGE:-gha-dind-runner:latest}"   # PRE-BUILT by build-image.sh (deps + runner baked in)
DIND_NET="gha-dind-net"
DIND_BRIDGE="br-gha-dind"
NIX_VOLUME="${NIX_VOLUME:-gha-dind-nix}"   # shared CI Nix store (docker volume)
PAT_FILE="${PAT_FILE:-$here/secrets/gh-pat}"
CACHE_DIR="$here/cache"
RUNNER_NAME="gha-dind-$(hostname -s)-${SLOT}"
# Seconds `docker stop` gives the container to shut down before SIGKILL. Must be
# comfortably under the supervisor's stop timeout (systemd TimeoutStopSec=120);
# slots stop in parallel, so this is per-slot wall-clock, not cumulative.
STOP_GRACE="${STOP_GRACE:-25}"

log() { echo "[runner ${SLOT}] $*"; }

# --- preflight ---
command -v curl >/dev/null || { echo "FATAL: curl not found" >&2; exit 1; }
command -v jq   >/dev/null || { echo "FATAL: jq not found"   >&2; exit 1; }
[ -r "$PAT_FILE" ] || { echo "FATAL: PAT file $PAT_FILE missing (fine-grained PAT, repo Administration:rw)" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "FATAL: host docker not reachable" >&2; exit 1; }
# The pre-built image must exist — build it once with ./build-image.sh. Fail fast
# with a clear message rather than falling back to a bare ubuntu that would
# apt-install per launch (the old flapping bug).
docker image inspect "$DIND_IMAGE" >/dev/null 2>&1 \
  || { echo "FATAL: image $DIND_IMAGE not found — run ./build-image.sh first" >&2; exit 1; }
PAT="$(tr -d '\r\n' < "$PAT_FILE")"

# --- one-time host setup (idempotent): trusted network + cache dirs ---
mkdir -p "$CACHE_DIR"/{go,gomod,gopath,npm,buildkit,dhall}

# The CI Nix store lives in a DOCKER NAMED VOLUME, not on the host filesystem.
# docker owns its storage, the host's own /nix is never involved, and the volume
# outlives the --rm job containers — which is the whole point: the devShell
# closure is fetched once and every later job reuses it.
# ONE volume shared by all slots (not per-slot) so that fetch happens once for
# the pool rather than once per slot.
docker volume inspect "$NIX_VOLUME" >/dev/null 2>&1 || docker volume create "$NIX_VOLUME" >/dev/null

if ! docker network inspect "$DIND_NET" >/dev/null 2>&1; then
  docker network create --opt com.docker.network.bridge.name="$DIND_BRIDGE" "$DIND_NET" >/dev/null
fi
# NOTE: $DIND_BRIDGE must be a trusted interface in the host firewall or
# DNS-dependent CI jobs fail — see README. This is a one-time host config, not
# something the runner probes at launch.

# mint_reg_token: exchange the PAT for a FRESH single-use registration token.
# Registration tokens are single-use and expire in ~1h, so one is minted PER JOB
# right before each container launch.
mint_reg_token() {
  curl -fsS --connect-timeout 10 --max-time 30 -X POST \
    -H "Authorization: Bearer ${PAT}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${REPO}/actions/runners/registration-token" \
  | jq -r '.token'
}

log "starting ephemeral loop: repo=${REPO} name=${RUNNER_NAME} labels=${RUNNER_LABELS}"
CONTAINER="gha-runner-${SLOT}"
RUN_PID=""

# force_remove: drop a stale same-name container before (re)launch. Immediate —
# there is nothing to shut down gracefully in a leftover from a previous boot.
force_remove() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }

# stop_container: GRACEFUL stop, used on shutdown. `docker stop` sends SIGTERM to
# the container's PID 1 and waits, which gives the Actions agent the chance to end
# its session and DEREGISTER from GitHub. `docker rm -f` (SIGKILL) does not: a
# killed agent leaves a session GitHub still believes is live, and the next runner
# registering under the same name collides with it —
#   "A session for this runner already exists" / "Error: Conflict. Retrying..."
# — which strands that slot for minutes after every restart.
stop_container() {
  docker stop -t "$STOP_GRACE" "$CONTAINER" >/dev/null 2>&1 || true
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}

on_signal() {
  echo
  log "stopping — shutting the runner container down cleanly"
  stop_container
  if [ -n "$RUN_PID" ]; then wait "$RUN_PID" 2>/dev/null || true; fi
  exit 0
}
trap on_signal INT TERM

while true; do
  REG_TOKEN="$(mint_reg_token)"
  if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" = "null" ]; then
    echo "ERROR: failed to mint a registration token (check PAT scope). Retrying in 30s." >&2
    sleep 30; continue
  fi

  force_remove   # remove any stale same-name container before (re)launch
  log "launching runner container for one job ..."
  # Launch FROM the pre-built gha-dind-runner image (deps + runner agent baked in
  # by build-image.sh) — starts in seconds, no apt per launch. --rm so the
  # ephemeral container is gone after the job; own /var/lib/docker named volume per
  # slot for the inner dockerd; trusted DIND_NET so job DNS works.
  #
  # Run it in the BACKGROUND and `wait` on it. A FOREGROUND `docker run` makes
  # bash defer the INT/TERM trap until the child exits — and an idle runner
  # container waiting for a job never exits on its own. That is why shutdown used
  # to hang: no slot ran its trap, systemd waited out TimeoutStopSec, SIGKILLed
  # the lot, and every agent died still registered. Backgrounding + wait lets the
  # trap fire the moment the signal arrives.
  #
  # /nix is a DOCKER NAMED VOLUME ($NIX_VOLUME), the same mechanism the inner
  # dockerd's /var/lib/docker uses above — docker-owned storage that survives
  # the --rm container, with the host's own /nix left entirely alone. Without
  # it every nix-using job re-downloaded the installer AND the whole devShell
  # closure into a container destroyed at job end — a large recurring download
  # on the 10s-timeout installer path, which is what intermittently failed CI
  # (ETIMEDOUT fetching the nix installer). runner-entry.sh seeds the volume
  # from the image's /nix-seed when it is empty, so a nix-using job needs ZERO
  # network for nix on a warm store and only the substituter fetch on a cold one.
  docker run --rm --name "$CONTAINER" \
    --privileged \
    --network "$DIND_NET" \
    -e RUNNER_URL="$RUNNER_URL" \
    -e RUNNER_TOKEN="$REG_TOKEN" \
    -e RUNNER_NAME="$RUNNER_NAME" \
    -e RUNNER_LABELS="$RUNNER_LABELS" \
    -v "gha-runner-${SLOT}-docker:/var/lib/docker" \
    -v "$CACHE_DIR/go:/cache/go" \
    -v "$CACHE_DIR/gomod:/cache/gomod" \
    -v "$CACHE_DIR/gopath:/cache/gopath" \
    -v "$CACHE_DIR/npm:/cache/npm" \
    -v "$CACHE_DIR/buildkit:/cache/buildkit" \
    -v "$CACHE_DIR/dhall:/cache/dhall" \
    -v "$NIX_VOLUME:/nix" \
    --entrypoint /bin/bash \
    "$DIND_IMAGE" /usr/local/bin/runner-entry.sh &
  RUN_PID=$!
  wait "$RUN_PID" || log "runner container exited non-zero (job failed or was cancelled) — relaunching"
  RUN_PID=""

  # Ephemeral: the agent deregistered itself and exited. Brief pause, then loop
  # mints a fresh token and re-registers for the next job.
  sleep 2
done
