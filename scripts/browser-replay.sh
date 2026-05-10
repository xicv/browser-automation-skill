#!/usr/bin/env bash
# scripts/browser-replay.sh — re-execute a prior capture's steps + diff against
# original. Phase 9 part 1-iv.
#
# Usage:
#   bash scripts/browser-replay.sh <capture-id> [--strict] [--session NAME] [--dry-run]
#
# Loads ${CAPTURES_DIR}/<capture-id>/meta.json + steps.jsonl. Re-dispatches
# each step via flow_dispatch (composes 9-1-i + 9-1-ii). Writes a NEW capture
# with `replay_of: <capture-id>` + `replay_match: bool`. Emits per-step
# replay_diff event lines + one replay_diff_summary on stdout.
#
# Status mapping (per design doc §3 F5 + plan locked decision D3):
#   All steps match → status:ok   replay_match:true   exit 0
#   Mixed match/diverge → status:partial replay_match:false exit 0
#   All steps diverged OR aborted → status:error exit non-zero
#
# --strict flag: ANY divergence → exit 13 (EXIT_ASSERTION_FAILED), matching
# the assert verb's exit code. Composes with CI scripts that grep for 13.

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

capture_id="${1:-}"
[ -n "${capture_id}" ] || die "${EXIT_USAGE_ERROR}" "browser-replay: missing <capture-id>"
shift

strict=0
dry_run=0
session_override=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict)  strict=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --session) session_override="$2"; shift 2 ;;
    *)         die "${EXIT_USAGE_ERROR}" "browser-replay: unknown flag '$1'" ;;
  esac
done

old_dir="${CAPTURES_DIR}/${capture_id}"
old_meta="${old_dir}/meta.json"
old_steps="${old_dir}/steps.jsonl"

[ -d "${old_dir}" ] || die "${EXIT_USAGE_ERROR}" "browser-replay: no such capture '${capture_id}' at ${old_dir}"
[ -f "${old_meta}" ] || die "${EXIT_USAGE_ERROR}" "browser-replay: no meta.json at ${old_meta}"

# Reject non-flow captures — only `verb: flow` (or `verb: replay`) captures
# carry steps.jsonl. Per plan sub-scope: replay only consumes flow captures.
old_verb="$(jq -r '.verb' "${old_meta}")"
case "${old_verb}" in
  flow|replay) ;;
  *) die "${EXIT_USAGE_ERROR}" "browser-replay: capture ${capture_id} is not a flow capture (verb=${old_verb})" ;;
esac

[ -f "${old_steps}" ] || die "${EXIT_USAGE_ERROR}" "browser-replay: no steps.jsonl at ${old_steps}"

# Dry-run pre-pass: print planned steps; no execution.
if [ "${dry_run}" = "1" ]; then
  ok "dry-run: would replay ${capture_id} (verb=${old_verb})"
  printf '%s\n' "$(cat "${old_steps}")"
  emit_summary verb=replay tool=none why=dry-run status=ok \
    replay_of="${capture_id}" dry_run=true
  exit 0
fi

# Real run: capture pipeline + per-step re-dispatch + per-step diff.
capture_start "replay"
new_meta="${CAPTURE_DIR}/meta.json"
tmp="${new_meta}.tmp.$$"
jq --arg ro "${capture_id}" '.replay_of = $ro' "${new_meta}" > "${tmp}"
chmod 600 "${tmp}"
mv "${tmp}" "${new_meta}"

new_steps="${CAPTURE_DIR}/steps.jsonl"
: > "${new_steps}"
chmod 600 "${new_steps}"

# Reset flow state in this shell (replay starts fresh; no inherited refs).
declare -gA FLOW_VARS=()
declare -gA FLOW_REFS=()

total_steps=0
matched_steps=0
diverged_steps=0
last_exit=0

