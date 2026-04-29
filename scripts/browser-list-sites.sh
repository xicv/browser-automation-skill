#!/usr/bin/env bash
# list-sites — list registered site profiles (no creds; sites are non-secret).
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
init_paths

started_at_ms="$(now_ms)"

names="$(site_list_names)"
rows='[]'
count=0
if [ -n "${names}" ]; then
  while IFS= read -r n; do
    [ -z "${n}" ] && continue
    profile="$(site_load "${n}")"
    meta="$(site_meta_load "${n}")"
    rows="$(jq --argjson p "${profile}" --argjson m "${meta}" '
      . + [{
        name:           $p.name,
        url:            $p.url,
        label:          ($p.label // ""),
        default_session:$p.default_session,
        default_tool:   $p.default_tool,
        last_used_at:   ($m.last_used_at // null)
      }]' <<< "${rows}")"
    count=$((count + 1))
  done <<< "${names}"
fi

duration_ms=$(( $(now_ms) - started_at_ms ))
jq -cn --argjson r "${rows}" --argjson c "${count}" --argjson d "${duration_ms}" \
  '{verb: "list-sites", tool: "none", why: "list", status: "ok",
    count: $c, sites: $r, duration_ms: $d}'
