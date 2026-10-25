#!/bin/bash
# Git's credential protocol carries the token on a private pipe, never in argv.
set -euo pipefail
if [ "${1:-}" = get ]; then
  printf 'username=x-access-token\npassword=%s\n' "${GH_TOKEN:?Explicit source-read token required}"
fi
