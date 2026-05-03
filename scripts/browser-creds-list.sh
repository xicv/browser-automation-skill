#!/usr/bin/env bash
# creds-list — list registered credentials. Optional --site filter mirrors
# list-sessions. Emits ONLY metadata (NEVER secret values; backend payloads
# stay in their respective vaults).

set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/credential.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/credential.sh"
init_paths

site_filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    --site)
      site_filter="$2"; shift 2
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: creds-list [--site NAME]

  --site NAME    show only credentials bound to this site
USAGE
      exit 0
      ;;
    *) die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done

started_at_ms="$(now_ms)"

rows='[]'
count=0
for name in $(credential_list_names); do
  meta="$(credential_load "${name}" 2>/dev/null)" || continue
  cred_site="$(printf '%s' "${meta}" | jq -r '.site // ""')"
  if [ -n "${site_filter}" ] && [ "${cred_site}" != "${site_filter}" ]; then
    continue
  fi
  rows="$(jq --arg n "${name}" --argjson m "${meta}" '
    . + [{
      credential:   $n,
      site:         ($m.site // null),
      account:      ($m.account // null),
      backend:      ($m.backend // null),
      auto_relogin: ($m.auto_relogin // null),
      totp_enabled: ($m.totp_enabled // null),
      created_at:   ($m.created_at // null)
    }]' <<< "${rows}")"
  count=$((count + 1))
done

duration_ms=$(( $(now_ms) - started_at_ms ))
jq -cn --argjson r "${rows}" --argjson c "${count}" --argjson d "${duration_ms}" \
  --arg sf "${site_filter}" \
  '{verb: "creds-list", tool: "none",
    why: (if $sf == "" then "list-all" else "list-by-site" end),
    status: (if $c == 0 then "empty" else "ok" end),
    site_filter: ($sf | if . == "" then null else . end),
    count: $c, credentials: $r, duration_ms: $d}'
