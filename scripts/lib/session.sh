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
