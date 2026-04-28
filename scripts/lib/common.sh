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
# Prints to stderr in red, returns the given code (caller should call exit if needed).
die() {
  local code="$1"
  shift
  local prefix
  prefix="$(_browser_skill_color $'\033[0;31m')error:$(_browser_skill_color $'\033[0m')"
  printf '%s %s\n' "${prefix}" "$*" >&2
  return "${code}"
}
