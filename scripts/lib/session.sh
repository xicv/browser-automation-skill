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
  assert_safe_name "${name}" "session-name"

  if ! printf '%s' "${ss_json}" | jq -e . >/dev/null 2>&1; then
    die "${EXIT_USAGE_ERROR}" "session_save: storageState JSON is not valid"
  fi
  if ! printf '%s' "${ss_json}" | jq -e '.cookies | type == "array"' >/dev/null 2>&1; then
    die "${EXIT_USAGE_ERROR}" "session_save: storageState missing cookies array"
  fi
  if ! printf '%s' "${ss_json}" | jq -e '.origins | type == "array"' >/dev/null 2>&1; then
    die "${EXIT_USAGE_ERROR}" "session_save: storageState missing origins array"
  fi
  # Playwright's context.addInitScript() / .storageState() round-trip requires
  # each origin to declare a localStorage array (may be empty). Hand-edited
  # storageState files trip on this at browser launch — surface it here.
  if ! printf '%s' "${ss_json}" | jq -e 'all(.origins[]; .localStorage | type == "array")' >/dev/null 2>&1; then
    die "${EXIT_USAGE_ERROR}" "session_save: storageState origins[*].localStorage must be an array (use [] for empty); see Playwright storageState shape"
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

# session_delete NAME — remove session storageState + meta files.
# Idempotent: succeeds even if files are already gone (dangling references
# can come from a cascading site removal that didn't clean sessions).
# Does NOT clear site.default_session pointers — Phase 5 may add that
# cascade once the credential lifecycle is more developed.
session_delete() {
  local name="$1"
  assert_safe_name "${name}" "session-name"
  local ss_path meta_path
  ss_path="$(_session_path "${name}")"
  meta_path="$(_session_meta_path "${name}")"
  rm -f "${ss_path}" "${meta_path}"
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

# url_origin URL → echoes scheme://host[:port] from a URL string.
# Bash-only, no python3 dep. Examples:
#   https://app.example.com/x      -> https://app.example.com
#   https://app.example.com:8443/  -> https://app.example.com:8443
#   http://localhost               -> http://localhost
url_origin() {
  local url="$1"
  case "${url}" in
    http://*)  ;;
    https://*) ;;
    *) die "${EXIT_USAGE_ERROR}" "url must start with http:// or https:// (got: ${url})" ;;
  esac
  # Strip the path/query/fragment after the host[:port].
  printf '%s' "${url}" | awk '
    {
      n = index($0, "://")
      scheme = substr($0, 1, n + 2)
      rest   = substr($0, n + 3)
      slash  = index(rest, "/")
      if (slash > 0) rest = substr(rest, 1, slash - 1)
      q = index(rest, "?")
      if (q > 0) rest = substr(rest, 1, q - 1)
      h = index(rest, "#")
      if (h > 0) rest = substr(rest, 1, h - 1)
      printf "%s%s", scheme, rest
    }'
}

# session_origin_check NAME TARGET_URL
# Compares the session's stored origin (from meta sidecar) against the URL's
# origin. Exits EXIT_SESSION_EXPIRED on mismatch (spec §5.5).
session_origin_check() {
  local name="$1" target_url="$2"
  local meta_origin target_origin
  meta_origin="$(session_meta_load "${name}" | jq -r .origin)"
  target_origin="$(url_origin "${target_url}")"
  if [ "${meta_origin}" != "${target_origin}" ]; then
    die "${EXIT_SESSION_EXPIRED}" \
      "origin mismatch: session origin=${meta_origin}, target origin=${target_origin}"
  fi
}

# session_expiry_summary NAME → emits a single-line JSON object:
#   {"session": NAME, "captured_at": ..., "expires_in_hours": ..., "origin": ...}
# Used by login + later phases' relogin / doctor to surface session staleness.
session_expiry_summary() {
  local name="$1"
  local meta
  meta="$(session_meta_load "${name}")"
  jq -c --arg n "${name}" '{
    session:          $n,
    origin:           (.origin // null),
    captured_at:      (.captured_at // null),
    expires_in_hours: (.expires_in_hours // null)
  }' <<< "${meta}"
}
