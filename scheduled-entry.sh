#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/container-init.sh"
init_toolchains
mode="${1:-run}"
if [ "$mode" = run ]; then
  umask 077
  mkdir -p /scheduled
  chmod 700 /scheduled
  init_container strict
  exec flock -n /scheduled/controller.lock node /usr/local/lib/gha-dind/scheduled.mjs run
fi
exec node /usr/local/lib/gha-dind/scheduled.mjs "$mode"
