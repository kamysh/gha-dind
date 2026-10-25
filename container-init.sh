#!/bin/bash
# Shared container setup for GitHub-runner and local-command execution.
# This script is sourced inside a dedicated privileged DinD container.
init_container() {
  local strict_cleanup="${1:-warn}"
  export DOCKER_HOST=unix:///var/run/docker.sock
  unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH
  # Docker restart preserves the writable layer, including a stale PID file.
  # Never remove it underneath an already responsive inner daemon.
  if docker info >/dev/null 2>&1; then
    echo 'FATAL: inner daemon already running before initialization' >&2
    return 1
  fi
  rm -f /var/run/docker.pid /var/run/docker.sock
  dockerd >>/var/log/dockerd.log 2>&1 &
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
  cleanup_inner_docker "$strict_cleanup"
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

cleanup_inner_docker() {
  local strict_cleanup="${1:-warn}"
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
}

tool_path() {
  local tool="$1" version="$2" candidates=()
  if [ -n "$version" ]; then
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    candidates=("/opt/hostedtoolcache/$tool/$version/x64")
  else
    shopt -s nullglob
    candidates=(/opt/hostedtoolcache/"$tool"/*/x64)
    shopt -u nullglob
  fi
  [ "${#candidates[@]}" -eq 1 ] && [ -x "${candidates[0]}/bin/$tool" ] || {
    echo "Exactly one installed $tool is required; select LOCAL_${tool^^}_VERSION if needed" >&2
    return 1
  }
  printf '%s/bin' "${candidates[0]}"
}
init_toolchains() {
  local go_path node_path
  go_path="$(tool_path go "${LOCAL_GO_VERSION:-}")"
  node_path="$(tool_path node "${LOCAL_NODE_VERSION:-}")"
  export PATH="$go_path:$node_path:$PATH"
}
