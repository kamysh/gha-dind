#!/bin/bash
# Execute one local command in the same prepared environment as a CI runner.
# No GitHub registration, runner credentials, or workflow emulation.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/container-init.sh"
[ "$#" -gt 0 ] || { echo 'Usage: local-entry.sh COMMAND [ARG...]' >&2; exit 2; }
child=
finish_local() {
  local status=$?
  trap - EXIT INT TERM
  if [ -n "${LOCAL_OUTPUT_UID:-}" ] && [ -n "${LOCAL_OUTPUT_GID:-}" ]; then
    [[ "$LOCAL_OUTPUT_UID" =~ ^[0-9]+$ && "$LOCAL_OUTPUT_GID" =~ ^[0-9]+$ ]] || exit 1
    chown -R --no-dereference "$LOCAL_OUTPUT_UID:$LOCAL_OUTPUT_GID" /evidence || status=1
    if [ "${LOCAL_OWN_WORKSPACE:-false}" = true ]; then
      chown -R --no-dereference "$LOCAL_OUTPUT_UID:$LOCAL_OUTPUT_GID" /workspace || status=1
    fi
  fi
  exit "$status"
}
stop_local() {
  local status="$1"
  if [ -n "$child" ]; then kill -TERM -- "-$child" 2>/dev/null || true; wait "$child" || true; fi
  exit "$status"
}
trap finish_local EXIT
trap 'stop_local 130' INT
trap 'stop_local 143' TERM
init_container strict

tool_path() {
  local tool="$1" version="$2" candidates=()
  if [ -n "$version" ]; then
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid $tool version" >&2; return 1; }
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
go_path="$(tool_path go "${LOCAL_GO_VERSION:-}")"
node_path="$(tool_path node "${LOCAL_NODE_VERSION:-}")"
export PATH="$go_path:$node_path:$PATH"
export CI=true
cd /workspace
setsid "$@" &
child=$!
wait "$child"
