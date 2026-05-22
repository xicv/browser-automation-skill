#!/usr/bin/env bash
# scripts/browser-extract.sh — extract content via CSS selector / JS / scrape.
# Usage: bash scripts/browser-extract.sh [--site NAME] [--tool NAME] [--dry-run]
#                                        [--raw]
#                                        ( --selector CSS | --eval JS
#                                        | --scrape [--eval JS] [--concurrency N] URL... )
#
# Routes to chrome-devtools-mcp by default for selector / eval (post-1d router
# promotion — only adapter with `evaluate_script` + `list_network_requests`
# per parent spec Appendix B). `--scrape` and `--stealth` auto-route to obscura
# via rule_scrape_flag / rule_stealth_flag (Phase 8-2-i, Path B).
# Exactly one mode is required: --selector / --eval / --scrape / --stealth.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/output.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/output.sh"
# shellcheck source=lib/router.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/router.sh"
# shellcheck source=lib/verb_helpers.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/verb_helpers.sh"
# shellcheck source=lib/stats.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/stats.sh"

init_paths

SUMMARY_T0="$(now_ms)"; export SUMMARY_T0

parse_verb_globals "$@"

resolve_session_storage_state

selector="" eval_js="" mode_scrape=0 mode_stealth=0 concurrency=""
# Phase 12 amendment: --format=toon|json (parent spec §4 + amendment §1).
# Default empty leaves emit_format in passthrough (single-line JSON, unchanged).
out_format=""
verb_argv=()
positional_urls=()
i=0
while [ "${i}" -lt "${#REMAINING_ARGV[@]}" ]; do
  case "${REMAINING_ARGV[i]}" in
    --format)
      # Phase 12: swallow at the verb boundary; do NOT pass to adapter.
      out_format="${REMAINING_ARGV[i+1]:-}"
      [ -n "${out_format}" ] || die "${EXIT_USAGE_ERROR}" "--format requires a value"
      i=$((i + 2))
      ;;
    --format=*)
      out_format="${REMAINING_ARGV[i]#--format=}"
      i=$((i + 1))
      ;;
    --selector)
      selector="${REMAINING_ARGV[i+1]:-}"
      [ -n "${selector}" ] || die "${EXIT_USAGE_ERROR}" "--selector requires a value"
      verb_argv+=(--selector "${selector}")
      i=$((i + 2))
      ;;
    --eval)
      eval_js="${REMAINING_ARGV[i+1]:-}"
      [ -n "${eval_js}" ] || die "${EXIT_USAGE_ERROR}" "--eval requires a value"
      verb_argv+=(--eval "${eval_js}")
      i=$((i + 2))
      ;;
    --scrape)
      mode_scrape=1
      verb_argv+=(--scrape)
      i=$((i + 1))
      ;;
    --stealth)
      mode_stealth=1
      verb_argv+=(--stealth)
      i=$((i + 1))
      ;;
    --concurrency)
      concurrency="${REMAINING_ARGV[i+1]:-}"
      [ -n "${concurrency}" ] || die "${EXIT_USAGE_ERROR}" "--concurrency requires a value"
      verb_argv+=(--concurrency "${concurrency}")
      i=$((i + 2))
      ;;
    --*)
      # Unknown flag — passthrough to adapter (defensive; adapter will reject
      # if it doesn't recognise it).
      verb_argv+=("${REMAINING_ARGV[i]}")
      i=$((i + 1))
      ;;
    *)
      # Positional. In --scrape / --stealth mode these are URLs. Outside both
      # modes the verb script has no use for positionals (selector/eval are
      # flag-only).
      if [ "${mode_scrape}" = "1" ] || [ "${mode_stealth}" = "1" ]; then
        positional_urls+=("${REMAINING_ARGV[i]}")
        verb_argv+=("${REMAINING_ARGV[i]}")
      else
        die "${EXIT_USAGE_ERROR}" "unexpected positional arg '${REMAINING_ARGV[i]}' (use --selector / --eval / --scrape / --stealth)"
      fi
      i=$((i + 1))
      ;;
  esac
done

if [ "${mode_scrape}" = "1" ] && [ "${mode_stealth}" = "1" ]; then
  die "${EXIT_USAGE_ERROR}" "--scrape and --stealth are mutually exclusive"
fi

if [ "${mode_scrape}" = "1" ]; then
  [ "${#positional_urls[@]}" -ge 1 ] || die "${EXIT_USAGE_ERROR}" "--scrape requires at least one URL"
elif [ "${mode_stealth}" = "1" ]; then
  [ "${#positional_urls[@]}" -eq 1 ] || die "${EXIT_USAGE_ERROR}" "--stealth requires exactly one URL"
  [ -n "${eval_js}" ]               || die "${EXIT_USAGE_ERROR}" "--stealth requires --eval EXPR"
elif [ -z "${selector}" ] && [ -z "${eval_js}" ]; then
  die "${EXIT_USAGE_ERROR}" "extract requires --selector CSS, --eval JS, --scrape URL..., or --stealth URL"
