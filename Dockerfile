# gha-dind-runner — the pre-built image for the ephemeral GitHub Actions runner.
#
# WHY THIS EXISTS: the entry script used to `apt-get install docker.io git curl
# build-essential libicu74` on EVERY container launch — minutes of identical work
# per job, and a flapping-loop failure surface. That is a Dockerfile's job. We
# install the deps ONCE here; each job then launches from this image and starts in
# seconds. The runner agent tarball is baked in too (GitHub ships it only as a
# release .tar.gz — no apt package), so a job launch needs zero network install.
#
# Base = Ubuntu (glibc). The runner agent is a glibc .NET app and GitHub ships no
# musl build, so glibc runs it natively (Alpine needed shims; Ubuntu needs none).
#
# Rebuild this image (build-image.sh) only when the dep set or the pinned runner
# version changes — NOT per job.

# --- nix seed ---------------------------------------------------------------
# A complete, pinned Nix installation, carried in the image purely as a SEED for
# the persistent CI Nix store — a docker named volume mounted at /nix by
# runner.sh. Jobs never install Nix over the network: runner-entry.sh copies
# this into /nix the first time it finds that volume empty, and every job after
# that reuses the warm store.
#
# It is staged at /nix-seed, NOT /nix, on purpose — runner.sh mounts the volume
# OVER /nix, which would shadow anything the image put there.
#
# The version is pinned for reproducibility. This store is entirely separate
# from the host's /nix, which is never mounted into a runner.
ARG NIX_VERSION=2.34.8
FROM nixos/nix:${NIX_VERSION} AS nixseed

FROM ubuntu:24.04