# Iterate the OLD steps in order; re-dispatch each; emit diff event.
while IFS= read -r old_step; do
  [ -z "${old_step}" ] && continue
  total_steps=$((total_steps + 1))

  # Re-build the step input for flow_dispatch from the OLD step's verb + args.
  # (We don't carry over the OLD status / summary — we want the FRESH outcome.)
  step_input="$(printf '%s' "${old_step}" | jq -c '{step_index, verb, args}')"
  new_step_event="$(flow_dispatch "${step_input}")"
  printf '%s\n' "${new_step_event}" >> "${new_steps}"

  # Diff old vs new.
  set +e
  diff_event="$(flow_diff_steps "${old_step}" "${new_step_event}")"
  diff_rc=$?
  set -e
  printf '%s\n' "${diff_event}"

  if [ "${diff_rc}" = "0" ]; then
    matched_steps=$((matched_steps + 1))
  else
    diverged_steps=$((diverged_steps + 1))
  fi

  # Track step-level errors for status mapping.
  step_status="$(printf '%s' "${new_step_event}" | jq -r '.status')"
  if [ "${step_status}" != "ok" ]; then
    last_exit="$(printf '%s' "${new_step_event}" | jq -r '.exit_code')"
  fi

  # Phase 9-1-ii ref-harvest semantics also apply during replay.
  refs_for_step="$(printf '%s' "${new_step_event}" | jq -c '.refs // null')"
  if [ "${refs_for_step}" != "null" ]; then
    FLOW_REFS=()
    while IFS=$'\t' read -r ref_text ref_id; do
      [ -z "${ref_text}" ] && continue
      FLOW_REFS["${ref_text}"]="${ref_id}"
    done <<< "$(printf '%s' "${refs_for_step}" | jq -r '.[] | "\(.text)\t\(.ref)"')"
  fi
done < "${old_steps}"

# Determine replay_match + status.
if [ "${diverged_steps}" = "0" ] && [ "${total_steps}" -gt "0" ]; then
  replay_match=true
  flow_status="ok"
elif [ "${matched_steps}" = "0" ] && [ "${diverged_steps}" -gt "0" ]; then
  replay_match=false
  flow_status="error"
else
  replay_match=false
  flow_status="partial"
fi

# Append replay-specific fields to meta.json.
tmp="${new_meta}.tmp.$$"
jq \
  --arg     ro    "${capture_id}" \
  --argjson rm    "${replay_match}" \
  --argjson tot   "${total_steps}" \
  --argjson mat   "${matched_steps}" \
  --argjson div   "${diverged_steps}" \
  '. + {replay_of: $ro, replay_match: $rm, total_steps: $tot, matched_steps: $mat, diverged_steps: $div}' \
  "${new_meta}" > "${tmp}"
chmod 600 "${tmp}"
mv "${tmp}" "${new_meta}"

capture_finish "${flow_status}" true

# Emit replay_diff_summary line.
jq -nc \
  --arg     event         "replay_diff_summary" \
  --arg     old_capture_id "${capture_id}" \
  --arg     new_capture_id "${CAPTURE_ID}" \
  --argjson total_steps   "${total_steps}" \
  --argjson matched_steps "${matched_steps}" \
  --argjson diverged_steps "${diverged_steps}" \
  --argjson replay_match  "${replay_match}" \
  '{event: $event, old_capture_id: $old_capture_id, new_capture_id: $new_capture_id,
    total_steps: $total_steps, matched_steps: $matched_steps, diverged_steps: $diverged_steps,
    replay_match: $replay_match}'

# --strict: any divergence → exit 13 (EXIT_ASSERTION_FAILED).
if [ "${strict}" = "1" ] && [ "${diverged_steps}" -gt "0" ]; then
  emit_summary verb=replay tool=none why=run status=error \
    replay_of="${capture_id}" capture_id="${CAPTURE_ID}" \
    replay_match="${replay_match}" \
    total_steps="${total_steps}" matched_steps="${matched_steps}" diverged_steps="${diverged_steps}"
  exit "${EXIT_ASSERTION_FAILED}"
fi

emit_summary verb=replay tool=none why=run status="${flow_status}" \
  replay_of="${capture_id}" capture_id="${CAPTURE_ID}" \
  replay_match="${replay_match}" \
  total_steps="${total_steps}" matched_steps="${matched_steps}" diverged_steps="${diverged_steps}"

if [ "${flow_status}" = "ok" ] || [ "${flow_status}" = "partial" ]; then
  exit 0
fi
exit "${last_exit}"
