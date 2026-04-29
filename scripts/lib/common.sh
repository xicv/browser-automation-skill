# scripts/lib/common.sh
# Shared helpers for browser-automation-skill. Source this file from every
# verb script and lib module. Mirrors mqtt-skill's lib/common.sh pattern.

# Guard against double-sourcing.
[ -n "${BROWSER_SKILL_COMMON_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_COMMON_LOADED=1

# Restrictive umask for everything we create.
umask 077

# --- Exit code table (matches docs/superpowers/specs §5.1) ---
readonly EXIT_OK=0
readonly EXIT_GENERIC_ERROR=1
readonly EXIT_USAGE_ERROR=2
readonly EXIT_EMPTY_RESULT=11
readonly EXIT_PARTIAL_RESULT=12
readonly EXIT_ASSERTION_FAILED=13
readonly EXIT_PREFLIGHT_FAILED=20
readonly EXIT_TOOL_MISSING=21
readonly EXIT_SESSION_EXPIRED=22
readonly EXIT_SITE_NOT_FOUND=23
readonly EXIT_CREDENTIAL_AMBIGUOUS=24
readonly EXIT_AUTH_INTERACTIVE_REQUIRED=25
readonly EXIT_KEYCHAIN_LOCKED=26
readonly EXIT_TTY_REQUIRED=27
readonly EXIT_BLOCKLIST_REJECTED=28
readonly EXIT_NETWORK_ERROR=30
readonly EXIT_CAPTURE_WRITE_FAILED=31
readonly EXIT_RETENTION_BLOCKED=32
readonly EXIT_SCHEMA_MIGRATION_REQUIRED=33
readonly EXIT_TOOL_UNSUPPORTED_OP=41
readonly EXIT_TOOL_CRASHED=42
readonly EXIT_TOOL_TIMEOUT=43

# --- Logging ---
# All logging goes to stderr. stdout is reserved for streaming JSON + summary.
# Honors NO_COLOR=1 (https://no-color.org) and FORCE_COLOR=1.

_browser_skill_color() {
  if [ "${NO_COLOR:-0}" = "1" ]; then
    printf ''
    return
  fi
  if [ "${FORCE_COLOR:-0}" = "1" ] || [ -t 2 ]; then
    printf '%s' "$1"
    return
  fi
  printf ''
}

ok() {
  local prefix
  prefix="$(_browser_skill_color $'\033[0;32m')ok:$(_browser_skill_color $'\033[0m')"
  printf '%s %s\n' "${prefix}" "$*" >&2
}

warn() {
  local prefix
  prefix="$(_browser_skill_color $'\033[0;33m')warn:$(_browser_skill_color $'\033[0m')"
  printf '%s %s\n' "${prefix}" "$*" >&2
}

# die EXIT_CODE MESSAGE...
# Prints to stderr in red, exits with the given code.
die() {
  local code="$1"
  shift
  local prefix
  prefix="$(_browser_skill_color $'\033[0;31m')error:$(_browser_skill_color $'\033[0m')"
  printf '%s %s\n' "${prefix}" "$*" >&2
  exit "${code}"
}

# --- Path resolution ---
# resolve_browser_skill_home echoes the canonical state-home path.
# Resolution order:
#   1. $BROWSER_SKILL_HOME (explicit override)
#   2. Walk up from $PWD looking for .browser-skill/ (project-scoped mode)
#   3. ~/.browser-skill/ (user-level fallback)
resolve_browser_skill_home() {
  if [ -n "${BROWSER_SKILL_HOME:-}" ]; then
    printf '%s\n' "${BROWSER_SKILL_HOME}"
    return 0
  fi
  local dir="${PWD}"
  while [ "${dir}" != "/" ]; do
    if [ -d "${dir}/.browser-skill" ]; then
      printf '%s\n' "${dir}/.browser-skill"
      return 0
    fi
    dir="$(dirname "${dir}")"
  done
  printf '%s\n' "${HOME}/.browser-skill"
}

# Convenience: export the resolved home + canonical subdirs once per invocation.
# Verbs source common.sh and call this immediately.
init_paths() {
  BROWSER_SKILL_HOME="$(resolve_browser_skill_home)"
  export BROWSER_SKILL_HOME
  export SITES_DIR="${BROWSER_SKILL_HOME}/sites"
  export SESSIONS_DIR="${BROWSER_SKILL_HOME}/sessions"
  export CREDENTIALS_DIR="${BROWSER_SKILL_HOME}/credentials"
  export CAPTURES_DIR="${BROWSER_SKILL_HOME}/captures"
  export FLOWS_DIR="${BROWSER_SKILL_HOME}/flows"
  export CURRENT_FILE="${BROWSER_SKILL_HOME}/current"
}

# --- JSON summary writer ---
# Usage: summary_json key=value key=value ...
# Emits one valid JSON object per line on stdout. Uses jq for safe escaping —
# never let bash interpolation construct JSON strings (quote bugs = leaks).
# Numeric values (duration_ms, console_errors, etc.) stay as JSON numbers.
summary_json() {
  if [ "$#" -eq 0 ]; then
    die "${EXIT_USAGE_ERROR}" "summary_json: no key=value pairs supplied"
  fi

  local args=()
  local pair key value
  for pair in "$@"; do
    case "${pair}" in
      *=*)
        key="${pair%%=*}"
        value="${pair#*=}"
        # Numeric? Pass as --argjson; else --arg (string).
        if [[ "${value}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
          args+=(--argjson "${key}" "${value}")
        elif [ "${value}" = "true" ] || [ "${value}" = "false" ] || [ "${value}" = "null" ]; then
          args+=(--argjson "${key}" "${value}")
        else
          args+=(--arg "${key}" "${value}")
        fi
        ;;
      *)
        die "${EXIT_USAGE_ERROR}" "summary_json: bad pair '${pair}' (expected key=value)"
        ;;
    esac
  done

  # Build the object dynamically: jq -n accepts our --arg/--argjson names.
  local jq_filter='. = {}'
  for pair in "$@"; do
    key="${pair%%=*}"
    jq_filter="${jq_filter} | .${key} = \$${key}"
  done
  jq -nc "${args[@]}" "${jq_filter}"
}

# --- Millisecond timestamp ---
# now_ms echoes the current epoch time in milliseconds as a positive integer.
# Verbs use this to compute duration_ms for their JSON summary.
# Portable across GNU date (%3N) and BSD date (no %3N — falls through to python3).
now_ms() {
  local t
  t="$(date +%s%3N 2>/dev/null)"
  case "${t}" in
    *N) python3 -c 'import time; print(int(time.time()*1000))' ;;
    *)  printf '%s\n' "${t}" ;;
  esac
}

