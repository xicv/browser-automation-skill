#!/usr/bin/env bash
# scripts/browser-snapshot.sh — capture an accessibility snapshot via the
# routed adapter; result is eN-indexed per token-efficient-output spec §5.
# Usage: bash scripts/browser-snapshot.sh [--site NAME] [--tool NAME]
#                                         [--dry-run] [--raw] [--depth N]
#                                         [--capture]
#
# Phase 7 part 1-i: --capture writes adapter stdout to
# ${CAPTURES_DIR}/NNN/snapshot.json + meta.json. capture_id joins the summary.
# Snapshot is structurally safe (refs only, no headers/cookies) — sanitization
# arrives in 7-iii when console.json + network.har enter the picture.

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

init_paths

SUMMARY_T0="$(now_ms)"; export SUMMARY_T0

parse_verb_globals "$@"

# Resolve site/session → BROWSER_SKILL_STORAGE_STATE (no-op if neither set).
# Router's rule_session_required reads the env var to prefer playwright-lib.
resolve_session_storage_state

# Strip --capture (verb-script-level; not for adapter dispatch). All other
# args pass through.
do_capture=0
verb_argv=()
i=0
while [ "${i}" -lt "${#REMAINING_ARGV[@]}" ]; do
  case "${REMAINING_ARGV[i]}" in
    --capture)
      do_capture=1
      i=$((i + 1))
      ;;
    *)
      verb_argv+=("${REMAINING_ARGV[i]}")
      i=$((i + 1))
      ;;
  esac
done

if [ "${ARG_DRY_RUN:-0}" = "1" ]; then
  ok "dry-run: would snapshot"
  if [ "${do_capture}" = "1" ]; then
    emit_summary verb=snapshot tool=none why=dry-run status=ok dry_run=true capture=true
  else
    emit_summary verb=snapshot tool=none why=dry-run status=ok dry_run=true
  fi
  exit 0
fi

picked="$(pick_tool snapshot "${verb_argv[@]}")"
tool_name="${picked%%$'\t'*}"
why="${picked#*$'\t'}"

source_picked_adapter "${tool_name}"

# Open capture dir BEFORE adapter call so meta.json/in_progress lands even if
# the adapter crashes before producing output.
if [ "${do_capture}" = "1" ]; then
  capture_start snapshot
fi

# invoke_with_retry wraps tool_snapshot in transparent retry-on-EXIT_SESSION_
# EXPIRED (phase-5 part 3-ii).
set +e
adapter_out="$(invoke_with_retry snapshot "${verb_argv[@]}")"
adapter_rc=$?
set -e

[ -n "${adapter_out}" ] && printf '%s\n' "${adapter_out}"

# Persist adapter stdout to snapshot.json before finalizing meta.json (so the
# inventory + total_bytes reflect the artifact).
if [ "${do_capture}" = "1" ]; then
  if [ -n "${adapter_out}" ]; then
    printf '%s\n' "${adapter_out}" > "${CAPTURE_DIR}/snapshot.json"
    chmod 600 "${CAPTURE_DIR}/snapshot.json"
  fi
  if [ "${adapter_rc}" -eq 0 ]; then
    capture_finish ok
  else
    capture_finish error
  fi
fi

if [ "${adapter_rc}" -eq 0 ]; then
  if [ "${do_capture}" = "1" ]; then
    emit_summary verb=snapshot tool="${tool_name}" why="${why}" status=ok capture_id="${CAPTURE_ID}"
  else
    emit_summary verb=snapshot tool="${tool_name}" why="${why}" status=ok
  fi
  exit 0
fi
if [ "${do_capture}" = "1" ]; then
  emit_summary verb=snapshot tool="${tool_name}" why="${why}" status=error capture_id="${CAPTURE_ID}"
else
  emit_summary verb=snapshot tool="${tool_name}" why="${why}" status=error
fi
exit "${adapter_rc}"
