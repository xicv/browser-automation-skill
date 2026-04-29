# scripts/lib/session.sh
# Read/write helpers for Playwright storageState files plus their meta sidecar.
# Source from any verb that needs to load or save a session.
# Requires lib/common.sh sourced first (init_paths must have run).

[ -n "${BROWSER_SKILL_SESSION_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_SESSION_LOADED=1

_session_path()      { printf '%s/%s.json'      "${SESSIONS_DIR}" "$1"; }
_session_meta_path() { printf '%s/%s.meta.json' "${SESSIONS_DIR}" "$1"; }

session_exists() {
  [ -f "$(_session_path "$1")" ]
}

# session_save NAME STORAGE_STATE_JSON META_JSON
# Validates that storageState has top-level `cookies` and `origins` arrays
# (Playwright shape), then writes both files atomically at mode 0600.
session_save() {
  local name="$1" ss_json="$2" meta_json="$3"

  if ! printf '%s' "${ss_json}" | jq -e . >/dev/null 2>&1; then
    die "${EXIT_USAGE_ERROR}" "session_save: storageState JSON is not valid"
  fi
  if ! printf '%s' "${ss_json}" | jq -e '.cookies | type == "array"' >/dev/null 2>&1; then
    die "${EXIT_USAGE_ERROR}" "session_save: storageState missing cookies array"
  fi
  if ! printf '%s' "${ss_json}" | jq -e '.origins | type == "array"' >/dev/null 2>&1; then
    die "${EXIT_USAGE_ERROR}" "session_save: storageState missing origins array"
  fi
  if ! printf '%s' "${meta_json}" | jq -e . >/dev/null 2>&1; then
    die "${EXIT_USAGE_ERROR}" "session_save: meta JSON is not valid"
  fi

  mkdir -p "${SESSIONS_DIR}"
  chmod 700 "${SESSIONS_DIR}"

  local ss_path meta_path ss_tmp meta_tmp
  ss_path="$(_session_path "${name}")"
  meta_path="$(_session_meta_path "${name}")"
  ss_tmp="${ss_path}.tmp.$$"
  meta_tmp="${meta_path}.tmp.$$"

  (
    umask 077
    printf '%s\n' "${ss_json}"   | jq . > "${ss_tmp}"
    printf '%s\n' "${meta_json}" | jq . > "${meta_tmp}"
  )
  chmod 600 "${ss_tmp}" "${meta_tmp}"
  mv "${ss_tmp}" "${ss_path}"
  mv "${meta_tmp}" "${meta_path}"
}

# session_load NAME → echoes the storageState JSON (Playwright shape).
# Missing session → exit 22 (SESSION_EXPIRED) per spec §5.5; the caller
# can decide whether to relogin (Phase 5) or surface to the user.
session_load() {
  local name="$1"
  local path
  path="$(_session_path "${name}")"
  if [ ! -f "${path}" ]; then
    die "${EXIT_SESSION_EXPIRED}" "session not found: ${name}"
  fi
  cat "${path}"
}

session_meta_load() {
  local name="$1"
  local path
  path="$(_session_meta_path "${name}")"
  if [ ! -f "${path}" ]; then
    die "${EXIT_SESSION_EXPIRED}" "session meta not found: ${name}"
  fi
  cat "${path}"
}
