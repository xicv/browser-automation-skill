#!/usr/bin/env bash
# scripts/browser-baseline.sh — named-blessed-capture management. Phase 9
# part 1-v (CLOSES Phase 9).
#
# Sub-modes:
#   save <capture-id> --as NAME      — set is_baseline:true; write baselines.json entry
#   list                              — emit one baseline_row per entry
#   remove <NAME>                     — clear is_baseline; splice baselines.json
#                                       (does NOT delete the capture dir; use
#                                        history clear for that)
#
# Per locked decision B1: thin wrapper over Phase 7's meta.is_baseline:true.
# capture_prune already honors the skip-rule (landed in 7-1-v as forward-compat
# for Phase 9). NO new prune logic here.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}"
export SCRIPTS_DIR

# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/output.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/output.sh"

init_paths

SUMMARY_T0="$(now_ms)"; export SUMMARY_T0

readonly BASELINES_FILE="${BROWSER_SKILL_HOME}/baselines.json"

# Lazy-create baselines.json on first save (mode 0600).
_baseline_init_file() {
  if [ ! -f "${BASELINES_FILE}" ]; then
    jq -nc '{schema_version: 1, baselines: []}' > "${BASELINES_FILE}"
    chmod 600 "${BASELINES_FILE}"
  fi
}

sub_mode="${1:-}"
[ -n "${sub_mode}" ] || die "${EXIT_USAGE_ERROR}" "browser-baseline: missing sub-mode (save / list / remove)"
shift

case "${sub_mode}" in
  save)
    capture_id="${1:-}"
    [ -n "${capture_id}" ] || die "${EXIT_USAGE_ERROR}" "baseline save: missing <capture-id>"
    shift
    name=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --as) name="$2"; shift 2 ;;
        *)    die "${EXIT_USAGE_ERROR}" "baseline save: unknown flag '$1'" ;;
      esac
    done
    [ -n "${name}" ] || die "${EXIT_USAGE_ERROR}" "baseline save: --as NAME is required"

    meta="${CAPTURES_DIR}/${capture_id}/meta.json"
    [ -f "${meta}" ] || die "${EXIT_USAGE_ERROR}" "baseline save: no such capture '${capture_id}'"

    # Set is_baseline:true on meta.json (Phase 7's prune skip-rule honors this).
    tmp="${meta}.tmp.$$"
    jq '.is_baseline = true' "${meta}" > "${tmp}"
    chmod 600 "${tmp}"
    mv "${tmp}" "${meta}"

    # Append entry to baselines.json.
    _baseline_init_file
    saved_at="$(now_iso)"
    summary_obj="$(jq -c '{verb, flow_name, step_count}' "${meta}")"
    tmp="${BASELINES_FILE}.tmp.$$"
    jq -c \
      --arg name "${name}" \
      --arg cid "${capture_id}" \
      --arg ts "${saved_at}" \
      --argjson sum "${summary_obj}" \
      '.baselines += [{name: $name, capture_id: $cid, saved_at: $ts, summary: $sum}]' \
      "${BASELINES_FILE}" > "${tmp}"
    chmod 600 "${tmp}"
    mv "${tmp}" "${BASELINES_FILE}"

    emit_summary verb=baseline tool=none why=save status=ok mode=save \
      capture_id="${capture_id}" name="${name}"
    exit 0
    ;;

  list)
    _baseline_init_file
    total=0
    while IFS= read -r row; do
      [ -z "${row}" ] && continue
      printf '%s' "${row}" | jq -c '. + {event: "baseline_row"}'
      total=$((total + 1))
    done <<< "$(jq -c '.baselines[]?' "${BASELINES_FILE}")"
    emit_summary verb=baseline tool=none why=list status=ok mode=list total="${total}"
    exit 0
    ;;

  remove)
    name="${1:-}"
    [ -n "${name}" ] || die "${EXIT_USAGE_ERROR}" "baseline remove: missing <name>"
    _baseline_init_file
    # Find the capture-id for the given name.
    capture_id="$(jq -r --arg n "${name}" '.baselines[] | select(.name == $n) | .capture_id' "${BASELINES_FILE}")"
    [ -n "${capture_id}" ] || die "${EXIT_USAGE_ERROR}" "baseline remove: no such baseline '${name}'"

    # Clear is_baseline on meta.json (if capture still exists; fail-soft).
    meta="${CAPTURES_DIR}/${capture_id}/meta.json"
    if [ -f "${meta}" ]; then
      tmp="${meta}.tmp.$$"
      jq '.is_baseline = false' "${meta}" > "${tmp}"
      chmod 600 "${tmp}"
      mv "${tmp}" "${meta}"
    fi

    # Splice baselines.json.
    tmp="${BASELINES_FILE}.tmp.$$"
    jq -c --arg n "${name}" '.baselines |= map(select(.name != $n))' \
      "${BASELINES_FILE}" > "${tmp}"
    chmod 600 "${tmp}"
    mv "${tmp}" "${BASELINES_FILE}"

    emit_summary verb=baseline tool=none why=remove status=ok mode=remove \
      capture_id="${capture_id}" name="${name}"
    exit 0
    ;;

  *)
    die "${EXIT_USAGE_ERROR}" "browser-baseline: unknown sub-mode '${sub_mode}' (use save / list / remove)"
    ;;
esac