fi

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  if [ "${mode_scrape}" = "1" ]; then
    ok "dry-run: would scrape ${#positional_urls[@]} URL(s) via obscura"
    emit_summary verb=extract tool=none why=dry-run status=ok mode=scrape \
      total_urls="${#positional_urls[@]}" dry_run=true
  elif [ "${mode_stealth}" = "1" ]; then
    ok "dry-run: would stealth-fetch ${positional_urls[0]} via obscura"
    emit_summary verb=extract tool=none why=dry-run status=ok mode=stealth \
      url="${positional_urls[0]}" dry_run=true
  else
    ok "dry-run: would extract ${selector:-${eval_js}}"
    emit_summary verb=extract tool=none why=dry-run status=ok selector="${selector}" dry_run=true
  fi
  exit 0
fi

picked="$(pick_tool extract "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

stats_t0="$(now_ms)"
set +e
adapter_out="$(invoke_with_retry extract "${verb_argv[@]}")"
adapter_rc=$?
set -e

# Phase 12 part 1: per-action telemetry. extract covers chrome-devtools-mcp
# (default) + obscura (--scrape/--stealth). observed=adapter_out so
# element_value post-conditions can match extracted text/JSON.
BROWSER_STATS_OBSERVED="${adapter_out}" \
  stats_run_adapter_emit \
    "extract" "${tool_name}" "${stats_t0}" "${adapter_rc}" "${adapter_out}" "" \
    -- "${verb_argv[@]}" || true

# Phase 12: TOON callers consume a single consolidated document; streaming
# per-URL events would prepend duplicate data + break the doc-shape guarantee.
# Suppress streaming when --format=toon is active on a multi-URL mode.
if [ "${out_format}" != "toon" ] || [ "${mode_scrape}" != "1" ]; then
  [ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"
fi

if [ "${mode_scrape}" = "1" ]; then
  # Aggregate per-URL events into success/failure counts for the summary line.
  total="${#positional_urls[@]}"
  successful=0
  failed=0
  if [ -n "${adapter_out}" ]; then
    successful="$(printf '%s\n' "${adapter_out}" | jq -s 'map(select(.event=="scrape_url" and (.title // false))) | length' 2>/dev/null || printf '0')"
    failed="$(    printf '%s\n' "${adapter_out}" | jq -s 'map(select(.event=="scrape_url" and (.error // false))) | length' 2>/dev/null || printf '0')"
  fi
  if [ "${adapter_rc}" -ne 0 ]; then
    overall_status=error
  elif [ "${failed}" = "0" ]; then
    overall_status=ok
  elif [ "${successful}" = "0" ]; then
    overall_status=error
  else
    overall_status=partial
  fi
  if [ "${out_format}" = "toon" ]; then
    # Consolidate per-URL events into a TOON results[] table (amendment §3).
    # Project to uniform columns so the encoder picks table form. The full
    # streaming events stay available in stats.jsonl for replay/diagnosis.
    results="$(printf '%s\n' "${adapter_out}" | jq -s '
      map(select(.event=="scrape_url"))
      | map({
          url:    .url,
          status: (if (.error // false) then "error" else "ok" end),
          title:  (.title // null),
          error:  (.error // null)
        })')"
    duration_ms=$(( $(now_ms) - SUMMARY_T0 ))
    # Replace the streaming-line output (already printed above) is unavoidable
    # in scrape mode; the consolidated TOON document follows. Callers using
    # --format=toon should only consume the trailing TOON document, not the
    # per-line events; the events themselves remain valid JSONL for stat tools.
    jq -cn --arg verb extract --arg tool "${tool_name}" --arg why "${why}" \
           --arg status "${overall_status}" \
           --argjson total "${total}" --argjson succ "${successful}" --argjson fail "${failed}" \
           --argjson r "${results}" --argjson d "${duration_ms}" \
      '{verb:$verb,tool:$tool,why:$why,status:$status,mode:"scrape",
        total_urls:$total,successful:$succ,failed:$fail,
        results:$r,duration_ms:$d}' \
      | emit_format toon
  else
    emit_summary verb=extract tool="${tool_name}" why="${why}" \
      status="${overall_status}" mode=scrape \
      total_urls="${total}" successful="${successful}" failed="${failed}"
  fi
  [ "${overall_status}" = "ok" ] && exit 0
  exit "${adapter_rc}"
fi

if [ "${mode_stealth}" = "1" ]; then
  if [ "${adapter_rc}" -ne 0 ]; then
    overall_status=error
  elif [ -z "${adapter_out}" ]; then
    overall_status=empty
  else
    overall_status=ok
  fi
  emit_summary verb=extract tool="${tool_name}" why="${why}" \
    status="${overall_status}" mode=stealth url="${positional_urls[0]}"
  [ "${overall_status}" = "ok" ] && exit 0
  exit "${adapter_rc}"
fi

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=extract tool="${tool_name}" why="${why}" status=ok selector="${selector}"
  exit 0
fi
emit_summary verb=extract tool="${tool_name}" why="${why}" status=error selector="${selector}"
exit "${adapter_rc}"