# now_iso echoes the current UTC time as RFC-3339 / ISO-8601, second precision,
# trailing Z. Portable across GNU date (-u +%FT%TZ) and BSD date.
now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# --- Name safety ---
# assert_safe_name NAME [FIELD_LABEL]
# Refuses names that could escape a state dir or run outside the allowed
# character set. Allowed chars: A-Z a-z 0-9 dash underscore. Empty rejected.
# FIELD_LABEL (default "name") shows up in the error so callers can pass
# "session-name", "default-session", etc. for clearer messages.
assert_safe_name() {
  local name="$1"
  local field="${2:-name}"
  if [[ ! "${name}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    die "${EXIT_USAGE_ERROR}" "${field} must match ^[A-Za-z0-9_-]+$ (got: ${name})"
  fi
}

# --- Timeout wrapper ---
# with_timeout SECONDS COMMAND ARGS...
# Wraps `timeout` (GNU) or `gtimeout` (macOS coreutils) or a hand-rolled fallback.
# On timeout: kills the child, returns EXIT_TOOL_TIMEOUT (43).
# On success: returns the child's exit code.
with_timeout() {
  local secs="$1"
  shift
  local rc=0

  if command -v timeout >/dev/null 2>&1; then
    timeout --preserve-status -k 2 "${secs}" "$@" || rc=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout --preserve-status -k 2 "${secs}" "$@" || rc=$?
  else
    # Fallback: spawn child + watcher in subshell.
    "$@" &
    local child=$!
    ( sleep "${secs}"; kill -TERM "${child}" 2>/dev/null; sleep 2; kill -KILL "${child}" 2>/dev/null ) &
    local watcher=$!
    wait "${child}" 2>/dev/null || rc=$?
    kill "${watcher}" 2>/dev/null || true
  fi

  # 124 = GNU timeout's "timed out" code; 137 = SIGKILL; 143 = SIGTERM (fallback).
  # Map any of these timeout signals to our 43.
  if [ "${rc}" = "124" ] || [ "${rc}" = "137" ] || [ "${rc}" = "143" ]; then
    return "${EXIT_TOOL_TIMEOUT}"
  fi
  return "${rc}"
}