# Base deps, installed once:
#   docker.io         inner dockerd (the postgres CI jobs' `docker run`)
#   git + curl        actions/checkout downloads
#   build-essential   gcc/make — the engine -race pass + any cgo build
#   ca-certificates   TLS for downloads
#   libicu74          .NET GLOBALIZATION dep — the runner agent (Runner.Listener)
#                     won't START without it. Its error misleadingly says
#                     "libstdc++.so.6 => not found"; the real missing dep is ICU.
#   jq                token/JSON handling if the entry script needs it
#   xz-utils          extract the go tarball (.tar.gz uses gzip, but keep xz for
#                     any xz-compressed toolchain artifacts)
RUN export DEBIAN_FRONTEND=noninteractive \
 && apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      docker.io git curl build-essential ca-certificates libicu74 jq xz-utils \
 && rm -rf /var/lib/apt/lists/*

# Bake go + node into the RUNNER TOOL-CACHE so actions/setup-go and
# actions/setup-node FIND them and SKIP the per-job download. This is the whole
# point: without it, setup-go re-fetches go from GitHub on EVERY job (proven in
# the job log: "Acquiring 1.25.12 from .../go-versions ... Extracting Go ... -C
# /work/_temp/...", into the ephemeral /work that dies with the container).
#
# The tool-cache layout is a hard contract: setup-* probe
#   $RUNNER_TOOL_CACHE/<tool>/<exact-version>/<arch>/   (+ a sibling .complete
# marker file). RUNNER_TOOL_CACHE defaults to /opt/hostedtoolcache; runner-entry.sh
# exports it explicitly so the job and this bake agree. Putting go on PATH alone
# does NOT help — setup-go only consults the tool-cache, not PATH. The DIRECTORY
# is named with the exact version, but the workflow's request need NOT be exact:
# setup-* resolves its version spec as a semver range over what is installed, so
# `go-version: '1.25'` matches this baked 1.25.12 (and `node-version: '22'`
# matches 22.12.0). Bake a version that satisfies what the workflow asks for.
#
# These defaults suit a Go + Node matrix. Pass an EMPTY value to skip a bake
# (build-image.sh forwards GO_VERSION / NODE_VERSION from config.env); the job
# then downloads that toolchain itself, exactly as on a GitHub-hosted runner.
# Swap in whatever toolchains your own matrix needs.
ARG GO_VERSION=1.25.12
ARG NODE_VERSION=22.12.0
ARG TOOLCACHE=/opt/hostedtoolcache
RUN set -eux; \
    # --- go → $TOOLCACHE/go/<ver>/x64 ---
    if [ -n "${GO_VERSION}" ]; then \
      curl -fL --retry 3 -o /tmp/go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"; \
      mkdir -p "${TOOLCACHE}/go/${GO_VERSION}/x64"; \
      tar -C "${TOOLCACHE}/go/${GO_VERSION}/x64" --strip-components=1 -xzf /tmp/go.tgz; \
      touch "${TOOLCACHE}/go/${GO_VERSION}/x64.complete"; \
      rm -f /tmp/go.tgz; \
    else echo "GO_VERSION empty — skipping the go tool-cache bake"; fi; \
    # --- node → $TOOLCACHE/node/<ver>/x64 ---
    if [ -n "${NODE_VERSION}" ]; then \
      curl -fL --retry 3 -o /tmp/node.txz \
        "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"; \
      mkdir -p "${TOOLCACHE}/node/${NODE_VERSION}/x64"; \
      tar -C "${TOOLCACHE}/node/${NODE_VERSION}/x64" --strip-components=1 -xJf /tmp/node.txz; \
      touch "${TOOLCACHE}/node/${NODE_VERSION}/x64.complete"; \
      rm -f /tmp/node.txz; \
    else echo "NODE_VERSION empty — skipping the node tool-cache bake"; fi

# Bake the pinned GitHub Actions runner agent into the image. build-image.sh
# downloads the tarball to ./dl first (it's the build context). Extracted to
# /actions-runner so runner-entry.sh never unpacks per launch.
ARG RUNNER_VERSION=2.335.1
COPY dl/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz /tmp/actions-runner.tar.gz
RUN mkdir -p /actions-runner \
 && tar xzf /tmp/actions-runner.tar.gz -C /actions-runner \
 && rm -f /tmp/actions-runner.tar.gz

# Stage the Nix installation for runner-entry.sh to seed the persistent /nix
# mount from. See the nixseed stage at the top for why this is NOT /nix.
COPY --from=nixseed /nix /nix-seed

# Nix config. This lives OUTSIDE /nix on purpose: /nix is bind-mounted per job,
# so anything written under it by the image is invisible at runtime, while
# /etc/nix is part of the image and always present.
#
#   experimental-features  `nix develop` (flakes) is the whole reason CI wants
#                          nix; without this every invocation errors out.
#   build-users-group=     empty => single-user mode, builds run as root. The
#                          image has no nixbld users and there is no daemon
#                          (see NIX_REMOTE below); leaving this at its default
#                          makes every build fail looking for the build group.
#   sandbox=false          matches the upstream nixos/nix image default. The
#                          job container is already an isolation boundary, and
#                          the sandbox's user-namespace requirements are a
#                          failure class we gain nothing from here.
#   keep-derivations       REQUIRED for the GC story to actually work. The
#   keep-outputs           `nix develop --profile` root protects the devShell's
#                          RUNTIME closure only — not the .drv files, and not
#                          the flake input sources (nixpkgs) that EVALUATION
#                          needs. Without these two, a GC deletes the nixpkgs
#                          source and the .drv; the next job then re-fetches
#                          nixpkgs and, if it cannot substitute, plans to build
#                          stdenv from the stage0 bootstrap. Measured: a GC left
#                          the store with "562 derivations will be built".
#                          keep-derivations makes a rooted output retain its
#                          derivation, which in turn retains its input sources.
RUN mkdir -p /etc/nix \
 && printf '%s\n' \
      'experimental-features = nix-command flakes' \
      'build-users-group =' \
      'sandbox = false' \
      'keep-derivations = true' \
      'keep-outputs = true' \
    > /etc/nix/nix.conf

# NIX_REMOTE empty => talk to the store DIRECTLY rather than through a daemon.
# There is no nix-daemon in this container, and a non-empty NIX_REMOTE is what
# produces "cannot connect to socket at /nix/var/nix/daemon-socket/socket".
# NIX_SSL_CERT_FILE points at Ubuntu's CA bundle so substituter TLS works.
ENV NIX_REMOTE="" \
    NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PATH=/nix/var/nix/profiles/default/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Entry script baked in (no per-launch bind-mount needed; runner.sh may still
# bind-mount a working copy to override during development).
COPY runner-entry.sh /usr/local/bin/runner-entry.sh
RUN chmod +x /usr/local/bin/runner-entry.sh
