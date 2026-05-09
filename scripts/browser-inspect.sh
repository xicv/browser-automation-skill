#!/usr/bin/env bash
# scripts/browser-inspect.sh — inspect a page (console, network, screenshot,
# or selector text). Usage:
#   bash scripts/browser-inspect.sh [--site NAME] [--tool NAME] [--dry-run]
#                                   [--raw]
#                                   (--capture-console | --capture-network
#                                    | --screenshot | --selector CSS)
#                                   [--capture]
#
# Routes to chrome-devtools-mcp by default (post-1d router promotion — only
# adapter with dedicated console + network MCP tools per parent spec
# Appendix B). At least one of --capture-* / --screenshot / --selector is
# required so the adapter has something to do.
#
# Phase 7 part 1-iii: --capture writes adapter output to ${CAPTURES_DIR}/NNN/
# as console.json + network.har, sanitized via lib/sanitize.sh. Stdout output
# is ALSO sanitized (defense in depth) — single transformation, both sinks.

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
# shellcheck source=lib/capture.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/capture.sh"
# shellcheck source=lib/sanitize.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/sanitize.sh"

init_paths

SUMMARY_T0="$(now_ms)"; export SUMMARY_T0

parse_verb_globals "$@"

resolve_session_storage_state

selector="" capture_console=0 capture_network=0 screenshot=0 do_capture=0 unsanitized=0
verb_argv=()
i=0
while [ "${i}" -lt "${#REMAINING_ARGV[@]}" ]; do
  case "${REMAINING_ARGV[i]}" in
    --selector)
      selector="${REMAINING_ARGV[i+1]:-}"
      [ -n "${selector}" ] || die "${EXIT_USAGE_ERROR}" "--selector requires a value"
      verb_argv+=(--selector "${selector}")
      i=$((i + 2))
      ;;
    --capture-console)
      capture_console=1
      verb_argv+=(--capture-console)
      i=$((i + 1))
      ;;
    --capture-network)
      capture_network=1
      verb_argv+=(--capture-network)
      i=$((i + 1))
      ;;
    --screenshot)
      screenshot=1
      verb_argv+=(--screenshot)
      i=$((i + 1))
      ;;
    --capture)
      do_capture=1
      i=$((i + 1))
      ;;
    --unsanitized)
      unsanitized=1
      i=$((i + 1))
      ;;
    *)
      verb_argv+=("${REMAINING_ARGV[i]}")
      i=$((i + 1))
      ;;
  esac
done

# Phase 7 part 1-iv: --unsanitized requires typed-phrase confirmation.
# Strict equality (no whitespace strip) — friction-by-design. Mirrors
# scripts/browser-creds-show.sh::--reveal precedent. Phrase verbatim per
# parent spec §8.3. Scripted use: pipe phrase via stdin.
if [ "${unsanitized}" = "1" ]; then
  printf 'Type the unsanitized confirmation phrase to confirm: ' >&2
  IFS= read -r unsanitized_answer || true
  if [ "${unsanitized_answer}" != "I want raw network/console data including auth tokens" ]; then
    die "${EXIT_USAGE_ERROR}" "unsanitized aborted (confirmation mismatch)"
  fi
fi

if [ -z "${selector}" ] && [ "${capture_console}" = 0 ] \
   && [ "${capture_network}" = 0 ] && [ "${screenshot}" = 0 ]; then
  die "${EXIT_USAGE_ERROR}" \
      "inspect requires one of --capture-console / --capture-network / --screenshot / --selector CSS"
fi

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would inspect (${selector:-<no-selector>})"
  if [ "${do_capture}" = "1" ]; then
    emit_summary verb=inspect tool=none why=dry-run status=ok selector="${selector}" dry_run=true capture=true
  else
    emit_summary verb=inspect tool=none why=dry-run status=ok selector="${selector}" dry_run=true
  fi
  exit 0
fi

picked="$(pick_tool inspect "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

if [ "${do_capture}" = "1" ]; then
  capture_start inspect
fi

set +e
adapter_out="$(invoke_with_retry inspect "${verb_argv[@]}")"
adapter_rc=$?
set -e

if [ "${do_capture}" = "1" ] && [ -n "${adapter_out}" ]; then
  # Single (maybe-)sanitize, both sinks: stdout + per-aspect files. Either
  # path produces the same emit-twice contract; only the transformation
  # differs. --unsanitized skips sanitize_inspect_reply.
  if [ "${unsanitized}" = "1" ]; then
    out_for_emit="${adapter_out}"
    sanitized_flag=false
  else
    out_for_emit="$(printf '%s' "${adapter_out}" | sanitize_inspect_reply)"
    sanitized_flag=true
  fi

  # console.json — extract .console_messages array.
  if [ "${capture_console}" = "1" ]; then
    if printf '%s' "${out_for_emit}" | jq -e 'has("console_messages")' >/dev/null 2>&1; then
      printf '%s' "${out_for_emit}" | jq '.console_messages // []' > "${CAPTURE_DIR}/console.json"
      chmod 600 "${CAPTURE_DIR}/console.json"
    fi
  fi

  # network.har — wrap .network_requests in HAR envelope and persist.
  if [ "${capture_network}" = "1" ]; then
    if printf '%s' "${out_for_emit}" | jq -e 'has("network_requests")' >/dev/null 2>&1; then
      printf '%s' "${out_for_emit}" \
        | jq '{log: {version: "1.2", entries: (.network_requests // [])}}' \
        > "${CAPTURE_DIR}/network.har"
      chmod 600 "${CAPTURE_DIR}/network.har"
    fi
  fi

  printf '%s\n' "${out_for_emit}"

  if [ "${adapter_rc}" -eq 0 ]; then
    capture_finish ok "${sanitized_flag}"
  else
    capture_finish error "${sanitized_flag}"
  fi
else
  [ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"
fi

if [ "${adapter_rc}" -eq 0 ]; then
  if [ "${do_capture}" = "1" ]; then
    emit_summary verb=inspect tool="${tool_name}" why="${why}" status=ok selector="${selector}" capture_id="${CAPTURE_ID}"
  else
    emit_summary verb=inspect tool="${tool_name}" why="${why}" status=ok selector="${selector}"
  fi
  exit 0
fi
if [ "${do_capture}" = "1" ]; then
  emit_summary verb=inspect tool="${tool_name}" why="${why}" status=error selector="${selector}" capture_id="${CAPTURE_ID}"
else
  emit_summary verb=inspect tool="${tool_name}" why="${why}" status=error selector="${selector}"
fi
exit "${adapter_rc}"
