#!/usr/bin/env bash
# show-session — emit session metadata only.
#
# CRITICAL SECURITY INVARIANT: this verb NEVER emits the storageState contents
# (cookies, tokens, localStorage). Only the meta sidecar (origin, captured_at,
# expires_in_hours, source_user_agent) is surfaced. The agent has no business
# seeing raw session material; the adapter applies it via storageState file
# path, never via JSON pass-through.

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

name=""
usage() { printf 'Usage: show-session --as NAME\n'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --as) name="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done
[ -n "${name}" ] || { usage; die "${EXIT_USAGE_ERROR}" "--as is required"; }
assert_safe_name "${name}" "session-name"

started_at_ms="$(now_ms)"

if ! session_exists "${name}"; then
  die "${EXIT_SESSION_EXPIRED}" "session not found: ${name}"
fi

meta="$(session_meta_load "${name}")"
ss_path="${SESSIONS_DIR}/${name}.json"
file_size="$(wc -c < "${ss_path}" 2>/dev/null | tr -d ' ' || printf '0')"
duration_ms=$(( $(now_ms) - started_at_ms ))

# Derive surface-level info from storageState WITHOUT echoing values: count
# cookies + count distinct origins. Never reveal cookie names, values, or
# domains beyond the count.
counts="$(jq -c '{cookie_count: (.cookies // [] | length),
                 origin_count: (.origins // [] | length)}' "${ss_path}" 2>/dev/null || printf '{}')"

jq -cn --arg n "${name}" --argjson m "${meta}" --argjson c "${counts}" \
       --argjson s "${file_size}" --argjson d "${duration_ms}" \
  '{verb: "show-session", tool: "none", why: "show", status: "ok",
    session: $n, meta: $m,
    storage_state: ($c + {file_size_bytes: $s}),
    duration_ms: $d}'
