#!/usr/bin/env bash
# show-site — emit one site's full profile JSON.
# (Phase 5 will mask credential-shaped fields if any are added; today the
#  profile contains nothing secret, so this verb has no --reveal flag.)
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

name=""
usage() { printf 'Usage: show-site --name NAME\n'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --name) name="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done
[ -n "${name}" ] || { usage; die "${EXIT_USAGE_ERROR}" "--name is required"; }

started_at_ms="$(now_ms)"
profile="$(site_load "${name}")"
meta="$(site_meta_load "${name}")"
duration_ms=$(( $(now_ms) - started_at_ms ))

jq -cn --arg n "${name}" --argjson p "${profile}" --argjson m "${meta}" \
       --argjson d "${duration_ms}" \
  '{verb: "show-site", tool: "none", why: "show", status: "ok",
    site: $n, profile: $p, meta: $m, duration_ms: $d}'
