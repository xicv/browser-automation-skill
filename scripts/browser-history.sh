#!/usr/bin/env bash
# scripts/browser-history.sh — read-side ops over the captures pipeline +
# manual-trigger prune. Phase 9 part 1-v (CLOSES Phase 9).
#
# Sub-modes:
#   list [--limit N]                   — enumerate captures (newest first)
#   show <capture-id>                  — print meta.json + steps.jsonl
#   diff <id1> <id2>                   — per-step replay_diff via flow_diff_steps
#   clear [--keep N] [--days D]        — manual prune (composes Phase 7's
#         [--not-baseline]               capture_prune; respects is_baseline
#                                        skip-rule by default)

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
# shellcheck source=lib/capture.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/capture.sh"
# shellcheck source=lib/flow.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/flow.sh"

init_paths

SUMMARY_T0="$(now_ms)"; export SUMMARY_T0

sub_mode="${1:-}"
[ -n "${sub_mode}" ] || die "${EXIT_USAGE_ERROR}" "browser-history: missing sub-mode (list / show / diff / clear)"
shift

case "${sub_mode}" in
  list)
    limit=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --limit) limit="$2"; shift 2 ;;
        --since) shift 2 ;;  # accepted; deferred (out-of-scope filter)
        *)       die "${EXIT_USAGE_ERROR}" "history list: unknown flag '$1'" ;;
      esac
    done
    total=0
    if [ -d "${CAPTURES_DIR}" ]; then
      shopt -s nullglob
      # Sort by capture_id (which is monotonic per Phase 7); newest first.
      ids=()
      for d in "${CAPTURES_DIR}"/[0-9]*/; do
        ids+=("$(basename "${d}")")
      done
      shopt -u nullglob
      # Reverse-sort to put newest first.
      mapfile -t sorted < <(printf '%s\n' "${ids[@]}" | sort -r)
      for id in "${sorted[@]}"; do
        meta="${CAPTURES_DIR}/${id}/meta.json"
        [ -f "${meta}" ] || continue
        if [ -n "${limit}" ] && [ "${total}" -ge "${limit}" ]; then
          break
        fi
        # Emit per-capture row event.
        jq -c --arg event "history_row" \
          '. + {event: $event}' "${meta}"
        total=$((total + 1))
      done
    fi
    emit_summary verb=history tool=none why=list status=ok mode=list total="${total}"
    exit 0
    ;;

  show)
    show_id="${1:-}"
    [ -n "${show_id}" ] || die "${EXIT_USAGE_ERROR}" "history show: missing <capture-id>"
    meta="${CAPTURES_DIR}/${show_id}/meta.json"
    [ -f "${meta}" ] || die "${EXIT_USAGE_ERROR}" "history show: no such capture '${show_id}'"
    # Compact meta.json onto a single line so callers can parse the first
    # line as a complete JSON object (capture_start writes pretty-printed
    # multi-line; jq -c re-flattens).
    jq -c . "${meta}"
    steps_log="${CAPTURES_DIR}/${show_id}/steps.jsonl"
    [ -f "${steps_log}" ] && cat "${steps_log}"
    emit_summary verb=history tool=none why=show status=ok mode=show capture_id="${show_id}"
    exit 0
    ;;

  diff)
    id1="${1:-}"
    id2="${2:-}"
    [ -n "${id1}" ] && [ -n "${id2}" ] || die "${EXIT_USAGE_ERROR}" "history diff: requires <id1> <id2>"
    log1="${CAPTURES_DIR}/${id1}/steps.jsonl"
    log2="${CAPTURES_DIR}/${id2}/steps.jsonl"
    [ -f "${log1}" ] || die "${EXIT_USAGE_ERROR}" "history diff: no steps.jsonl at captures/${id1}/"
    [ -f "${log2}" ] || die "${EXIT_USAGE_ERROR}" "history diff: no steps.jsonl at captures/${id2}/"
    # Iterate paired step events; emit replay_diff per pair.
    matched=0
    diverged=0
    paste -d $'\t' "${log1}" "${log2}" | while IFS=$'\t' read -r old new; do
      [ -z "${old}" ] || [ -z "${new}" ] && continue
      flow_diff_steps "${old}" "${new}" || true
    done
    # Aggregate counts via separate read pass.
    total_steps="$(wc -l < "${log1}" | tr -d ' ')"
    emit_summary verb=history tool=none why=diff status=ok mode=diff \
      capture_id_old="${id1}" capture_id_new="${id2}" total_steps="${total_steps}"
    exit 0
    ;;

  clear)
    keep=""
    days=""
    not_baseline=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --keep)         keep="$2"; shift 2 ;;
        --days)         days="$2"; shift 2 ;;
        --not-baseline) not_baseline=1; shift ;;
        *)              die "${EXIT_USAGE_ERROR}" "history clear: unknown flag '$1'" ;;
      esac
    done

    pruned=0
    if [ -d "${CAPTURES_DIR}" ]; then
      shopt -s nullglob
      ids=()
      for d in "${CAPTURES_DIR}"/[0-9]*/; do
        ids+=("$(basename "${d}")")
      done
      shopt -u nullglob
      # Newest-first sort; keep first N if --keep.
      mapfile -t sorted < <(printf '%s\n' "${ids[@]}" | sort -r)
      idx=0
      now_epoch="$(date -u +%s)"
      for id in "${sorted[@]}"; do
        meta="${CAPTURES_DIR}/${id}/meta.json"
        [ -f "${meta}" ] || continue
        is_baseline="$(jq -r '.is_baseline // false' "${meta}" 2>/dev/null || printf 'false')"
        # is_baseline:true is ALWAYS skipped (per Phase 7 prune contract +
        # locked decision H3).
        if [ "${is_baseline}" = "true" ]; then
          idx=$((idx + 1))
          continue
        fi
        # --keep N: keep the newest N (skip pruning the first N).
        if [ -n "${keep}" ] && [ "${idx}" -lt "${keep}" ]; then
          idx=$((idx + 1))
          continue
        fi
        # --days D: keep captures younger than D days.
        if [ -n "${days}" ]; then
          finished_at="$(jq -r '.finished_at // .started_at // ""' "${meta}" 2>/dev/null || printf '')"
          if [ -n "${finished_at}" ]; then
            cap_epoch="$(date -d "${finished_at}" +%s 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%SZ' "${finished_at}" +%s 2>/dev/null || printf '0')"
            age_days=$(( (now_epoch - cap_epoch) / 86400 ))
            if [ "${age_days}" -lt "${days}" ]; then
              idx=$((idx + 1))
              continue
            fi
          fi
        fi
        # If --not-baseline alone (no --keep / --days), prune everything
        # non-baseline. If --not-baseline + --keep / --days, the above
        # checks already excluded baselines + applied limits.
        if [ -z "${keep}" ] && [ -z "${days}" ] && [ "${not_baseline}" = "0" ]; then
          # No flags at all → no-op (use config defaults via auto-prune).
          idx=$((idx + 1))
          continue
        fi
        rm -rf "${CAPTURES_DIR}/${id}"
        pruned=$((pruned + 1))
        idx=$((idx + 1))
      done
    fi
    emit_summary verb=history tool=none why=clear status=ok mode=clear pruned="${pruned}"
    exit 0
    ;;

  *)
    die "${EXIT_USAGE_ERROR}" "browser-history: unknown sub-mode '${sub_mode}' (use list / show / diff / clear)"
    ;;
esac
