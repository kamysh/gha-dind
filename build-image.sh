#!/usr/bin/env bash
# build-image.sh — build the pre-built runner image ONCE (gha-dind-runner:latest).
# Run this when the dep set (Dockerfile) or the pinned runner version changes —
# NOT per job. runner.sh launches job containers FROM this image, so a job starts
# in seconds instead of apt-installing every launch.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

# shellcheck source=lib.sh
. "$here/lib.sh"
load_config "$here/config.env"

IMAGE="${IMAGE:-gha-dind-runner:latest}"
RUNNER_VERSION="${RUNNER_VERSION:-2.335.1}"     # actions/runner release, pinned (matches Dockerfile ARG)
# Toolchains baked into the runner tool-cache. An EMPTY value skips that bake —
# jobs then download the toolchain themselves, as on a GitHub-hosted runner.
# Use the ${VAR-default} form (not ${VAR:-default}) so an explicit empty value in
# config.env means "skip", rather than silently falling back to the default.
GO_VERSION="${GO_VERSION-1.26.6}"
NODE_VERSION="${NODE_VERSION-22.12.0}"
# Nix installation seeded into the persistent CI store volume (see Dockerfile).
# Unlike go/node this one is NOT skippable — a job that needs `nix develop` has
# no other source of nix, so an empty value would just break that job.
NIX_VERSION="${NIX_VERSION:-2.34.8}"

RUNNER_TARBALL="dl/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

# 1) Fetch the pinned runner agent tarball (GitHub ships it only as a release
#    .tar.gz — no apt package). Downloaded once into the build context.
mkdir -p dl
if [ ! -f "$RUNNER_TARBALL" ]; then
  echo "-- downloading actions-runner ${RUNNER_VERSION} ..."
  curl -fL --connect-timeout 10 --max-time 300 \
    -o "$RUNNER_TARBALL" \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
    || { echo "FATAL: could not download the runner tarball" >&2; rm -f "$RUNNER_TARBALL"; exit 1; }
fi

# 2) Build. The context is this dir; .dockerignore keeps it tiny (only the
#    Dockerfile, the two entry scripts, and dl/<tarball> are needed).
echo "-- building $IMAGE (runner ${RUNNER_VERSION}, go '${GO_VERSION:-none}', node '${NODE_VERSION:-none}', nix ${NIX_VERSION}) ..."
docker build \
  --build-arg "RUNNER_VERSION=${RUNNER_VERSION}" \
  --build-arg "GO_VERSION=${GO_VERSION}" \
  --build-arg "NODE_VERSION=${NODE_VERSION}" \
  --build-arg "NIX_VERSION=${NIX_VERSION}" \
  -t "$IMAGE" \
  -f Dockerfile \
  .

echo "-- built $IMAGE"
docker image inspect "$IMAGE" --format '   id={{.Id}}  size={{.Size}} bytes' 2>/dev/null || true
echo "   runner.sh launches job containers FROM this image now."
