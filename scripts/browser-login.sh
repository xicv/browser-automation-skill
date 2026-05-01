#!/usr/bin/env bash
# login — capture a Playwright storageState into sessions/<name>.json.
#
# Phase 2: STUB ADAPTER. Reads a hand-edited storageState file from disk,
# validates it, origin-binds it to the site, writes the session + meta.
# No browser launch yet — Phase 3 will replace this file-read with a real
# `playwright open --save-storage` call behind the same CLI.
#
# Headed-only; --auto is reserved for Phase 5 (auto-relogin).
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/site.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/site.sh"
# shellcheck source=lib/session.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/session.sh"
init_paths

site=""; as=""; ss_file=""; dry_run=0; auto=0; headed=1

usage() {
  cat <<'USAGE'
Usage: login --site NAME --as SESSION --storage-state-file PATH [--dry-run]

Phase 2 stub adapter — reads a hand-edited Playwright storageState from
PATH and writes it as sessions/<SESSION>.json. (Phase 3 will replace
--storage-state-file with a real headed browser launch.)

  --site NAME                 site profile to bind the session to (required)
  --as SESSION                session name (required, used as filename)
  --storage-state-file PATH   path to a Playwright storageState JSON (required)
  --dry-run                   validate inputs; write nothing
  --headed                    accepted (default; Phase 2 is headed-only)
  --auto                      reserved; refused in Phase 2
  -h, --help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --site)                 site="$2"; shift 2 ;;
    --as)                   as="$2"; shift 2 ;;
    --storage-state-file)   ss_file="$2"; shift 2 ;;
    --dry-run)              dry_run=1; shift ;;
    --headed)               headed=1; shift ;;
    --auto)                 auto=1; shift ;;
    -h|--help)              usage; exit 0 ;;
    *)                      die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done

if [ "${auto}" -eq 1 ]; then
  die "${EXIT_USAGE_ERROR}" "--auto is reserved for Phase 5 auto-relogin; refused in Phase 2"
fi
[ -n "${site}" ]    || { usage; die "${EXIT_USAGE_ERROR}" "--site is required"; }
# --as defaults to site.default_session if the site sets one.
if [ -z "${as}" ]; then
  default_session_from_site="$(site_load "${site}" | jq -r '.default_session // ""')"
  if [ -n "${default_session_from_site}" ]; then
    as="${default_session_from_site}"
  else
    die "${EXIT_USAGE_ERROR}" "--as is required (site ${site} has no default_session set)"
  fi
fi
# Validate session name before using it as a filename.
assert_safe_name "${as}" "session-name"
[ -n "${ss_file}" ] || { usage; die "${EXIT_USAGE_ERROR}" "--storage-state-file is required (Phase 2 is stub-only)"; }
[ -f "${ss_file}" ] || die "${EXIT_USAGE_ERROR}" "storage-state-file not found: ${ss_file}"

started_at_ms="$(now_ms)"

# Site must exist; load its URL → derive origin for binding.
profile_json="$(site_load "${site}")"   # exits 23 if missing
site_url="$(printf '%s' "${profile_json}" | jq -r .url)"
site_origin="$(url_origin "${site_url}")"

# Read & validate the storageState file.
if ! ss_json="$(jq -c . "${ss_file}" 2>/dev/null)"; then
  die "${EXIT_USAGE_ERROR}" "storage-state-file is not valid JSON: ${ss_file}"
fi

# Origin-binding (spec §5.5): every storageState.origins[] must match site_origin.
# Empty origins[] is allowed (storageState may carry only cookies).
mismatched="$(printf '%s' "${ss_json}" | jq -r --arg target "${site_origin}" '
  [.origins[]? | select(.origin != $target) | .origin] | join(",")')"
if [ -n "${mismatched}" ]; then
  die "${EXIT_SESSION_EXPIRED}" \
    "origin mismatch: storage-state-file origins=[${mismatched}], site origin=${site_origin}"
fi

ok "site=${site} session=${as} origin=${site_origin}"

if [ "${dry_run}" -eq 1 ]; then
  ok "dry-run: would write ${SESSIONS_DIR}/${as}.json"
  duration_ms=$(( $(now_ms) - started_at_ms ))
  summary_json verb=login tool=playwright-lib why=dry-run status=ok would_run=true \
               site="${site}" session="${as}" duration_ms="${duration_ms}"
  exit "${EXIT_OK}"
fi

# Build meta sidecar.
captured_at="$(now_iso)"
meta_json="$(jq -nc \
  --arg n "${as}" \
  --arg s "${site}" \
  --arg o "${site_origin}" \
  --arg c "${captured_at}" \
  --arg ua "browser-skill phase-2 stub adapter" \
  '{
    name: $n, site: $s, origin: $o, captured_at: $c,
    source_user_agent: $ua, expires_in_hours: 168, schema_version: 1
  }')"

session_save "${as}" "${ss_json}" "${meta_json}"
ok "session captured: ${as}"

duration_ms=$(( $(now_ms) - started_at_ms ))
summary_json verb=login tool=playwright-lib why=storageState-file-import status=ok \
             site="${site}" session="${as}" origin="${site_origin}" \
             expires_in_hours=168 duration_ms="${duration_ms}"
