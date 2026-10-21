#!/usr/bin/env bash
# Maintained local/CI/publication checks. Retain complete output for every phase.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
mode=all output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --contracts) mode=contracts; shift;;
    --container) mode=container; shift;;
    --output) output="${2:?--output needs a new absolute directory}"; shift 2;;
    *) echo 'Usage: check.sh [--contracts|--container] [--output NEW_ABSOLUTE_DIR]' >&2; exit 2;;
  esac
done
if [ -z "$output" ]; then output="$(mktemp -d "${TMPDIR:-/tmp}/gha-dind-check-XXXXXXXX")";
else [[ "$output" = /* ]] && mkdir -m 700 "$output"; fi
echo "Full check evidence: $output"
run_check() {
  local name="$1" status
  shift
  set +e
  "$@" >"$output/$name.log" 2>&1
  status=$?
  set -e
  printf '%s\n' "$status" > "$output/$name.status"
  tail -n 40 "$output/$name.log"
  return "$status"
}
if [ "$mode" != container ]; then
  run_check syntax bash -n local.sh local-entry.sh container-init.sh runner-entry.sh smoke-local.sh check.sh
  run_check contracts timeout --foreground 30s node --test --test-reporter=tap local.test.mjs
  node -e 'const fs=require("node:fs"),assert=require("node:assert/strict"),tap=fs.readFileSync(process.argv[1],"utf8");assert(Number(/^# tests (\d+)$/m.exec(tap)?.[1])>=3);for(const key of ["fail","skipped","cancelled"])assert(new RegExp("^# "+key+" 0$","m").test(tap));assert(!/^# Subtest: .*local[.]test[.]mjs$/m.test(tap));' "$output/contracts.log"
fi
if [ "$mode" != contracts ]; then
  export IMAGE="gha-dind-check:$(git rev-parse --short HEAD)-$$"
  export DIND_IMAGE="$IMAGE" GO_VERSION="${GO_VERSION:-1.26.6}" NODE_VERSION="${NODE_VERSION:-22.23.1}"
  export CACHE_DIR="$output/cache"
  run_check image timeout --foreground --signal=TERM --kill-after=10s 900s bash build-image.sh
  run_check smoke timeout --foreground --signal=TERM --kill-after=10s 180s bash smoke-local.sh "$output/smoke"
  docker image inspect "$IMAGE" >"$output/image.json"
fi
printf 'passed\n' > "$output/result"
echo 'Selected maintained gha-dind checks passed.'
