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
#   /nix                  (rw)  persistent CI Nix store — a DOCKER NAMED VOLUME
#                               shared by all slots, seeded from the image's
#                               /nix-seed when empty. Not the host's /nix.
#   env RUNNER_URL           https://github.com/<owner>/<repo>
#   env RUNNER_TOKEN         a FRESH registration token (minted by runner.sh)
#   env RUNNER_NAME          unique runner name
#   env RUNNER_LABELS        comma labels (e.g. dind)
#   privileged + own /var/lib/docker (host named volume) → inner dockerd, overlay2
set -eu

log() { echo "== runner-entry: $*"; }
echo "================ DinD GH-ACTIONS RUNNER (ubuntu) ================"

# Shared initialization also serves local-command containers.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/container-init.sh"
init_container

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
  # Nix, from the persistent /nix mount. PATH must carry the default profile so
  # `nix` and `nix develop` are on it with no install step in the workflow.
  # NIX_REMOTE stays EMPTY (direct store access; there is no daemon here) —
  # a set value is what yields "cannot connect to socket at
  # /nix/var/nix/daemon-socket/socket".
  echo "PATH=/nix/var/nix/profiles/default/bin:${PATH}"
  echo "NIX_REMOTE="
  echo "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
} > .env

log "running one job (run.sh) ..."
exec ./run.sh
