#!/usr/bin/env bash
# use — get / set / clear the current site (CURRENT_FILE).
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

mode=""; arg=""
usage() {
  cat <<'USAGE'
Usage: use --set NAME | --show | --clear
USAGE
}
while [ $# -gt 0 ]; do
  case "$1" in
    --set)    mode=set;   arg="$2"; shift 2 ;;
    --show)   mode=show;  shift ;;
    --clear)  mode=clear; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "${EXIT_USAGE_ERROR}" "unknown flag: $1" ;;
  esac
done
[ -n "${mode}" ] || { usage; die "${EXIT_USAGE_ERROR}" "specify --set NAME, --show, or --clear"; }

started_at_ms="$(now_ms)"

case "${mode}" in
  set)
    [ -n "${arg}" ] || die "${EXIT_USAGE_ERROR}" "--set requires NAME"
    current_set "${arg}"
    ok "current site: ${arg}"
    why="set"
    ;;
  show)
    why="show"
    ;;
  clear)
    current_clear
    ok "current site cleared"
    why="clear"
    ;;
esac

current="$(current_get)"
duration_ms=$(( $(now_ms) - started_at_ms ))
if [ -z "${current}" ]; then
  jq -cn --arg w "${why}" --argjson d "${duration_ms}" \
    '{verb: "use", tool: "none", why: $w, status: "ok", current: null, duration_ms: $d}'
else
  jq -cn --arg w "${why}" --arg c "${current}" --argjson d "${duration_ms}" \
    '{verb: "use", tool: "none", why: $w, status: "ok", current: $c, duration_ms: $d}'
fi
