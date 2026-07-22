#!/usr/bin/env bash
# lib.sh — shared config loading for build-image.sh / pool.sh / runner.sh.
# Sourced, never executed.

# load_config <file> — apply settings from a KEY=VALUE file WITHOUT clobbering
# variables already present in the environment, so precedence is:
#
#   real env var  >  config.env  >  the script's built-in default
#
# We parse rather than `source` for two reasons:
#   1. `source` would overwrite an env var the caller deliberately set, inverting
#      the precedence above;
#   2. the file must stay literal KEY=VALUE so systemd can consume the SAME file
#      via EnvironmentFile= (systemd does no shell expansion — a `${VAR:-x}` in
#      there would be taken literally).
load_config() {
  local file="$1" line key val
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    # skip blanks and comments
    case "$line" in ''|'#'*) continue ;; esac
    # must look like KEY=VALUE
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    # tolerate `KEY = value` and surrounding quotes on the value
    key="${key%"${key##*[![:space:]]}"}"
    val="${val#"${val%%[![:space:]]*}"}"
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    # reject anything that isn't a plain shell identifier
    case "$key" in *[!A-Za-z0-9_]*|'') continue ;; esac
    # Already set in the environment? The environment wins. Test set-NESS, not
    # non-emptiness: an explicit `GO_VERSION= ./build-image.sh` means "skip that
    # toolchain bake", and the file must not override that deliberate empty.
    [ -n "${!key+set}" ] && continue
    printf -v "$key" '%s' "$val"
    export "${key?}"
  done < "$file"
}

# require_var <NAME> <hint> — fail fast with an actionable message.
require_var() {
  local name="$1" hint="$2"
  [ -n "${!name-}" ] || {
    echo "FATAL: $name is not set — $hint" >&2
    echo "       Set it in config.env (see config.env.example) or pass it as an env var." >&2
    exit 1
  }
}
