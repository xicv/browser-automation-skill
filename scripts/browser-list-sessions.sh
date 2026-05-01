#!/usr/bin/env bash
# list-sessions — list captured Playwright sessions (storageState files).
#
# Sessions are tied to sites via meta.site; pass --site NAME to filter.
# A site may have many sessions — this verb is the discoverability surface
# for the 1-many credential model (e.g. prod--admin, prod--readonly, prod--ci).
#
# Storage state itself is sensitive and stays at mode 0600 — this verb only
# emits metadata (origin, captured_at, expires_in_hours), never cookie/token
# values.

set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/session.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/session.sh"
init_paths

site_filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    --site) site_filter="$2"; shift 2 ;;
    -h|--help)
      cat <<'USAGE'
Usage: list-sessions [--site NAME]

  --site NAME    show only sessions bound to this site
USAGE
      exit 0
      ;;
    *) die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done

started_at_ms="$(now_ms)"

rows='[]'
count=0
if [ -d "${SESSIONS_DIR}" ]; then
  shopt -s nullglob
  for f in "${SESSIONS_DIR}"/*.json; do
    base="$(basename "${f}" .json)"
    case "${base}" in
      *.meta) continue ;;
      *interactive-tmp*) continue ;;
    esac
    [ -f "${SESSIONS_DIR}/${base}.meta.json" ] || continue
    meta="$(session_meta_load "${base}" 2>/dev/null)" || continue
    sess_site="$(printf '%s' "${meta}" | jq -r '.site // ""')"
    if [ -n "${site_filter}" ] && [ "${sess_site}" != "${site_filter}" ]; then
      continue
    fi
    rows="$(jq --arg n "${base}" --argjson m "${meta}" '
      . + [{
        session:          $n,
        site:             ($m.site // null),
        origin:           ($m.origin // null),
        captured_at:      ($m.captured_at // null),
        expires_in_hours: ($m.expires_in_hours // null)
      }]' <<< "${rows}")"
    count=$((count + 1))
  done
  shopt -u nullglob
fi

duration_ms=$(( $(now_ms) - started_at_ms ))
jq -cn --argjson r "${rows}" --argjson c "${count}" --argjson d "${duration_ms}" \
  --arg sf "${site_filter}" \
  '{verb: "list-sessions", tool: "none", why: (if $sf == "" then "list-all" else "list-by-site" end),
    status: (if $c == 0 then "empty" else "ok" end),
    site_filter: ($sf | if . == "" then null else . end),
    count: $c, sessions: $r, duration_ms: $d}'
