#!/usr/bin/env bash
# scripts/browser-extract.sh — extract content via CSS selector / JS / scrape.
# Usage: bash scripts/browser-extract.sh [--site NAME] [--tool NAME] [--dry-run]
#                                        [--raw]
#                                        ( --selector CSS | --eval JS
#                                        | --scrape [--eval JS] [--concurrency N] URL... )
#
# Routes to chrome-devtools-mcp by default for selector / eval (post-1d router
# promotion — only adapter with `evaluate_script` + `list_network_requests`
# per parent spec Appendix B). `--scrape` requires `--tool obscura` in 8-1-ii;
# router promotion to default for `--scrape` is 8-2-i (Path B).
# Exactly one mode is required: --selector / --eval / --scrape.

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

init_paths

SUMMARY_T0="$(now_ms)"; export SUMMARY_T0

parse_verb_globals "$@"

resolve_session_storage_state

selector="" eval_js="" mode_scrape=0 concurrency=""
verb_argv=()
scrape_urls=()
i=0
while [ "${i}" -lt "${#REMAINING_ARGV[@]}" ]; do
  case "${REMAINING_ARGV[i]}" in
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
      # Positional. In --scrape mode these are URLs. Outside scrape mode the
      # only positional we accept is empty (selector/eval must use flags).
      if [ "${mode_scrape}" = "1" ]; then
        scrape_urls+=("${REMAINING_ARGV[i]}")
        verb_argv+=("${REMAINING_ARGV[i]}")
      else
        die "${EXIT_USAGE_ERROR}" "unexpected positional arg '${REMAINING_ARGV[i]}' (use --selector / --eval / --scrape)"
      fi
      i=$((i + 1))
      ;;
  esac
done

if [ "${mode_scrape}" = "1" ]; then
  [ "${#scrape_urls[@]}" -ge 1 ] || die "${EXIT_USAGE_ERROR}" "--scrape requires at least one URL"
elif [ -z "${selector}" ] && [ -z "${eval_js}" ]; then
  die "${EXIT_USAGE_ERROR}" "extract requires --selector CSS, --eval JS, or --scrape URL..."
fi

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  if [ "${mode_scrape}" = "1" ]; then
    ok "dry-run: would scrape ${#scrape_urls[@]} URL(s) via obscura"
    emit_summary verb=extract tool=none why=dry-run status=ok mode=scrape \
      total_urls="${#scrape_urls[@]}" dry_run=true
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

set +e
adapter_out="$(invoke_with_retry extract "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

if [ "${mode_scrape}" = "1" ]; then
  # Aggregate per-URL events into success/failure counts for the summary line.
  total="${#scrape_urls[@]}"
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
  emit_summary verb=extract tool="${tool_name}" why="${why}" \
    status="${overall_status}" mode=scrape \
    total_urls="${total}" successful="${successful}" failed="${failed}"
  [ "${overall_status}" = "ok" ] && exit 0
  exit "${adapter_rc}"
fi

if [ "${adapter_rc}" -eq 0 ]; then
  emit_summary verb=extract tool="${tool_name}" why="${why}" status=ok selector="${selector}"
  exit 0
fi
emit_summary verb=extract tool="${tool_name}" why="${why}" status=error selector="${selector}"
exit "${adapter_rc}"
