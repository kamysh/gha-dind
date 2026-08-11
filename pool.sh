#!/usr/bin/env bash
# pool.sh — start a POOL of N ephemeral DinD runner slots for real matrix
# parallelism. Each slot is an independent runner.sh loop (own inner dockerd, own
# /var/lib/docker volume, own container), so a job step like `docker run --name
# postgres -p 5432` cannot collide across concurrent jobs — the same isolation
# GitHub gives via one-VM-per-job, at container weight.
#
# Usage: ./pool.sh [N]
#   N — slot count. Defaults to POOL_SIZE from config.env, else 4.
#
# Runs the N loops in the foreground under one process group; Ctrl-C stops all of
# them cleanly (each runner.sh traps SIGTERM and removes its container). For a
# boot-persistent fleet see systemd/gha-dind-pool.service.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

# shellcheck source=lib.sh
. "$here/lib.sh"
load_config "$here/config.env"

N="${1:-${POOL_SIZE:-4}}"
case "$N" in (*[!0-9]*|'') echo "usage: pool.sh <N>  (positive integer)" >&2; exit 1;; esac
[ "$N" -ge 1 ] || { echo "N must be >= 1" >&2; exit 1; }

echo "== gha-dind pool: starting $N ephemeral runner slots =="

pids=()
stop_all() {
  echo; echo "-- stopping pool ($N slots) ..."
  for pid in "${pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  echo "-- pool stopped"
}
trap stop_all INT TERM

for i in $(seq 0 $((N - 1))); do
  # Invoke runner.sh through the SAME bash running this script ($BASH), not via
  # ./runner.sh — the latter relies on runner.sh's #!/usr/bin/env bash shebang,
  # which fails under a minimal systemd environment (no /usr/bin/env to exec).
  "${BASH:-bash}" "$here/runner.sh" "$i" &
  pids+=("$!")
  echo "   slot $i -> pid ${pids[-1]}"
done

# Wait on all slots individually rather than a bare `wait` — bash's no-argument
# `wait` always returns 0 regardless of what its background jobs exited with, so
# it was silently reporting success to systemd even when every slot had died
# (this is exactly what let the pool sit offline for 9h with Restart=on-failure
# never firing: all 7 slots died in a boot-time DNS race, and the bare `wait`
# still exited 0). Each runner.sh already retries transient failures internally
# and only exits on something truly unrecoverable, so a non-zero slot exit here
# is real and should make this script — and the systemd unit — fail loudly.
status=0
for pid in "${pids[@]}"; do
  wait "$pid" || { echo "!! slot pid $pid exited non-zero" >&2; status=1; }
done
exit "$status"
