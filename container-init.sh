#!/bin/bash
# Shared container setup for GitHub-runner and local-command execution.
# This script is sourced inside a dedicated privileged DinD container.
init_container() {
  local strict_cleanup="${1:-warn}"
  export DOCKER_HOST=unix:///var/run/docker.sock
  unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH
  dockerd >/var/log/dockerd.log 2>&1 &
  local attempts=0
  until docker info >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 30 ]; then
      echo 'FATAL: inner dockerd did not start' >&2
      tail -n 40 /var/log/dockerd.log >&2
      return 1
    fi
    sleep 1
  done
  # Only this container's inner daemon is reachable. Keep cached images.
  docker ps -aq | xargs -r docker rm -f || {
    echo 'WARNING: inner container cleanup failed' >&2
    [ "$strict_cleanup" != strict ] || return 1
  }
  docker network prune -f || {
    echo 'WARNING: inner network cleanup failed' >&2
    [ "$strict_cleanup" != strict ] || return 1
  }
  docker volume prune -af || {
    echo 'WARNING: inner volume cleanup failed' >&2
    [ "$strict_cleanup" != strict ] || return 1
  }
  mkdir -p /cache/go /cache/gomod /cache/gopath /cache/npm
  exec 9>/nix/.gha-seed.lock
  flock 9
  if [ ! -d /nix/store ]; then cp -a /nix-seed/. /nix/; fi
  flock -u 9
  exec 9>&-
  export RUNNER_TOOL_CACHE=/opt/hostedtoolcache
  export AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache
  export GOCACHE=/cache/go GOMODCACHE=/cache/gomod GOPATH=/cache/gopath
  export npm_config_cache=/cache/npm
}
